import Foundation
import SwiftUI

/// Favoris et nombre d'écoutes, gardés sur l'iPhone.
@MainActor
final class Stats: ObservableObject {
    static let shared = Stats()

    @Published private(set) var favorites: Set<String>
    /// Albums mis en favori (avec le cœur de la page album), séparés des sons favoris.
    @Published private(set) var favoriteAlbums: Set<String>
    @Published private(set) var playCounts: [String: Int]
    /// Historique des écoutes, du plus récent au plus ancien.
    @Published private(set) var history: [PlayEvent]

    private static let historyLimit = 3000
    /// Secondes écoutées par jour (« 2026-11-08 » → 5040). Pas publié : l'Accueil le relit toutes les 30 s.
    private var listening: [String: Double] = UserDefaults.standard.dictionary(forKey: "listeningByDay") as? [String: Double] ?? [:]
    private var lastListeningSave = Date()

    private init() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
        favoriteAlbums = Set(UserDefaults.standard.stringArray(forKey: "favoriteAlbums") ?? [])
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
        if favorites.contains(track.id) {
            favorites.remove(track.id)
            favoritesOrder.removeAll { $0 == track.id }
        } else {
            favorites.insert(track.id)
            favoritesOrder.removeAll { $0 == track.id }
            favoritesOrder.insert(track.id, at: 0)
        }
        saveFavorites()
    }

    // MARK: Ordre de la playlist « Favoris » (le dernier liké en premier, modifiable)

    /// Ordre choisi dans « Favoris » → Modifier. Les anciens favoris sans ordre viennent après, par titre.
    @Published private(set) var favoritesOrder: [String] = UserDefaults.standard.stringArray(forKey: "favoritesOrder") ?? []

    func orderedFavorites(in tracks: [Track]) -> [Track] {
        let favs = tracks.filter { favorites.contains($0.id) }
        let rank = Dictionary(favoritesOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return favs.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    /// Nouvel ordre après un glisser-déposer dans « Modifier ».
    func setFavoritesOrder(_ ids: [String]) {
        favoritesOrder = ids
        saveFavorites()
    }

    func removeFavorites(_ ids: [String]) {
        favorites.subtract(ids)
        favoritesOrder.removeAll { ids.contains($0) }
        saveFavorites()
    }

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
        UserDefaults.standard.set(favoritesOrder, forKey: "favoritesOrder")
    }

    func isFavorite(_ album: Album) -> Bool { favoriteAlbums.contains(album.id) }

    /// Met l'album lui-même en favori (ses sons ne changent pas).
    func toggleFavorite(_ album: Album) {
        if favoriteAlbums.contains(album.id) { favoriteAlbums.remove(album.id) } else { favoriteAlbums.insert(album.id) }
        UserDefaults.standard.set(Array(favoriteAlbums), forKey: "favoriteAlbums")
    }

    func countPlay(_ track: Track) {
        playCounts[track.id, default: 0] += 1
        UserDefaults.standard.set(playCounts, forKey: "playCounts")
        history.insert(PlayEvent(trackId: track.id, date: Date().timeIntervalSince1970), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        saveHistory()
    }

    // MARK: Temps d'écoute

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func addListening(_ seconds: Double) {
        guard seconds > 0, seconds < 5 else { return }
        listening[Self.dayFormatter.string(from: Date()), default: 0] += seconds
        if Date().timeIntervalSince(lastListeningSave) > 15 { flush() }
    }

    func listenedToday() -> Double { listening[Self.dayFormatter.string(from: Date())] ?? 0 }

    /// Écrit le temps d'écoute sur l'iPhone (garde les 120 derniers jours).
    func flush() {
        lastListeningSave = Date()
        if listening.count > 120 {
            for key in listening.keys.sorted().prefix(listening.count - 120) { listening[key] = nil }
        }
        UserDefaults.standard.set(listening, forKey: "listeningByDay")
    }

    /// Relit tout depuis l'iPhone (après une restauration de la sauvegarde du PC).
    func reload() {
        let d = UserDefaults.standard
        favorites = Set(d.stringArray(forKey: "favorites") ?? [])
        favoriteAlbums = Set(d.stringArray(forKey: "favoriteAlbums") ?? [])
        favoritesOrder = d.stringArray(forKey: "favoritesOrder") ?? []
        playCounts = d.dictionary(forKey: "playCounts") as? [String: Int] ?? [:]
        if let data = d.data(forKey: "playHistory"), let saved = try? JSONDecoder().decode([PlayEvent].self, from: data) {
            history = saved
        }
        listening = d.dictionary(forKey: "listeningByDay") as? [String: Double] ?? [:]
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
    @State private var editMode: EditMode = .inactive
    @State private var query = ""
    @State private var selection = Set<String>()

    private var editing: Bool { editMode.isEditing }

    var body: some View {
        let all = stats.orderedFavorites(in: library.tracks)
        let list = query.isEmpty ? all : all.filter { $0.matchesSearch(query) }
        List(selection: $selection) {
            if !list.isEmpty && !editing {
                PlayShuffleButtons(play: { player.play(list) }, shuffle: { player.play(list, shuffled: true) })
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track)
                    .contentShape(Rectangle())
                    .onTapGesture { if !editing { player.play(list, startAt: i) } }
                    .tag(track.id)
            }
            .onDelete { offsets in
                stats.removeFavorites(offsets.map { list[$0].id })
            }
            .onMove { from, to in
                // Le déplacement n'a de sens que sur la liste complète (sans recherche).
                guard query.isEmpty else { return }
                var ids = all.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                stats.setFavoritesOrder(ids)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .searchable(text: $query, prompt: "Rechercher dans tes favoris")
        .overlay {
            if all.isEmpty {
                ContentUnavailableView {
                    Label("Aucun favori", systemImage: "heart")
                } description: {
                    Text("Touche le cœur dans le lecteur, ou « … » sur un son, pour l'ajouter ici.")
                }
            } else if list.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Favoris")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editing {
                    if !selection.isEmpty {
                        Button(role: .destructive) {
                            stats.removeFavorites(Array(selection))
                            selection = []
                        } label: { Text("Retirer (\(selection.count))") }
                    }
                    Button("OK") { withAnimation { editMode = .inactive; selection = [] } }
                        .fontWeight(.semibold)
                } else if !all.isEmpty {
                    DownloadAllButton(tracks: all)
                    Button("Modifier") { withAnimation { editMode = .active } }
                }
            }
        }
    }
}
