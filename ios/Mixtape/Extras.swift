import AVFoundation
import SwiftUI
import UIKit
import UserNotifications

// MARK: - Couleur de l'app

/// Couleur principale de l'app, au choix dans les Réglages.
enum AccentChoice: String, CaseIterable, Identifiable {
    case rose, rouge, orange, vert, menthe, bleu, violet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rose: return "Rose"
        case .rouge: return "Rouge"
        case .orange: return "Orange"
        case .vert: return "Vert"
        case .menthe: return "Menthe"
        case .bleu: return "Bleu"
        case .violet: return "Violet"
        }
    }

    var color: Color {
        switch self {
        case .rose: return Color(red: 0.98, green: 0.18, blue: 0.28)
        case .rouge: return Color(red: 0.90, green: 0.12, blue: 0.12)
        case .orange: return Color(red: 1.00, green: 0.48, blue: 0.10)
        case .vert: return Color(red: 0.16, green: 0.72, blue: 0.33)
        case .menthe: return Color(red: 0.10, green: 0.72, blue: 0.66)
        case .bleu: return Color(red: 0.16, green: 0.48, blue: 1.00)
        case .violet: return Color(red: 0.58, green: 0.32, blue: 0.98)
        }
    }

    /// Lu une seule fois, puis mis à jour quand tu changes de couleur.
    static var current: AccentChoice = AccentChoice(rawValue: UserDefaults.standard.string(forKey: "accentColor") ?? "") ?? .rose
}

extension Color {
    /// Couleur principale de l'app (rose par défaut).
    static var accentPink: Color { AccentChoice.current.color }
}

struct AccentPicker: View {
    @AppStorage("accentColor") private var accent = AccentChoice.rose.rawValue

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
            ForEach(AccentChoice.allCases) { choice in
                let on = choice.rawValue == accent
                Button {
                    AccentChoice.current = choice
                    withAnimation(.easeInOut(duration: 0.25)) { accent = choice.rawValue }
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(choice.color)
                            .frame(width: 36, height: 36)
                            .overlay(Circle().strokeBorder(.primary.opacity(on ? 0.9 : 0), lineWidth: 2.5).padding(-4))
                            .overlay {
                                if on { Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.white) }
                            }
                        Text(choice.label).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Temps d'écoute du jour

/// « 1 h 24 écoutées aujourd'hui » sur l'Accueil (mis à jour toutes les 30 secondes).
struct TodayListeningLine: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let seconds = Stats.shared.listenedToday()
            HStack(spacing: 8) {
                Image(systemName: "headphones")
                    .foregroundStyle(Color.accentPink)
                Text(seconds >= 60 ? "\(Self.format(seconds)) écoutées aujourd'hui" : "Pas encore d'écoute aujourd'hui")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : String(format: "%d h %02d", h, m)
    }
}

// MARK: - Sauvegarde sur le PC

/// Envoie favoris, historique, stats, réglages… au serveur, et les récupère si l'app est réinstallée.
@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()

    @Published private(set) var lastBackup: Date? = UserDefaults.standard.object(forKey: "lastBackupDate") as? Date
    @Published private(set) var isWorking = false
    @Published var message: String?

    /// Tout ce qui est gardé sur l'iPhone et mérite d'être sauvegardé.
    private let keys = [
        "favorites", "playCounts", "playHistory", "recentlyPlayed", "albumProgress", "listeningByDay",
        "reelsPenalties", "recentSearches", "lastSession", "autoplay", "standbyEnabled", "accentColor",
        "albumSort", "songSort", "albumFilter", "songFilter", "annotations", "showAnnotations", "partyHostName", "partyMode",
        "alarmEnabled", "alarmHour", "alarmMinute", "alarmRepeat", "alarmSource", "alarmTrackId",
        "animatedCoversOn", "staticCoverAlbums",
    ]

    private init() {}

    private var isLocalEmpty: Bool {
        let d = UserDefaults.standard
        return (d.stringArray(forKey: "favorites") ?? []).isEmpty
            && (d.dictionary(forKey: "playCounts") ?? [:]).isEmpty
            && d.data(forKey: "playHistory") == nil
    }

