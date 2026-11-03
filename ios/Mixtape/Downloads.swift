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

    private var tracks: [Track] {
        library.tracks.filter { downloads.isDownloaded($0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        let list = tracks
        List {
            if !list.isEmpty {
                PlayShuffleButtons(play: { player.play(list) }, shuffle: { player.play(list, shuffled: true) })
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track)
                    .onTapGesture { player.play(list, startAt: i) }
                    .swipeActions {
                        Button("Supprimer", role: .destructive) { downloads.remove([track]) }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if list.isEmpty {
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
