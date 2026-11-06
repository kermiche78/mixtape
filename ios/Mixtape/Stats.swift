import Foundation
import SwiftUI

/// Favoris et nombre d'écoutes, gardés sur l'iPhone.
@MainActor
final class Stats: ObservableObject {
    static let shared = Stats()

    @Published private(set) var favorites: Set<String>
    @Published private(set) var playCounts: [String: Int]
    /// Historique des écoutes, du plus récent au plus ancien.
    @Published private(set) var history: [PlayEvent]

    private static let historyLimit = 3000

    private init() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
        playCounts = UserDefaults.standard.dictionary(forKey: "playCounts") as? [String: Int] ?? [:]
        if let data = UserDefaults.standard.data(forKey: "playHistory"),
           let saved = try? JSONDecoder().decode([PlayEvent].self, from: data) {
            history = saved
        } else {
            history = []
        }
    }

    func isFavorite(_ track: Track) -> Bool { favorites.contains(track.id) }

    func toggleFavorite(_ track: Track) {
        if favorites.contains(track.id) { favorites.remove(track.id) } else { favorites.insert(track.id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }

    func countPlay(_ track: Track) {
        playCounts[track.id, default: 0] += 1
        UserDefaults.standard.set(playCounts, forKey: "playCounts")
        history.insert(PlayEvent(trackId: track.id, date: Date().timeIntervalSince1970), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: "playHistory") }
    }

    func plays(_ track: Track) -> Int { playCounts[track.id] ?? 0 }

    /// « Nouveau » : ajouté sur le serveur il y a moins de 7 jours et pas encore écouté.
    func isNew(_ track: Track) -> Bool {
        guard plays(track) == 0, track.createdAt > 0 else { return false }
        // Le serveur peut donner la date en secondes ou en millisecondes.
        let added = track.createdAt > 100_000_000_000 ? track.createdAt / 1000 : track.createdAt
        return Date().timeIntervalSince1970 - added < 7 * 24 * 3600
    }

    func isNew(_ album: Album) -> Bool { album.tracks.contains { isNew($0) } }

    /// Les sons les plus écoutés parmi une liste.
    func top(_ tracks: [Track], limit: Int) -> [Track] {
        Array(tracks.filter { plays($0) > 0 }.sorted { plays($0) > plays($1) }.prefix(limit))
    }
}

/// Une écoute : quel son, et quand.
struct PlayEvent: Codable, Hashable {
    let trackId: String
    let date: Double
}

/// Cœur pour ajouter ou retirer un son des favoris.
struct FavoriteButton: View {
    @ObservedObject private var stats = Stats.shared
    let track: Track
    var size: CGFloat = 17

    var body: some View {
        let on = stats.isFavorite(track)
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { stats.toggleFavorite(track) } } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(on ? Color.accentPink : .white.opacity(0.75))
                .symbolEffect(.bounce, value: on)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: on)
        .accessibilityLabel(on ? "Retirer des favoris" : "Ajouter aux favoris")
    }
}

struct FavoritesView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var stats = Stats.shared

    var body: some View {
        let list = library.tracks.filter { stats.isFavorite($0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        List {
            if !list.isEmpty {
                PlayShuffleButtons(play: { player.play(list) }, shuffle: { player.play(list, shuffled: true) })
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track)
                    .onTapGesture { player.play(list, startAt: i) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if list.isEmpty {
                ContentUnavailableView {
                    Label("Aucun favori", systemImage: "heart")
                } description: {
                    Text("Touche le cœur dans le lecteur, ou « … » sur un son, pour l'ajouter ici.")
                }
            }
        }
        .navigationTitle("Favoris")
    }
}
