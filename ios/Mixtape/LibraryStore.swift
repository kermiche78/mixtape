import Foundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var api: APIClient?
    @Published var tracks: [Track] = [] { didSet { rebuildIndexes() } }
    @Published var playlists: [Playlist] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [Artist] = []
    private var byId: [String: Track] = [:]

    private var savedAddress: String {
        get { UserDefaults.standard.string(forKey: "serverAddress") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "serverAddress") }
    }
    private var savedPassword: String {
        get { UserDefaults.standard.string(forKey: "serverPassword") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "serverPassword") }
    }

    var serverAddress: String { savedAddress }
    var isConfigured: Bool { api != nil }

    init() {
        if !savedAddress.isEmpty, !savedPassword.isEmpty {
            api = APIClient(address: savedAddress, token: savedPassword)
            loadCache()
        }
    }

    // MARK: Connexion

    func connect(address: String, password: String) async throws {
        guard let client = APIClient(address: address, token: password) else { throw APIError.badURL }
        try await client.ping()
        savedAddress = client.baseURL.absoluteString
        savedPassword = password
        api = client
        await refresh()
    }

    func disconnect() {
        savedAddress = ""
        savedPassword = ""
        api = nil
        tracks = []
        playlists = []
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: Chargement

    func refresh() async {
        guard let api else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let t = api.tracks()
            async let p = api.playlists()
            let (newTracks, newPlaylists) = try await (t, p)
            tracks = newTracks
            playlists = newPlaylists
            errorMessage = nil
            saveCache()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func track(_ id: String) -> Track? { byId[id] }

    func tracks(of playlist: Playlist) -> [Track] {
        playlist.trackIds.compactMap { byId[$0] }
    }

    func album(for track: Track) -> Album? {
        albums.first { $0.id == track.albumKey }
    }

    func artist(named name: String) -> Artist? {
        artists.first { $0.name.lowercased() == name.lowercased() }
    }

    func coverURL(_ track: Track?) -> URL? {
        guard let track, let api else { return nil }
        return api.coverURL(for: track)
    }

    var recentlyAdded: [Album] {
        Array(albums.sorted { $0.latestAdded > $1.latestAdded }.prefix(12))
    }

    // MARK: Playlists

    func createPlaylist(name: String, trackIds: [String] = []) async {
        guard let api else { return }
        do {
            let p = try await api.createPlaylist(name: name, trackIds: trackIds)
            playlists.insert(p, at: 0)
        } catch { errorMessage = error.localizedDescription }
    }

    func savePlaylist(_ playlist: Playlist) async {
        guard let api else { return }
        if let i = playlists.firstIndex(where: { $0.id == playlist.id }) { playlists[i] = playlist }
        do {
            let saved = try await api.updatePlaylist(playlist)
            if let i = playlists.firstIndex(where: { $0.id == saved.id }) { playlists[i] = saved }
        } catch { errorMessage = error.localizedDescription }
    }

    func add(_ track: Track, to playlist: Playlist) async {
        var p = playlist
        p.trackIds.append(track.id)
        await savePlaylist(p)
    }

    func deletePlaylist(_ playlist: Playlist) async {
        guard let api else { return }
        playlists.removeAll { $0.id == playlist.id }
        do { try await api.deletePlaylist(id: playlist.id) } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Index

    private func rebuildIndexes() {
        byId = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let grouped = Dictionary(grouping: tracks, by: \.albumKey)
        albums = grouped.map { key, list in
            let sorted = list.sorted {
                switch ($0.trackNumber, $1.trackNumber) {
                case let (a?, b?) where a != b: return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            }
            let artist = Self.mostCommon(sorted.map(\.artist)) ?? ""
            return Album(id: key, name: sorted.first?.displayAlbum ?? "", artist: artist.isEmpty ? "Artiste inconnu" : artist,
                         tracks: sorted, isSingle: key.hasPrefix("single:"))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let byArtist = Dictionary(grouping: tracks) { $0.displayArtist }
        artists = byArtist.map { name, list in
            let keys = Set(list.map(\.albumKey))
            return Artist(name: name,
                          tracks: list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending },
                          albums: albums.filter { keys.contains($0.id) })
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func mostCommon(_ values: [String]) -> String? {
        let counts = Dictionary(values.filter { !$0.isEmpty }.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key
    }

    // MARK: Cache (affiche la bibliothèque même avant la réponse du serveur)

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("library.json")
    }

    private struct Cache: Codable { let tracks: [Track]; let playlists: [Playlist] }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(Cache(tracks: tracks, playlists: playlists)) {
            try? data.write(to: cacheURL)
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        tracks = cache.tracks
        playlists = cache.playlists
        rebuildIndexes()
    }
}
