import SwiftUI
import UIKit

// MARK: - Écoute à deux

/// Session d'écoute partagée : le PC garde l'état, l'iPhone le met à jour et suit ce que font les invités.
@MainActor
final class PartySession: ObservableObject {
    static let shared = PartySession()

    @Published private(set) var state: PartyState?
    @Published private(set) var isStarting = false
    @Published var message: String?
    @Published var mode: String = UserDefaults.standard.string(forKey: "partyMode") ?? "all" {
        didSet {
            UserDefaults.standard.set(mode, forKey: "partyMode")
            modeDirty = true
        }
    }

    private weak var library: LibraryStore?
    private weak var player: PlayerModel?
    private var loop: Task<Void, Never>?
    private var lastVersion = 0
    private var lastPushed: Snapshot?
    private var lastPushAt = Date.distantPast
    /// Après avoir suivi un invité, on laisse le lecteur se mettre en place avant de renvoyer quoi que ce soit.
    private var holdUntil = Date.distantPast
    private var modeDirty = false

    private struct Snapshot: Equatable {
        let ids: [String]
        let index: Int
        let playing: Bool
    }

    var isActive: Bool { state != nil }

    var link: URL? {
        guard let code = state?.code else { return nil }
        return library?.api?.partyLink(code: code)
    }

    /// Prénoms des invités connectés en ce moment.
    var guestNames: [String] { state?.guests.map(\.name) ?? [] }

    private init() {}