    /// Envoie la sauvegarde au PC (sans bloquer l'app).
    func upload(api: APIClient?, manual: Bool = false) async {
        guard let api, !isWorking else { return }
        Stats.shared.flush()
        let d = UserDefaults.standard
        var payload: [String: Any] = [:]
        for key in keys {
            guard let value = d.object(forKey: key) else { continue }
            if let data = value as? Data {
                payload[key] = ["__data": data.base64EncodedString()]
            } else if JSONSerialization.isValidJSONObject([value]) {
                payload[key] = value
            }
        }
        guard !payload.isEmpty, let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await api.putBackup(body)
            let now = Date()
            lastBackup = now
            d.set(now, forKey: "lastBackupDate")
            if manual { message = "Sauvegarde envoyée sur le PC." }
        } catch {
            if manual { message = "Le PC n'a pas répondu. Réessaie quand il est allumé." }
        }
    }

    /// Récupère la sauvegarde du PC. Automatique seulement si l'app est vide (réinstallation).
    func restore(api: APIClient?, player: PlayerModel?, onlyIfEmpty: Bool) async {
        guard let api, !isWorking else { return }
        if onlyIfEmpty && !isLocalEmpty { return }
        isWorking = true
        defer { isWorking = false }
        guard let data = try? await api.getBackup(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let saved = root["data"] as? [String: Any] else {
            if !onlyIfEmpty { message = "Aucune sauvegarde trouvée sur le PC." }
            return
        }
        let d = UserDefaults.standard
        for key in keys {
            guard let value = saved[key] else { continue }
            if let wrapped = value as? [String: Any], let b64 = wrapped["__data"] as? String, let raw = Data(base64Encoded: b64) {
                d.set(raw, forKey: key)
            } else {
                d.set(value, forKey: key)
            }
        }
        AccentChoice.current = AccentChoice(rawValue: d.string(forKey: "accentColor") ?? "") ?? .rose
        Stats.shared.reload()
        AnnotationStore.shared.reloadPrivate()
        player?.reloadSaved()
        message = "Sauvegarde récupérée : favoris, historique et stats sont de retour."
    }
}

// MARK: - Réveil Mixtape

