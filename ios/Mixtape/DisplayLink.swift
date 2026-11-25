import CoreBluetooth
import SwiftUI
import UIKit

/// Écran Swag (LilyGO T-Display S3) : Mixtape lui envoie le son en cours et sa pochette en Bluetooth.
/// Le protocole doit rester identique à display/MixtapeDisplay/MixtapeDisplay.ino.
@MainActor
final class DisplayLink: NSObject, ObservableObject {
    static let shared = DisplayLink()

    enum Status: Equatable {
        case off, bluetoothOff, unauthorized, searching, connecting, connected
        var label: String {
            switch self {
            case .off: return "Pas configuré"
            case .bluetoothOff: return "Bluetooth éteint"
            case .unauthorized: return "Bluetooth refusé pour Mixtape"
            case .searching: return "Recherche de l'écran…"
            case .connecting: return "Reconnexion…"
            case .connected: return "Connecté en Bluetooth"
            }
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case texte, musique, auto
        var id: String { rawValue }
        var title: String {
            switch self {
            case .texte: return "Texte"
            case .musique: return "Musique"
            case .auto: return "Auto"
            }
        }
        var help: String {
            switch self {
            case .texte: return "L'écran affiche toujours ton texte, même quand tu écoutes de la musique."
            case .musique: return "L'écran affiche uniquement le morceau en cours."
            case .auto: return "Ton texte s'affiche, et le morceau prend sa place dès que la musique démarre."
            }
        }
    }

    static let colors: [(name: String, hex: String)] = [
        ("Violet", "4A148C"), ("Rose", "C2185B"), ("Bleu", "1565C0"), ("Vert", "1B5E20"), ("Noir", "111111"),
    ]

    private static let serviceID = CBUUID(string: "8f1c0001-6d69-7874-6170-652d64737033")
    private static let inputID = CBUUID(string: "8f1c0002-6d69-7874-6170-652d64737033")
    private static let statusID = CBUUID(string: "8f1c0003-6d69-7874-6170-652d64737033")

