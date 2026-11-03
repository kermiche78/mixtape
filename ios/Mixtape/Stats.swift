import Foundation
import SwiftUI

/// Favoris et nombre d'écoutes, gardés sur l'iPhone.
@MainActor
final class Stats: ObservableObject {
    static let shared = Stats()

    @Published private(set) var favorites: Set<String>
    @Published private(set) var playCounts: [String: Int]

    private init() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
        playCounts = UserDefaults.standard.dictionary(forKey: "playCounts") as? [String: Int] ?? [:]
    }

    func isFavorite(_ track: Track) -> Bool { favorites.contains(track.id) }

    func toggleFavorite(_ track: Track) {
        if favorites.contains(track.id) { favorites.remove(track.id) } else { favorites.insert(track.id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }

    func countPlay(_ track: Track) {
        playCounts[track.id, default: 0] += 1
        UserDefaults.standard.set(playCounts, forKey: "playCounts")
    }

    func plays(_ track: Track) -> Int { playCounts[track.id] ?? 0 }

    /// Les sons les plus écoutés parmi une liste.
    func top(_ tracks: [Track], limit: Int) -> [Track] {
        Array(tracks.filter { plays($0) > 0 }.sorted { plays($0) > plays($1) }.prefix(limit))
    }
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