/// Réveil : une notification à l'heure choisie, avec 30 secondes d'un son comme sonnerie.
@MainActor
final class AlarmManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AlarmManager()

    @Published private(set) var status: String = ""
    @Published private(set) var isPreparing = false

    private weak var library: LibraryStore?
    private weak var player: PlayerModel?
    private let requestID = "mixtape-alarm"

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func attach(library: LibraryStore, player: PlayerModel) {
        self.library = library
        self.player = player
    }

    private var defaults: UserDefaults { .standard }
    var enabled: Bool { defaults.bool(forKey: "alarmEnabled") }

    /// Recalcule le réveil (et tire un nouveau favori au hasard si besoin).
    func reschedule() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        guard enabled else { status = "Réveil désactivé"; return }
        guard let library else { return }

        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            status = "Autorise les notifications de Mixtape dans les Réglages de l'iPhone."
            return
        }
        guard let track = pickTrack(library: library) else {
            status = "Choisis un son (ou mets des sons en favoris)."
            return
        }

        isPreparing = true
        defer { isPreparing = false }
        let soundName = await makeAlarmSound(for: track, library: library)

        let content = UNMutableNotificationContent()
        content.title = "Réveil Mixtape"
        content.body = "« \(track.title) » · \(track.displayArtist)"
        content.sound = soundName.map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
        content.userInfo = ["trackId": track.id]

        var when = DateComponents()
        when.hour = defaults.object(forKey: "alarmHour") as? Int ?? 7
        when.minute = defaults.object(forKey: "alarmMinute") as? Int ?? 30
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: defaults.object(forKey: "alarmRepeat") as? Bool ?? true)
        do {
            try await center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: trigger))
            let time = String(format: "%d:%02d", when.hour ?? 0, when.minute ?? 0)
            status = "Réveil à \(time) avec « \(track.title) »" + (soundName == nil ? " (sonnerie par défaut : son pas disponible)" : "")
        } catch {
            status = "Impossible de programmer le réveil."
        }
    }

    private func pickTrack(library: LibraryStore) -> Track? {
        switch defaults.string(forKey: "alarmSource") ?? "favorites" {
        case "chosen":
            return defaults.string(forKey: "alarmTrackId").flatMap { library.track($0) }
        default:
            let favorites = library.tracks.filter { Stats.shared.isFavorite($0) }
            return (favorites.isEmpty ? library.tracks : favorites).randomElement()
        }
    }

    /// Découpe 30 secondes du son (vers le refrain) dans un fichier sonnerie que l'iPhone sait jouer.
    private func makeAlarmSound(for track: Track, library: LibraryStore) async -> String? {
        let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "mixtape-reveil-\(track.id).caf"
        let dest = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return name }
        // Un seul fichier de réveil à la fois.
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("mixtape-reveil-") {
            try? FileManager.default.removeItem(at: old)
        }

        var source = DownloadManager.shared.localURL(for: track)
        var temp: URL?
        if source == nil, let url = library.api?.streamURL(for: track),
           let result = try? await URLSession.shared.download(from: url),
           (result.1 as? HTTPURLResponse)?.statusCode == 200 {
            let tmp = result.0
            let named = FileManager.default.temporaryDirectory.appendingPathComponent("reveil-source.\(track.ext)")
            try? FileManager.default.removeItem(at: named)
            try? FileManager.default.moveItem(at: tmp, to: named)
            source = named
            temp = named
        }
        guard let source else { return nil }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }

        let start = track.duration > 60 ? track.duration * 0.35 : 0
        let ok = await Task.detached(priority: .userInitiated) {
            Self.writeExtract(from: source, to: dest, start: start, length: 29)
        }.value
        return ok ? name : nil
    }

    nonisolated private static func writeExtract(from source: URL, to dest: URL, start: Double, length: Double) -> Bool {
        do {
            let input = try AVAudioFile(forReading: source)
            let format = input.processingFormat
            let rate = format.sampleRate
            let startFrame = AVAudioFramePosition(start * rate)
            guard startFrame < input.length else { return false }
            input.framePosition = startFrame
            let frames = AVAudioFrameCount(min(length * rate, Double(input.length - startFrame)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return false }
            try input.read(into: buffer, frameCount: frames)

            // Fondu à l'entrée (3 s) et à la sortie (1 s) : un réveil en douceur.
            if let channels = buffer.floatChannelData {
                let n = Int(buffer.frameLength)
                let fadeIn = min(Int(3 * rate), n), fadeOut = min(Int(1 * rate), n)
                for c in 0..<Int(format.channelCount) {
                    let data = channels[c]
                    for i in 0..<fadeIn { data[i] *= Float(i) / Float(fadeIn) }
                    for i in 0..<fadeOut { data[n - 1 - i] *= Float(i) / Float(fadeOut) }
                }
            }

            try? FileManager.default.removeItem(at: dest)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let output = try AVAudioFile(forWriting: dest, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
            try output.write(from: buffer)
            return true
        } catch {
            return false
        }
    }

    // Notification touchée : on lance le son en entier.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let trackId = response.notification.request.content.userInfo["trackId"] as? String
        Task { @MainActor in
            if let trackId, let library = self.library, let track = library.track(trackId) {
                self.player?.play([track])
            }
            await self.reschedule()
            completionHandler()
        }
    }

    // Réveil pendant que l'app est ouverte : on l'affiche quand même, avec le son.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

struct AlarmSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var alarm = AlarmManager.shared
    @AppStorage("alarmEnabled") private var enabled = false
    @AppStorage("alarmHour") private var hour = 7
    @AppStorage("alarmMinute") private var minute = 30
    @AppStorage("alarmRepeat") private var repeats = true
    @AppStorage("alarmSource") private var source = "favorites"
    @AppStorage("alarmTrackId") private var trackId = ""

    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        } set: { date in
            hour = Calendar.current.component(.hour, from: date)
            minute = Calendar.current.component(.minute, from: date)
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("Réveil", isOn: $enabled).tint(Color.accentPink)
                DatePicker("Heure", selection: time, displayedComponents: .hourAndMinute)
                Toggle("Tous les jours", isOn: $repeats).tint(Color.accentPink)
            } footer: {
                if alarm.isPreparing {
                    Text("Préparation de la sonnerie…")
                } else if !alarm.status.isEmpty {
                    Text(alarm.status)
                }
            }

            Section {
                Picker("Son", selection: $source) {
                    Text("Au hasard dans mes favoris").tag("favorites")
                    Text("Un son précis").tag("chosen")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if source == "chosen" {
                    if let current = player.current {
                        Button {
                            trackId = current.id
                        } label: {
                            Label("Utiliser le son en cours : \(current.title)", systemImage: "music.note")
                        }
                    }
                    if let chosen = library.track(trackId) {
                        LabeledContent("Son choisi", value: "\(chosen.title) · \(chosen.displayArtist)")
                    } else {
                        Text("Lance un son puis touche « Utiliser le son en cours ».")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sonnerie")
            } footer: {
                Text("Mixtape joue 30 secondes du son, vers le refrain, avec un fondu. Touche la notification pour écouter le son en entier. L'iPhone doit être en mode sonnerie (pas en silencieux) pour l'entendre.")
            }
        }
        .navigationTitle("Réveil Mixtape")
        .task { await alarm.reschedule() }
        .onChange(of: enabled) { _, _ in Task { await alarm.reschedule() } }
        .onChange(of: hour) { _, _ in Task { await alarm.reschedule() } }
        .onChange(of: minute) { _, _ in Task { await alarm.reschedule() } }
        .onChange(of: repeats) { _, _ in Task { await alarm.reschedule() } }
        .onChange(of: source) { _, _ in Task { await alarm.reschedule() } }
        .onChange(of: trackId) { _, _ in Task { await alarm.reschedule() } }
    }
}