    @Published private(set) var status: Status = .off
    @Published var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "displayMode")
            if !modeFromDisplay { sendSettings() }
        }
    }
    /// Vrai quand c'est le bouton de l'écran qui a changé le mode (rien à lui renvoyer).
    private var modeFromDisplay = false
    @Published var text: String { didSet { UserDefaults.standard.set(text, forKey: "displayText"); scheduleSettings() } }
    @Published var colorHex: String { didSet { UserDefaults.standard.set(colorHex, forKey: "displayColor"); sendSettings() } }
    @Published var sendCover: Bool {
        didSet {
            UserDefaults.standard.set(sendCover, forKey: "displayCover")
            sentCoverKey = nil
            resendNowPlaying()
        }
    }

    var isConfigured: Bool { savedID != nil }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var input: CBCharacteristic?
    private var outbox: [Data] = []
    private var settingsTask: Task<Void, Never>?

    // Dernier son reçu de PlayerModel (pour le renvoyer à la reconnexion).
    private var lastTrack: Track?
    private var lastArtwork: UIImage?
    private var lastPlaying = false
    private var lastElapsed: Double = 0
    private var lastDuration: Double = 0
    private var sentCoverKey: String?
    private var lastMeta: Data?

    private var savedID: UUID? {
        get { UserDefaults.standard.string(forKey: "displayPeripheral").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "displayPeripheral") }
    }

    private override init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .auto
        text = d.string(forKey: "displayText") ?? "swag"
        colorHex = d.string(forKey: "displayColor") ?? "4A148C"
        sendCover = d.object(forKey: "displayCover") as? Bool ?? true
        super.init()
    }

    /// Au lancement : on ne réveille le Bluetooth que si un écran a déjà été relié.
    func startIfConfigured() {
        if isConfigured { start() }
    }

    /// Lance la connexion (demande l'accès Bluetooth la première fois).
    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionRestoreIdentifierKey: "mixtape.display"])
        } else {
            connectOrScan()
        }
    }

    /// Oublie l'écran : il faudra le rechercher à nouveau.
    func forget() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        peripheral = nil
        input = nil
        savedID = nil
        status = .off
    }

    // MARK: Ce que joue Mixtape

    /// Appelé par PlayerModel à chaque changement (son, lecture/pause, position, pochette).
    func nowPlaying(track: Track?, artwork: UIImage?, playing: Bool, elapsed: Double, duration: Double) {
        let changed = track?.id != lastTrack?.id
        if changed { sentCoverKey = nil; lastArtwork = nil }
        lastTrack = track
        if let artwork { lastArtwork = artwork }
        lastPlaying = playing
        lastElapsed = elapsed
        lastDuration = duration
        resendNowPlaying()
    }

    private func resendNowPlaying() {
        guard status == .connected else { return }
        guard let track = lastTrack else {
            enqueue(Data("X".utf8))
            return
        }
        let fields = ["M", clip(track.title), clip(track.displayArtist), lastPlaying ? "1" : "0",
                      String(format: "%.1f", lastElapsed), String(format: "%.1f", lastDuration), coverKey(track)]
        let meta = Data(fields.joined(separator: "\u{1F}").utf8)
        if meta != lastMeta {
            lastMeta = meta
            enqueue(meta)
        }
        if sendCover, sentCoverKey != coverKey(track), let image = lastArtwork, let jpeg = Self.coverJPEG(image) {
            sentCoverKey = coverKey(track)
            sendCoverData(jpeg, key: coverKey(track))
        }
    }

    private func coverKey(_ track: Track) -> String { sendCover ? String(track.id.prefix(24)) : "" }

    /// L'écran ne connaît que les lettres sans accent : on enlève les accents et on coupe.
    private func clip(_ s: String) -> String {
        let plain = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        let cleaned = plain.replacingOccurrences(of: "\u{1F}", with: " ")
        return String(cleaned.prefix(48))
    }

    /// Pochette carrée 170 × 170 en JPEG (taille de l'écran).
    private static func coverJPEG(_ image: UIImage) -> Data? {
        let side: CGFloat = 170
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let square = renderer.image { _ in
            let s = image.size
            let scale = max(side / max(s.width, 1), side / max(s.height, 1))
            let w = s.width * scale, h = s.height * scale
            image.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        for quality in [0.7, 0.5, 0.35] {
            if let data = square.jpegData(compressionQuality: quality), data.count < 40_000 { return data }
        }
        return nil
    }

    private func sendCoverData(_ jpeg: Data, key: String) {
        guard let peripheral else { return }
        var start = Data([0x01])
        start.append(contentsOf: Self.u32(jpeg.count))
        start.append(Data(key.utf8))
        enqueue(start)
        let chunk = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse) - 5)
        var offset = 0
        while offset < jpeg.count {
            let end = min(offset + chunk, jpeg.count)
            var packet = Data([0x02])
            packet.append(contentsOf: Self.u32(offset))
            packet.append(jpeg.subdata(in: offset..<end))
            enqueue(packet)
            offset = end
        }
        enqueue(Data([0x03]))
    }

    private static func u32(_ v: Int) -> [UInt8] {
        let n = UInt32(v)
        return [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]
    }

    // MARK: Réglages de l'écran

    private func scheduleSettings() {
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.sendSettings()
        }
    }

    private func sendSettings() {
        guard status == .connected else { return }
        let fields = ["S", mode.rawValue, clip(text), colorHex]
        enqueue(Data(fields.joined(separator: "\u{1F}").utf8))
    }

    // MARK: Envoi (sans attendre de réponse, au rythme du Bluetooth)

    private func enqueue(_ data: Data) {
        outbox.append(data)
        flush()
    }

    private func flush() {
        guard let peripheral, let input, peripheral.state == .connected else { return }
        while !outbox.isEmpty, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(outbox.removeFirst(), for: input, type: .withoutResponse)
        }
    }

    private func connectOrScan() {
        guard let central, central.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connected {
            // Retrouvé après un redémarrage de l'app : il reste à retrouver le service.
            if input == nil { peripheral.delegate = self; peripheral.discoverServices([Self.serviceID]) }
            return
        }
        if let peripheral, peripheral.state == .connecting { return }
        if let id = savedID, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
            return
        }
        if let already = central.retrieveConnectedPeripherals(withServices: [Self.serviceID]).first {
            connect(already)
            return
        }
        status = .searching
        central.scanForPeripherals(withServices: [Self.serviceID])
    }

    private func connect(_ p: CBPeripheral) {
        central?.stopScan()
        peripheral = p
        p.delegate = self
        savedID = p.identifier
        status = .connecting
        // Connexion « en attente » : iOS la fait tout seul dès que l'écran est allumé à côté.
        central?.connect(p)
    }

    private func didBecomeReady() {
        status = .connected
        outbox.removeAll()
        lastMeta = nil
        sentCoverKey = nil
        sendSettings()
        resendNowPlaying()
    }
}

