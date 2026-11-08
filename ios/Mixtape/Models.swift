import Foundation

struct Track: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var trackNumber: Int?
    var duration: Double
    var ext: String
    var hasCover: Bool
    var createdAt: Double
    var updatedAt: Double

    var displayArtist: String { artist.isEmpty ? "Artiste inconnu" : artist }

    /// Un son sans album est rangé comme un single, à la manière d'Apple Music.
    var albumKey: String {
        album.isEmpty ? "single:\(id)" : "album:\(album.lowercased())"
    }

    var displayAlbum: String { album.isEmpty ? "\(title) - Single" : album }
}

/// Infos en plus envoyées par le serveur : descriptions et crédits d'albums, photos d'artistes.
struct LibraryExtras: Codable {
    struct AlbumInfo: Codable { let artist: String; let album: String; let description: String; var credits: String? }
    struct ArtistInfo: Codable { let name: String; let photoVersion: Int }
    var albums: [AlbumInfo]
    var artists: [ArtistInfo]
    /// Sons qui ont un clip vidéo sur le PC.
    var clips: [String]?
}

struct Album: Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String
    let tracks: [Track]
    let isSingle: Bool

    var coverTrack: Track? { tracks.first(where: { $0.hasCover }) ?? tracks.first }
    var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }
    var latestAdded: Double { tracks.map(\.createdAt).max() ?? 0 }
}

struct Artist: Identifiable, Hashable {
    var id: String { name.lowercased() }
    let name: String
    let tracks: [Track]
    let albums: [Album]
    var coverTrack: Track? { tracks.first(where: { $0.hasCover }) ?? tracks.first }
}

struct Playlist: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var trackIds: [String]
    var createdAt: Double
    var updatedAt: Double
}

enum LibrarySection: String, Hashable, CaseIterable, Identifiable {
    case favorites = "Favoris"
    case playlists = "Playlists"
    case artists = "Artistes"
    case albums = "Albums"
    case songs = "Morceaux"
    case downloads = "Téléchargements"
    case history = "Historique"
    case replay = "Mixtape Replay"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .favorites: return "heart"
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .songs: return "music.note"
        case .downloads: return "arrow.down.circle"
        case .history: return "clock.arrow.circlepath"
        case .replay: return "chart.bar.fill"
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

func formatTotal(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes < 60 { return "\(minutes) minute\(minutes > 1 ? "s" : "")" }
    let h = minutes / 60, m = minutes % 60
    return m == 0 ? "\(h) h" : "\(h) h \(m) min"
}