// MARK: - Mode soirée

/// Permet à un seul écran (le mode soirée) de passer à l'horizontale.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Prêt tout de suite à recevoir le réveil, même si l'app était fermée.
        UNUserNotificationCenter.current().delegate = AlarmManager.shared
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }

    static func lock(_ mask: UIInterfaceOrientationMask) {
        orientationLock = mask
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask == .portrait ? .portrait : .landscapeRight)) { _ in }
        }
    }
}

/// Plein écran en paysage pour une soirée : pochette géante, titre, et ce qui arrive ensuite.
/// À afficher sur la télé avec la recopie de l'écran (AirPlay).
struct PartyView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let track = player.current
            ZStack {
                BlurredBackdrop(url: library.coverURL(track))

                HStack(spacing: 44) {
                    ArtworkView(url: library.coverURL(track), cornerRadius: 20, placeholderSeed: track?.albumKey ?? "soiree")
                        .frame(width: h * 0.72, height: h * 0.72)
                        .shadow(color: .black.opacity(0.55), radius: 30, y: 14)
                        .id(track?.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("EN CE MOMENT")
                            .font(.caption.weight(.heavy))
                            .tracking(1.5)
                            .foregroundStyle(Color.accentPink)
                        Text(track?.title ?? "Lance un son pour démarrer la soirée")
                            .font(.system(size: max(28, h * 0.09), weight: .heavy))
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                        if let track {
                            Text(track.displayArtist)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.75))
                            MiniProgressLine()
                                .frame(maxWidth: 420)
                                .padding(.top, 6)
                        }

                        let next = Array(player.upNext.prefix(4))
                        if !next.isEmpty {
                            Text("À SUIVRE")
                                .font(.caption.weight(.heavy))
                                .tracking(1.5)
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.top, 18)
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(next) { t in
                                    VStack(alignment: .leading, spacing: 4) {
                                        ArtworkView(url: library.coverURL(t), cornerRadius: 8, placeholderSeed: t.albumKey)
                                            .frame(width: h * 0.17, height: h * 0.17)
                                        Text(t.title).font(.caption.weight(.semibold)).lineLimit(1)
                                    }
                                    .frame(width: h * 0.17)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 48)
                .foregroundStyle(.white)
                .animation(.easeInOut(duration: 0.5), value: track?.id)
            }
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 40, height: 40)
                        .liquidGlass(in: Circle(), interactive: true)
                }
                .foregroundStyle(.white)
                .padding(20)
                .accessibilityLabel("Quitter le mode soirée")
            }
            .overlay(alignment: .topTrailing) {
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(24)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 26) {
                    Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                }
                .font(.title2)
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .liquidGlass(in: Capsule())
                .padding(24)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            AppDelegate.lock(.landscape)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            AppDelegate.lock(.portrait)
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
