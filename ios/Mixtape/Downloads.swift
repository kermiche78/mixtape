import Foundation
import SwiftUI

/// Téléchargements pour écouter sans réseau (dans le métro, en avion…).
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var downloaded: Set<String> = []
    @Published private(set) var inProgress: Set<String> = []

    private let folder: URL
    private let indexKey = "downloadedTracks"

    private init() {
        folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Telechargements", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var f = folder
        try? f.setResourceValues(excluded)
        let saved = UserDefaults.standard.stringArray(forKey: indexKey) ?? []
        if UserDefaults.standard.stringArray(forKey: "wantedDownloads") == nil, !saved.isEmpty {
            UserDefaults.standard.set(saved, forKey: "wantedDownloads")
        }
        downloaded = Set(saved.filter { id in
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.contains { $0.hasPrefix(id + ".") } ?? false
        })
    }

    func isDownloaded(_ track: Track) -> Bool { downloaded.contains(track.id) }
    func isDownloading(_ track: Track) -> Bool { inProgress.contains(track.id) }

    func localURL(for track: Track) -> URL? {
        guard downloaded.contains(track.id) else { return nil }
        let url = folder.appendingPathComponent("\(track.id).\(track.ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Liste des sons voulus (sauvegardée sur le PC)
    //
    // Les fichiers restent sur l'iPhone, mais la liste des sons que tu as téléchargés part avec la
    // sauvegarde sur le PC : après une réinstallation, « Retélécharger mes sons » les récupère tous.
    private let wantedKey = "wantedDownloads"

    private var wanted: Set<String> {
        get {
            if let list = UserDefaults.standard.stringArray(forKey: wantedKey) { return Set(list) }
            // Avant cette version : l'ancienne liste (même si les fichiers ont disparu).
            return Set(UserDefaults.standard.stringArray(forKey: indexKey) ?? []).union(downloaded)
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: wantedKey) }
    }

    /// Sons téléchargés autrefois mais absents de l'iPhone (après une réinstallation par exemple).
    func missing(in library: LibraryStore) -> [Track] {
        let ids = wanted.subtracting(downloaded).subtracting(inProgress)
        return ids.compactMap { library.track($0) }.sorted { $0.title < $1.title }
    }

    func redownloadMissing(library: LibraryStore) {
        download(missing(in: library), api: library.api)
    }

    // MARK: File d'attente (3 téléchargements à la fois, pour les gros lots comme les favoris)
    private var queue: [(track: Track, source: URL)] = []
    private var running = 0
    private let maxParallel = 3

    /// Avancement (0 → 1) des sons en train de se télécharger. Absent = pas encore commencé.
    @Published private(set) var progress: [String: Double] = [:]
    /// Sons dont le téléchargement a échoué (PC injoignable, coupure réseau…).
    @Published private(set) var failed: Set<String> = []
    /// Taille du lot en cours, pour la barre globale (« 5 sur 12 »).
    @Published private(set) var batchTotal = 0

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var observers: [String: NSKeyValueObservation] = [:]
    private var cancelled: Set<String> = []

    /// Nombre de sons qui restent à télécharger dans le lot en cours.
    var remaining: Int { inProgress.count }

    /// En file d'attente, pas encore commencé.
    func isQueued(_ track: Track) -> Bool { inProgress.contains(track.id) && progress[track.id] == nil }
    func fraction(_ track: Track) -> Double? { progress[track.id] }
    func hasFailed(_ track: Track) -> Bool { failed.contains(track.id) }

    /// Avancement d'un album ou d'une playlist : sons finis, total, et pourcentage (sons en cours compris).
    func status(of tracks: [Track]) -> (done: Int, total: Int, fraction: Double) {
        let done = tracks.filter { downloaded.contains($0.id) }.count
        let partial = tracks.reduce(0.0) { $0 + (progress[$1.id] ?? 0) }
        let total = max(tracks.count, 1)
        return (done, tracks.count, min(1, (Double(done) + partial) / Double(total)))
    }

    /// Avancement de tout ce qui se télécharge en ce moment.
    var batchFraction: Double {
        guard batchTotal > 0 else { return 0 }
        let finished = batchTotal - inProgress.count
        let partial = progress.values.reduce(0, +)
        return min(1, (Double(finished) + partial) / Double(batchTotal))
    }

    func download(_ tracks: [Track], api: APIClient?) {
        guard let api else { return }
        if inProgress.isEmpty { batchTotal = 0 }
        var list = wanted
        for track in tracks where !downloaded.contains(track.id) && !inProgress.contains(track.id) {
            inProgress.insert(track.id)
            failed.remove(track.id)
            batchTotal += 1
            list.insert(track.id)
            queue.append((track, api.streamURL(for: track)))
        }
        for track in tracks { list.insert(track.id) }
        wanted = list
        pump()
    }

    /// Arrête le téléchargement de ces sons. Ceux déjà finis restent sur l'iPhone.
    func cancel(_ tracks: [Track]) {
        let ids = Set(tracks.map(\.id))
        let queued = Set(queue.map(\.track.id)).intersection(ids)
        queue.removeAll { ids.contains($0.track.id) }
        inProgress.subtract(queued)
        batchTotal = max(0, batchTotal - queued.count)
        for id in ids where tasks[id] != nil {
            cancelled.insert(id)
            tasks[id]?.cancel()
        }
        failed.subtract(ids)
        wanted = wanted.subtracting(ids.subtracting(downloaded))
    }

    func retryFailed(_ tracks: [Track], api: APIClient?) {
        download(tracks.filter { failed.contains($0.id) }, api: api)
    }

    private func pump() {
        while running < maxParallel, !queue.isEmpty {
            let item = queue.removeFirst()
            running += 1
            Task {
                let ok = await fetch(item.track, from: item.source)
                let id = item.track.id
                running -= 1
                inProgress.remove(id)
                progress[id] = nil
                tasks[id] = nil
                observers[id]?.invalidate()
                observers[id] = nil
                if cancelled.remove(id) != nil {
                    batchTotal = max(0, batchTotal - 1)
                } else if !ok {
                    failed.insert(id)
                }
                if inProgress.isEmpty { batchTotal = 0 }
                pump()
            }
        }
    }

    private func report(_ id: String, _ value: Double) {
        guard inProgress.contains(id) else { return }
        // Pas plus d'une mise à jour par pour-cent : l'écran reste fluide.
        if let old = progress[id], value < 1, abs(value - old) < 0.01 { return }
        progress[id] = value
    }

    private func fetch(_ track: Track, from source: URL) async -> Bool {
        let id = track.id
        let dest = folder.appendingPathComponent("\(track.id).\(track.ext)")
        progress[id] = 0
        let ok: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let task = URLSession.shared.downloadTask(with: source) { @Sendable tmp, response, _ in
                var success = false
                if let tmp, (response as? HTTPURLResponse)?.statusCode == 200 {
                    try? FileManager.default.removeItem(at: dest)
                    success = (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
                }
                cont.resume(returning: success)
            }
            observers[id] = task.progress.observe(\.fractionCompleted, options: [.new]) { @Sendable p, _ in
                let value = p.fractionCompleted
                Task { @MainActor in DownloadManager.shared.report(id, value) }
            }
            tasks[id] = task
            task.resume()
        }
        if ok {
            downloaded.insert(id)
            save()
        } else {
            try? FileManager.default.removeItem(at: dest)
        }
        return ok
    }

    func remove(_ tracks: [Track]) {
        let ids = Set(tracks.map(\.id))
        cancel(tracks)
        for track in tracks {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(track.id).\(track.ext)"))
            downloaded.remove(track.id)
        }
        wanted = wanted.subtracting(ids)
        save()
    }

    func removeAll() {
        queue.removeAll()
        inProgress.subtract(inProgress.filter { tasks[$0] == nil })
        for (id, task) in tasks { cancelled.insert(id); task.cancel() }
        failed = []
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        downloaded = []
        wanted = []
        save()
    }

    /// Espace occupé, pour l'afficher dans les réglages.
    var totalSize: String {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func save() {
        UserDefaults.standard.set(Array(downloaded), forKey: indexKey)
    }
}

/// Anneau qui se remplit au fil du téléchargement.
struct ProgressRing: View {
    let value: Double
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2.2
    var showStop = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.03, value))
                .stroke(Color.accentPink, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: value)
            if showStop {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentPink)
                    .frame(width: size * 0.28, height: size * 0.28)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Petite icône d'état à côté d'un son : en attente, pourcentage, téléchargé, échec.
