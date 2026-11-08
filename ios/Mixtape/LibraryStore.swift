import Foundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var api: APIClient?
    /// Sons affichés : tous, ou seulement les téléchargés quand le PC est injoignable.
    @Published private(set) var tracks: [Track] = [] { didSet { rebuildIndexes() } }
    /// Le PC ne répond pas : l'app passe toute seule en mode hors ligne.
    @Published private(set) var isOffline = false
    private var allTracks: [Track] = []
    private var retryTask: Task<Void, Never>?
    @Published var playlists: [Playlist] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [Artist] = []
    private var byId: [String: Track] = [:]
    private var lastExtras: LibraryExtras?
    private var albumsById: [String: Album] = [:]
    private var artistsByName: [String: Artist] = [:]
    /// Calculé une fois quand la bibliothèque change (et pas à chaque affichage).
    @Published private(set) var recentlyAdded: [Album] = []
    /// Texte du fichier « description » de chaque album (clé = id de l'album).
    @Published private(set) var albumDescriptions: [String: String] = [:]
    /// Fichier « credits » de chaque album, déjà découpé (clé = id de l'album).
    @Published private(set) var albumCredits: [String: AlbumCredits] = [:]
    /// Sons qui ont un clip vidéo.
    @Published private(set) var clipIds: Set<String> = []
    @Published private(set) var animatedCovers: [String: Int] = [:]
    /// Albums pour lesquels tu as choisi la pochette fixe.
    @Published private(set) var staticCoverAlbums: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "staticCoverAlbums") ?? [])
    /// Artistes qui ont une photo à eux (nom en minuscules → version de la photo).
    @Published private(set) var artistPhotos: [String: Int] = [:]

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
        allTracks = []
        tracks = []
        playlists = []
        setOffline(false)
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
            allTracks = newTracks
            setOffline(false)
            showTracks()
            playlists = newPlaylists
            errorMessage = nil
            // Descriptions et photos : facultatives (un ancien serveur ne les a pas).
            if let extras = try? await api.extras() { apply(extras) }
            saveCache()
        } catch APIError.unreachable {
            // Serveur éteint : pas d'alerte, on passe en mode hors ligne (sons téléchargés seulement).
            setOffline(true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func track(_ id: String) -> Track? { byId[id] }

    // MARK: Hors ligne

    private func setOffline(_ offline: Bool) {
        guard offline != isOffline else { return }
        isOffline = offline
        showTracks()
        retryTask?.cancel()
        retryTask = nil
        if offline {
            // Réessaie toutes les 20 secondes : dès que le PC répond, tout revient.
            retryTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    guard let self, self.isOffline, let api = self.api else { return }
                    if (try? await api.ping()) != nil {
                        await self.refresh()
                        return
                    }
                }
            }
        }
    }

    /// Met à jour la liste affichée (et donc albums, artistes, playlists automatiques…).
    func showTracks() {
        let visible = isOffline ? allTracks.filter { DownloadManager.shared.isDownloaded($0) } : allTracks
        if visible != tracks { tracks = visible }
    }

    func description(for album: Album) -> String? { albumDescriptions[album.id] }

    func credits(for album: Album) -> AlbumCredits? { albumCredits[album.id] }

    func hasClip(_ track: Track) -> Bool { clipIds.contains(track.id) }

    func hasAnimatedCover(_ album: Album) -> Bool { album.tracks.contains { animatedCovers[$0.id] != nil } }

    func usesStaticCover(_ album: Album) -> Bool { staticCoverAlbums.contains(album.id) }

    func setStaticCover(_ isStatic: Bool, for album: Album) {
        if isStatic { staticCoverAlbums.insert(album.id) } else { staticCoverAlbums.remove(album.id) }
        UserDefaults.standard.set(Array(staticCoverAlbums), forKey: "staticCoverAlbums")
    }

    /// Pochette animée de l'album de ce son (sauf si tu as choisi la pochette fixe pour cet album).
    func animatedCover(for track: Track) -> (url: URL, version: Int)? {
        guard let api, !staticCoverAlbums.contains(track.albumKey) else { return nil }
        // N'importe quel son de l'album convient : la vidéo est la même pour tout l'album.
        let source: Track? = animatedCovers[track.id] != nil ? track
            : albumsById[track.albumKey]?.tracks.first(where: { animatedCovers[$0.id] != nil })
        guard let source, let version = animatedCovers[source.id] else { return nil }
        return (api.animatedCoverURL(for: source, version: version), version)
    }

    /// Photo de l'artiste posée sur le PC, sinon la pochette d'un de ses albums.
    func artistImageURL(_ artist: Artist) -> URL? {
        artistImageURL(name: artist.name, fallback: artist.coverTrack)
    }

    func artistImageURL(name: String, fallback: Track?) -> URL? {
        if let version = artistPhotos[name.lowercased()], let api {
            return api.artistPhotoURL(name: name, version: version)
        }
        return coverURL(fallback ?? artist(named: name)?.coverTrack)
    }

    private func apply(_ extras: LibraryExtras) {
        lastExtras = extras
        let descriptions = Dictionary(extras.albums.map { ("album:\($0.album.lowercased())", $0.description) },
                                      uniquingKeysWith: { a, _ in a })
        let photos = Dictionary(extras.artists.map { ($0.name.lowercased(), $0.photoVersion) }, uniquingKeysWith: { a, _ in a })
        if descriptions != albumDescriptions { albumDescriptions = descriptions }
        var credits: [String: AlbumCredits] = [:]
        for info in extras.albums {
            guard let text = info.credits, !text.isEmpty else { continue }
            let parsed = AlbumCredits(text: text)
            if !parsed.isEmpty { credits["album:\(info.album.lowercased())"] = parsed }
        }
        if credits != albumCredits { albumCredits = credits }
        let clips = Set(extras.clips ?? [])
        if clips != clipIds { clipIds = clips }
        let animated = extras.animatedCovers ?? [:]
        if animated != animatedCovers { animatedCovers = animated }
        if photos != artistPhotos { artistPhotos = photos }
    }

    func tracks(of playlist: Playlist) -> [Track] {
        playlist.trackIds.compactMap { byId[$0] }
    }

    func album(for track: Track) -> Album? { albumsById[track.albumKey] }

    func album(id: String) -> Album? { albumsById[id] }

    func artist(named name: String) -> Artist? { artistsByName[name.lowercased()] }

    func coverURL(_ track: Track?) -> URL? {
        guard let track, let api else { return nil }
        return api.coverURL(for: track)
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
        albumsById = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        artistsByName = Dictionary(artists.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        recentlyAdded = Array(albums.sorted { $0.latestAdded > $1.latestAdded }.prefix(12))
    }

    private static func mostCommon(_ values: [String]) -> String? {
        let counts = Dictionary(values.filter { !$0.isEmpty }.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key
    }

    // MARK: Cache (affiche la bibliothèque même avant la réponse du serveur)

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("library.json")
    }

    private struct Cache: Codable { let tracks: [Track]; let playlists: [Playlist]; var extras: LibraryExtras? }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(Cache(tracks: allTracks, playlists: playlists, extras: lastExtras)) {
            try? data.write(to: cacheURL)
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        allTracks = cache.tracks
        tracks = cache.tracks
        playlists = cache.playlists
        rebuildIndexes()
        if let extras = cache.extras { apply(extras) }
    }
}