    func start(library: LibraryStore, player: PlayerModel) async {
        guard let api = library.api, !isStarting else { return }
        self.library = library
        self.player = player
        isStarting = true
        defer { isStarting = false }
        message = nil
        let host = UserDefaults.standard.string(forKey: "partyHostName") ?? ""
        do {
            let created = try await api.partyCreate([
                "mode": mode, "host": host.isEmpty ? "Kermiche" : host,
                "queue": player.queue.map(\.id), "index": player.index,
                "position": player.currentTime, "playing": player.isPlaying,
            ])
            state = created
            lastVersion = created.version
            lastPushed = snapshot()
            lastPushAt = Date()
            modeDirty = false
            startLoop()
        } catch {
            message = "Impossible de lancer l'écoute : \(error.localizedDescription)"
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if let code = state?.code, let api = library?.api {
            Task { await api.partyEnd(code: code) }
        }
        state = nil
    }

    private func snapshot() -> Snapshot? {
        guard let player else { return nil }
        return Snapshot(ids: player.queue.map(\.id), index: player.index, playing: player.isPlaying)
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func tick() async {
        guard let api = library?.api, let code = state?.code, let player else { return }
        do {
            guard let remote = try await api.partyState(code: code) else { ended(); return }
            if remote.version != lastVersion, remote.by != "host" {
                follow(remote)
                return
            }
            state = remote
            lastVersion = remote.version
            guard Date() >= holdUntil else { return }

            let snap = snapshot()
            let drift = abs(player.currentTime - remote.currentPosition)
            let changed = snap != lastPushed || modeDirty || (player.isPlaying && drift > 1.5)
            let refresh = player.isPlaying && Date().timeIntervalSince(lastPushAt) > 5
            guard changed || refresh else { return }

            let result = try await api.partyUpdate(code: code, fields: [
                "queue": player.queue.map(\.id), "index": player.index, "position": player.currentTime,
                "playing": player.isPlaying, "mode": mode, "baseVersion": lastVersion,
            ])
            if let s = result.state {
                if result.conflict {
                    follow(s)
                } else {
                    state = s
                    lastVersion = s.version
                    lastPushed = snap
                    lastPushAt = Date()
                    modeDirty = false
                }
            } else {
                ended()
            }
        } catch {
            // PC injoignable un instant : on réessaie à la seconde suivante.
        }
    }

    /// Un invité a changé quelque chose : l'iPhone s'aligne.
    private func follow(_ remote: PartyState) {
        state = remote
        lastVersion = remote.version
        guard let library, let player else { return }
        let currentId = remote.queue.indices.contains(remote.index) ? remote.queue[remote.index] : nil
        let tracks = remote.queue.compactMap { library.track($0) }
        let index = currentId.flatMap { id in tracks.firstIndex(where: { $0.id == id }) } ?? 0
        player.sync(queue: tracks, index: index, position: remote.currentPosition, playing: remote.playing)
        lastPushed = Snapshot(ids: tracks.map(\.id), index: index, playing: remote.playing)
        lastPushAt = Date()
        holdUntil = Date().addingTimeInterval(2)
    }

    private func ended() {
        loop?.cancel()
        loop = nil
        state = nil
        message = "L'écoute à deux est terminée."
    }

    func addedBy(_ track: Track) -> String? { state?.addedBy[track.id] }
}

// MARK: - Écrans

/// Fiche « Écouter avec quelqu'un » : lien, droits des invités, qui écoute, ce qui arrive.
struct PartySheet: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var party = PartySession.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("partyHostName") private var hostName = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "headphones")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(Color.accentPink, in: Circle())
                        Text("Écouter avec quelqu'un").font(.title3.bold())
                        Text("Envoie le lien. Ton pote écoute la même chose au même moment, depuis Safari, sans rien installer.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                if let link = party.link {
                    Section {
                        Button {
                            UIPasteboard.general.url = link
                            copied = true
                        } label: {
                            HStack {
                                Text(link.absoluteString).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            }
                        }
                        .foregroundStyle(.primary)
                        ShareLink(item: link, message: Text("Viens écouter avec moi sur Mixtape 🎧")) {
                            Label("Envoyer le lien", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .tint(Color.accentPink)
                    } footer: {
                        if link.scheme == "http" {
                            Text("Ton adresse de serveur est une adresse de la maison : le lien ne marchera que pour quelqu'un connecté à ton Wi-Fi.")
                        }
                    }

                    Section("En écoute") {
                        HStack {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text(hostName.isEmpty ? "Toi" : "\(hostName) (toi)")
                        }
                        if party.guestNames.isEmpty {
                            Text("Personne pour l'instant. Envoie le lien !").foregroundStyle(.secondary)
                        }
                        ForEach(party.guestNames, id: \.self) { name in
                            HStack {
                                Circle().fill(.green).frame(width: 8, height: 8)
                                Text(name)
                            }
                        }
                    }
                }

                Section {
                    Picker("Les invités peuvent", selection: $party.mode) {
                        Text("Tout choisir").tag("all")
                        Text("Ajouter").tag("add")
                        Text("Écouter").tag("listen")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Les invités peuvent")
                } footer: {
                    switch party.mode {
                    case "all": Text("Lancer un son, mettre pause, passer au suivant et ajouter des sons à la file.")
                    case "add": Text("Seulement ajouter des sons à la suite. Toi seul contrôles la lecture.")
                    default: Text("Ils écoutent, c'est toi qui choisis tout.")
                    }
                }

                if !party.isActive {
                    Section {
                        TextField("Ton prénom (affiché aux invités)", text: $hostName)
                            .textInputAutocapitalization(.words)
                    }
                    Section {
                        Button {
                            Task { await party.start(library: library, player: player) }
                        } label: {
                            HStack {
                                Spacer()
                                if party.isStarting { ProgressView() } else { Text("Lancer l'écoute").font(.headline) }
                                Spacer()
                            }
                        }
                        .tint(Color.accentPink)
                    } footer: {
                        if let message = party.message { Text(message) }
                    }
                } else {
                    let upNext = Array(player.upNext.prefix(10))
                    if !upNext.isEmpty {
                        Section("À suivre") {
                            ForEach(upNext) { track in
                                HStack(spacing: 10) {
                                    ArtworkView(url: library.coverURL(track), cornerRadius: 5, placeholderSeed: track.albumKey)
                                        .frame(width: 40, height: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title).lineLimit(1)
                                        Text(party.addedBy(track).map { "mis par \($0)" } ?? track.displayArtist)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        Button("Arrêter l'écoute à deux", role: .destructive) { party.stop() }
                    }
                }
            }
            .navigationTitle("Écoute à deux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("OK") { dismiss() } }
            }
        }
    }
}

/// Bandeau en haut du lecteur pendant une écoute à deux.
struct PartyBanner: View {
    @ObservedObject private var party = PartySession.shared
    @State private var showSheet = false

    var body: some View {
        if party.isActive {
            Button { showSheet = true } label: {
                HStack(spacing: 8) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(party.guestNames.isEmpty ? "Écoute à deux · en attente d'invités"
                         : "En écoute avec \(ListFormatter.localizedString(byJoining: party.guestNames))")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: -8) {
                        ForEach(party.guestNames.prefix(3), id: \.self) { name in
                            Text(String(name.prefix(1)).uppercased())
                                .font(.caption2.bold())
                                .frame(width: 22, height: 22)
                                .background(Color.accentPink, in: Circle())
                                .overlay(Circle().strokeBorder(.black.opacity(0.3), lineWidth: 1))
                        }
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .liquidGlass(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSheet) { PartySheet() }
        }
    }
}