struct DownloadBadge: View {
    @ObservedObject private var downloads = DownloadManager.shared
    let track: Track

    var body: some View {
        if downloads.isQueued(track) {
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("En attente de téléchargement")
        } else if let value = downloads.fraction(track) {
            ProgressRing(value: value, size: 15)
                .accessibilityLabel("Téléchargement \(Int(value * 100)) %")
        } else if downloads.isDownloaded(track) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Téléchargé")
        } else if downloads.hasFailed(track) {
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(Color.accentPink)
                .accessibilityLabel("Échec du téléchargement")
        }
    }
}

/// Bouton « télécharger tout » pour un album ou une playlist.
/// Pendant le téléchargement, l'anneau se remplit ; le toucher arrête.
struct DownloadAllButton: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var downloads = DownloadManager.shared
    let tracks: [Track]

    var body: some View {
        let done = !tracks.isEmpty && tracks.allSatisfy { downloads.isDownloaded($0) }
        let busy = tracks.contains { downloads.isDownloading($0) }
        Button {
            if busy { downloads.cancel(tracks) }
            else if done { downloads.remove(tracks) }
            else { downloads.download(tracks, api: library.api) }
        } label: {
            if busy {
                ProgressRing(value: downloads.status(of: tracks).fraction, size: 22, lineWidth: 2.5, showStop: true)
            } else {
                Image(systemName: done ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
        }
        .accessibilityLabel(busy ? "Arrêter le téléchargement" : done ? "Supprimer les téléchargements" : "Tout télécharger")
    }
}

/// Carte sur la page d'un album : « 5 sur 12 sons · 42 % », avec une barre qui avance.
struct AlbumDownloadCard: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var downloads = DownloadManager.shared
    let tracks: [Track]

    var body: some View {
        let busy = tracks.contains { downloads.isDownloading($0) }
        let failures = tracks.filter { downloads.hasFailed($0) }.count
        if busy || failures > 0 {
            let s = downloads.status(of: tracks)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        if busy {
                            Text("Téléchargement en cours").font(.headline)
                            Text("\(s.done) sur \(s.total) son\(s.total > 1 ? "s" : "") · \(Int(s.fraction * 100)) %")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                                .animation(.default, value: s.done)
                        } else {
                            Text("Téléchargement incomplet").font(.headline)
                            Text("\(failures) son\(failures > 1 ? "s n'ont" : " n'a") pas pu être téléchargé\(failures > 1 ? "s" : "")")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        if busy { downloads.cancel(tracks) } else { downloads.retryFailed(tracks, api: library.api) }
                    } label: {
                        Text(busy ? "Annuler" : "Réessayer")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(busy ? Color.primary : .black)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(busy ? AnyShapeStyle(Color.primary.opacity(0.15)) : AnyShapeStyle(Color.white), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if busy {
                    ProgressView(value: s.fraction)
                        .tint(Color.accentPink)
                        .animation(.linear(duration: 0.25), value: s.fraction)
                }
            }
            .padding(16)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var downloads = DownloadManager.shared
    @AppStorage("downloadsMode") private var mode = 0   // 0 = Albums, 1 = Morceaux
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    /// Albums qui ont au moins un son téléchargé, rangés par artiste puis par nom,
    /// avec uniquement leurs sons téléchargés, dans l'ordre de l'album.
    private var albums: [(album: Album, tracks: [Track])] {
        var result: [(album: Album, tracks: [Track])] = []
        for album in library.albums {
            let kept = album.tracks.filter { downloads.isDownloaded($0) }
            if !kept.isEmpty { result.append((album: album, tracks: kept)) }
        }
        result.sort { a, b in
            let c = a.album.artist.localizedCaseInsensitiveCompare(b.album.artist)
            if c != .orderedSame { return c == .orderedAscending }
            return a.album.name.localizedCaseInsensitiveCompare(b.album.name) == .orderedAscending
        }
        return result
    }

    var body: some View {
        let groups = albums
        // Lecture dans l'ordre : album par album, sans mélanger les artistes.
        let ordered = groups.flatMap { $0.tracks }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RedownloadBanner()
                if !groups.isEmpty {
                    Picker("Affichage", selection: $mode) {
                        Text("Albums").tag(0)
                        Text("Morceaux").tag(1)
                    }
                    .pickerStyle(.segmented)

                    PlayShuffleButtons(play: { player.play(ordered) }, shuffle: { player.play(ordered, shuffled: true) })
                }

                if mode == 0 {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(groups, id: \.album.id) { group in
                            NavigationLink(value: group.album) {
                                VStack(alignment: .leading, spacing: 2) {
                                    AlbumCell(album: group.album)
                                    if group.tracks.count < group.album.tracks.count {
                                        Text("\(group.tracks.count)/\(group.album.tracks.count) téléchargés")
                                            .font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.album.id) { group in
                            Section {
                                ForEach(Array(group.tracks.enumerated()), id: \.element.id) { i, track in
                                    TrackRow(track: track)
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                        // Touche un son : l'album continue dans l'ordre à partir de là.
                                        .onTapGesture { player.play(group.tracks, startAt: i) }
                                        .swipeToPlayNext(track)
                                        .contextMenu {
                                            Button(role: .destructive) { downloads.remove([track]) } label: {
                                                Label("Supprimer le téléchargement", systemImage: "trash")
                                            }
                                        }
                                    Divider().padding(.leading, 60)
                                }
                            } header: {
                                NavigationLink(value: group.album) {
                                    HStack(spacing: 6) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(group.album.isSingle ? (group.album.tracks.first?.title ?? group.album.name) : group.album.name)
                                                .font(.headline).lineLimit(1)
                                            Text(group.album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.bar)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 10)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("Aucun téléchargement", systemImage: "arrow.down.circle")
                } description: {
                    Text("Touche « … » sur un son, ou la flèche en haut d'un album, pour l'écouter sans réseau.")
                }
            }
        }
        .navigationTitle("Téléchargements")
    }
}

/// « 42 sons à retélécharger » : après une réinstallation, récupère d'un coup tous tes téléchargements.
struct RedownloadBanner: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        let missing = downloads.missing(in: library)
        if !missing.isEmpty || downloads.remaining > 0 {
            HStack(spacing: 12) {
                Image(systemName: downloads.remaining > 0 ? "arrow.down.circle.dotted" : "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentPink)
                VStack(alignment: .leading, spacing: 2) {
                    if downloads.remaining > 0 {
                        Text("Téléchargement en cours").font(.subheadline.weight(.semibold))
                        Text("Encore \(downloads.remaining) son\(downloads.remaining > 1 ? "s" : "") · \(Int(downloads.batchFraction * 100)) %")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: downloads.batchFraction)
                            .tint(Color.accentPink)
                            .padding(.top, 4)
                    } else {
                        Text("\(missing.count) son\(missing.count > 1 ? "s" : "") à retélécharger").font(.subheadline.weight(.semibold))
                        Text("Ils étaient téléchargés avant mais ne sont plus sur l'iPhone.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if downloads.remaining == 0 {
                    Button("Retélécharger") { downloads.redownloadMissing(library: library) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentPink)
                        .controlSize(.small)
                }
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
