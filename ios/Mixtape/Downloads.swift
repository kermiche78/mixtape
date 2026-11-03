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

    func download(_ tracks: [Track], api: APIClient?) {
        guard let api else { return }
        for track in tracks where !downloaded.contains(track.id) && !inProgress.contains(track.id) {
            inProgress.insert(track.id)
            let source = api.streamURL(for: track)
            let dest = folder.appendingPathComponent("\(track.id).\(track.ext)")
            Task {
                do {
                    let (tmp, response) = try await URLSession.shared.download(from: source)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    downloaded.insert(track.id)
                    save()
                } catch {
                    try? FileManager.default.removeItem(at: dest)
                }
                inProgress.remove(track.id)
            }
        }
    }

    func remove(_ tracks: [Track]) {
        for track in tracks {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(track.id).\(track.ext)"))
            downloaded.remove(track.id)
        }
        save()
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        downloaded = []
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

/// Petite icône d'état à côté d'un son : téléchargé, en cours…
struct DownloadBadge: View {
    @ObservedObject private var downloads = DownloadManager.shared
    let track: Track

    var body: some View {
        if downloads.isDownloading(track) {
            ProgressView().controlSize(.mini)
        } else if downloads.isDownloaded(track) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Téléchargé")
        }
    }
}

/// Bouton « télécharger tout » pour un album ou une playlist.
struct DownloadAllButton: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var downloads = DownloadManager.shared
    let tracks: [Track]

    var body: some View {
        let done = !tracks.isEmpty && tracks.allSatisfy { downloads.isDownloaded($0) }
        let busy = tracks.contains { downloads.isDownloading($0) }
        Button {
            if done { downloads.remove(tracks) } else { downloads.download(tracks, api: library.api) }
        } label: {
            if busy {
                ProgressView()
            } else {
                Image(systemName: done ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
        }
        .accessibilityLabel(done ? "Supprimer les téléchargements" : "Tout télécharger")
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