// MARK: - Bluetooth

extension DisplayLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: connectOrScan()
            case .poweredOff: status = .bluetoothOff
            case .unauthorized: status = .unauthorized
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
                peripheral = p
                p.delegate = self
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { connect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            status = .connecting
            peripheral.discoverServices([Self.serviceID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            input = nil
            outbox.removeAll()
            guard savedID != nil else { return }
            status = .connecting
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard savedID != nil else { return }
            central.connect(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else { return }
            peripheral.discoverCharacteristics([Self.inputID, Self.statusID], for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                if c.uuid == Self.inputID { input = c }
                if c.uuid == Self.statusID { peripheral.setNotifyValue(true, for: c) }
            }
            if input != nil { didBecomeReady() }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            // L'écran a changé de mode avec son bouton : on met l'app à jour sans renvoyer.
            guard characteristic.uuid == Self.statusID, let data = characteristic.value,
                  let raw = String(data: data, encoding: .utf8), let m = Mode(rawValue: raw), m != mode else { return }
            modeFromDisplay = true
            mode = m
            modeFromDisplay = false
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { flush() }
    }
}

// MARK: - Réglages › Écran

struct DisplaySettingsView: View {
    @ObservedObject private var link = DisplayLink.shared

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Text("S3")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 30)
                        .background(Color(displayHex: link.colorHex), in: RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("T-Display S3").font(.headline)
                        Text(link.status.label)
                            .font(.footnote)
                            .foregroundStyle(link.status == .connected ? .green : .secondary)
                    }
                    Spacer()
                    if link.status == .searching || link.status == .connecting { ProgressView() }
                }
                if link.isConfigured {
                    Button("Oublier l'écran", role: .destructive) { link.forget() }
                } else {
                    Button("Connecter l'écran") { link.start() }
                }
            } footer: {
                Text(link.isConfigured
                     ? "Mixtape se reconnecte toute seule dès que l'écran est allumé près de l'iPhone. Si l'iPhone propose un jumelage, accepte-le : c'est ce qui permet aussi d'afficher Spotify, Apple Music…"
                     : "Allume l'écran, puis touche « Connecter l'écran ». Accepte l'accès Bluetooth puis la demande de jumelage.")
            }

            Section {
                Toggle("Envoyer la pochette", isOn: $link.sendCover)
                    .tint(Color.accentPink)
            } footer: {
                Text("Les autres apps (Spotify, Apple Music…) s'affichent aussi, avec le titre et l'artiste mais sans pochette.")
            }

            Section {
                Picker("Mode", selection: $link.mode) {
                    ForEach(DisplayLink.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Mode")
            } footer: {
                Text(link.mode.help + " Appui long sur le bouton du haut de l'écran pour changer de mode.")
            }

            Section("Mon texte") {
                TextField("Texte qui défile", text: $link.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack(spacing: 12) {
                    Text("Couleur du fond")
                    Spacer()
                    ForEach(DisplayLink.colors, id: \.hex) { c in
                        Button {
                            link.colorHex = c.hex
                        } label: {
                            Circle()
                                .fill(Color(displayHex: c.hex))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(.white, lineWidth: link.colorHex == c.hex ? 3 : 0))
                                .overlay(Circle().stroke(.gray.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.name)
                    }
                }
            }

            Section {
                Label("Bouton du haut : appui court = son suivant, appui long = changer de mode.", systemImage: "button.horizontal.top.press")
                Label("Bouton du bas : appui court = lecture / pause, appui long = luminosité.", systemImage: "button.horizontal.top.press")
            } header: {
                Text("Boutons de l'écran")
            }
            .font(.footnote)
        }
        .navigationTitle("Écran")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension Color {
    init(displayHex hex: String) {
        let v = UInt64(hex, radix: 16) ?? 0x4A148C
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
