import Combine
import SwiftUI

// MARK: - Playlists automatiques (« Faites pour toi »)

/// Une playlist qui se remplit toute seule à partir de tes écoutes.
struct SmartPlaylist: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case recent, top, weekly, rediscover, neverPlayed, favoritesMix, artistMix, offline
    }

    let kind: Kind
    /// Pour les mix d'artiste.
    var artist: String? = nil

    var id: String { "smart:\(kind.rawValue):\(artist ?? "")" }

    var title: String {
        switch kind {
        case .recent: return "Ajoutés récemment"
        case .top: return "Top 25"
        case .weekly: return "En boucle cette semaine"
        case .rediscover: return "Redécouvertes"
        case .neverPlayed: return "Jamais écoutés"
        case .favoritesMix: return "Mix favoris"
        case .artistMix: return "Mix \(artist ?? "")"
        case .offline: return "Hors ligne"
        }
    }

    /// Texte en gros sur la pochette.
    var coverTitle: String {
        switch kind {
        case .recent: return "AJOUTÉS RÉCEMMENT"
        case .top: return "TOP 25"
        case .weekly: return "EN BOUCLE"
        case .rediscover: return "REDÉCOUVERTES"
        case .neverPlayed: return "JAMAIS ÉCOUTÉS"
        case .favoritesMix: return "MIX FAVORIS"
        case .artistMix: return (artist ?? "").uppercased()
        case .offline: return "HORS LIGNE"
        }
    }

    var subtitle: String {
        switch kind {
        case .recent: return "Les derniers sons ajoutés"
        case .top: return "Tes plus écoutés"
        case .weekly: return "Ces 7 derniers jours"
        case .rediscover: return "Pas écoutés depuis un mois"
        case .neverPlayed: return "À découvrir"
        case .favoritesMix: return "Nouveau mélange chaque jour"
        case .artistMix: return "Mix artiste"
        case .offline: return "Tes sons téléchargés"
        }
    }

    var details: String {
        switch kind {
        case .recent: return "Les 50 derniers sons déposés sur le serveur."
        case .top: return "Les 25 sons que tu as le plus écoutés."
        case .weekly: return "Ce que tu as le plus écouté ces 7 derniers jours."
        case .rediscover: return "Des sons que tu aimais bien, mais que tu n'as pas écoutés depuis plus d'un mois."
        case .neverPlayed: return "Les sons que tu n'as encore jamais lancés."
        case .favoritesMix: return "Tes favoris, mélangés différemment chaque jour."
        case .artistMix: return "Les sons de \(artist ?? ""), tes préférés d'abord."
        case .offline: return "Tous les sons téléchargés sur ton iPhone, à écouter sans réseau."
        }
    }

    var color: Color {
        switch kind {
        case .recent: return Color(red: 0.98, green: 0.30, blue: 0.40)
        case .top: return Color(red: 1.0, green: 0.55, blue: 0.15)
        case .weekly: return Color(red: 0.62, green: 0.40, blue: 1.0)
        case .rediscover: return Color(red: 0.20, green: 0.78, blue: 0.70)
        case .neverPlayed: return Color(red: 0.96, green: 0.90, blue: 0.30)
        case .favoritesMix: return Color(red: 1.0, green: 0.45, blue: 0.70)
        case .offline: return Color(red: 0.30, green: 0.62, blue: 1.0)
        case .artistMix:
            let seed = (artist ?? "").unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return Color(hue: Double(seed % 360) / 360, saturation: 0.65, brightness: 0.95)
        }
    }
}

/// Garde les playlists automatiques déjà calculées : on ne refait le calcul que quand
/// la bibliothèque, tes écoutes ou tes téléchargements changent (pas à chaque affichage).
@MainActor
final class SmartPlaylistStore: ObservableObject {
    static let shared = SmartPlaylistStore()

    @Published private(set) var playlists: [SmartPlaylist] = []
    private var cache: [String: [Track]] = [:]
    private weak var library: LibraryStore?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func attach(_ library: LibraryStore) {
        guard self.library !== library else { return }
        self.library = library
        cancellables = []
        Publishers.Merge3(
            library.$tracks.map { _ in () },
            Stats.shared.objectWillChange.map { _ in () },
            DownloadManager.shared.objectWillChange.map { _ in () }
        )
        .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
        .sink { [weak self] in self?.rebuild() }
        .store(in: &cancellables)
        rebuild()
    }

    func tracks(for playlist: SmartPlaylist) -> [Track] {
        if let cached = cache[playlist.id] { return cached }
        guard let library else { return [] }
        let computed = SmartPlaylists.tracks(for: playlist, library: library)
        cache[playlist.id] = computed
        return computed
    }

    func coverTrack(for playlist: SmartPlaylist) -> Track? {
        tracks(for: playlist).first { $0.hasCover }
    }

    private func rebuild() {
        guard let library else { return }
        var fresh: [String: [Track]] = [:]
        let candidates = SmartPlaylists.candidates(library: library)
        for playlist in candidates {
            fresh[playlist.id] = SmartPlaylists.tracks(for: playlist, library: library)
        }
        cache = fresh
        let visible = candidates.filter { !(fresh[$0.id] ?? []).isEmpty }
        playlists = visible
    }
}

@MainActor
enum SmartPlaylists {
    /// Toutes les playlists possibles (même vides).
    static func candidates(library: LibraryStore) -> [SmartPlaylist] {
        var list: [SmartPlaylist] = [
            SmartPlaylist(kind: .recent),
            SmartPlaylist(kind: .weekly),
            SmartPlaylist(kind: .top),
            SmartPlaylist(kind: .favoritesMix),
        ]
        list += topArtists(library: library, limit: 3).map { SmartPlaylist(kind: .artistMix, artist: $0) }
        list += [
            SmartPlaylist(kind: .rediscover),
            SmartPlaylist(kind: .neverPlayed),
            SmartPlaylist(kind: .offline),
        ]
        return list
    }

    static func tracks(for playlist: SmartPlaylist, library: LibraryStore) -> [Track] {
        let stats = Stats.shared
        let all = library.tracks
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let now = Date().timeIntervalSince1970

        switch playlist.kind {
        case .recent:
            return Array(all.sorted { $0.createdAt > $1.createdAt }.prefix(50))

        case .top:
            return stats.top(all, limit: 25)

        case .weekly:
            var counts: [String: Int] = [:]
            for event in stats.history {
                if event.date < now - 7 * 24 * 3600 { break }
                counts[event.trackId, default: 0] += 1
            }
            return counts.sorted { $0.value > $1.value }
                .compactMap { library.track($0.key) }
                .prefix(25)
                .map { $0 }

        case .rediscover:
            // Dernière écoute de chaque son (l'historique va du plus récent au plus ancien).
            var lastPlayed: [String: Double] = [:]
            for event in stats.history where lastPlayed[event.trackId] == nil {
                lastPlayed[event.trackId] = event.date
            }
            let picked = all.filter { track in
                guard stats.plays(track) >= 2, let last = lastPlayed[track.id] else { return false }
                return last < now - 30 * 24 * 3600
            }
            return Array(picked.sorted { stats.plays($0) > stats.plays($1) }.prefix(40))

        case .neverPlayed:
            return Array(all.filter { stats.plays($0) == 0 }.dailyShuffled(seed: day).prefix(50))

        case .favoritesMix:
            return all.filter { stats.isFavorite($0) }.dailyShuffled(seed: day &+ 1)

        case .artistMix:
            let name = (playlist.artist ?? "").lowercased()
            let mine = all.filter { $0.displayArtist.lowercased() == name }
            let loved = mine.filter { stats.plays($0) > 0 }.sorted { stats.plays($0) > stats.plays($1) }
            let rest = mine.filter { stats.plays($0) == 0 }.dailyShuffled(seed: day &+ 2)
            return Array((Array(loved.prefix(10)) + rest + Array(loved.dropFirst(10))).prefix(50))

        case .offline:
            return all.filter { DownloadManager.shared.isDownloaded($0) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    private static func topArtists(library: LibraryStore, limit: Int) -> [String] {
        var byArtist: [String: Int] = [:]
        for track in library.tracks {
            let n = Stats.shared.plays(track)
            if n > 0 { byArtist[track.displayArtist, default: 0] += n }
        }
        return byArtist.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }
}

extension Array {
    /// Mélange qui reste le même toute la journée et change le lendemain.
    func dailyShuffled(seed: Int) -> [Element] {
        var generator = DailyGenerator(seed: UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 17))
        return shuffled(using: &generator)
    }
}

private struct DailyGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Pochette façon Apple Music

/// Photo de pochette en noir et blanc teintée, gros titre et logo Mixtape.
struct SmartPlaylistCover: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var store = SmartPlaylistStore.shared
    let playlist: SmartPlaylist
    var cornerRadius: CGFloat = 12

    var body: some View {
        let cover = store.coverTrack(for: playlist)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .topLeading) {
                        playlist.color

                        if let cover {
                            ArtworkView(url: library.coverURL(cover), cornerRadius: 0, placeholderSeed: cover.albumKey)
                                .grayscale(1)
                                .contrast(1.15)
                                .colorMultiply(playlist.color)
                                .frame(width: w * 0.78, height: w * 0.78)
                                .clipShape(RoundedRectangle(cornerRadius: w * 0.03, style: .continuous))
                                .shadow(color: .black.opacity(0.25), radius: w * 0.04, y: w * 0.02)
                                .offset(x: w * 0.11, y: w * 0.30)
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 3) {
                                Spacer()
                                Image(systemName: "music.note")
                                Text("Mixtape")
                            }
                            .font(.system(size: max(w * 0.06, 9), weight: .heavy))
                            .foregroundStyle(.black.opacity(0.85))

                            Text(playlist.coverTitle)
                                .font(.system(size: w * 0.15, weight: .black))
                                .fontWidth(.compressed)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.35), radius: 0, x: w * 0.006, y: w * 0.006)
                                .lineLimit(2)
                                .minimumScaleFactor(0.4)
                                .padding(.top, w * 0.01)
                        }
                        .padding(w * 0.06)
                    }
                    .frame(width: w, height: geo.size.height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}

// MARK: - Rangée de l'accueil

/// « Faites pour toi » : grandes pochettes qui défilent, comme Apple Music.
struct SmartPlaylistsShelf: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var store = SmartPlaylistStore.shared

    var body: some View {
        let playlists = store.playlists
        Group {
        if !playlists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Faites pour toi").font(.title2.bold()).padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(playlists) { playlist in
                            NavigationLink(value: playlist) {
                                VStack(alignment: .leading, spacing: 6) {
                                    SmartPlaylistCover(playlist: playlist)
                                        .zoomSource(id: playlist.id)
                                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(playlist.title).font(.headline).lineLimit(1)
                                        Text("Mixtape : \(playlist.subtitle)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .frame(width: 180)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
        }
        .onAppear { store.attach(library) }
    }
}

// MARK: - Page d'une playlist automatique

struct SmartPlaylistView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var store = SmartPlaylistStore.shared
    let playlist: SmartPlaylist

    var body: some View {
        let list = store.tracks(for: playlist)
        List {
            VStack(spacing: 14) {
                SmartPlaylistCover(playlist: playlist, cornerRadius: 14)
                    .frame(width: 220, height: 220)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                VStack(spacing: 4) {
                    Text(playlist.title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(playlist.details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("\(list.count) morceau\(list.count > 1 ? "x" : "") · \(formatTotal(list.reduce(0) { $0 + $1.duration }))")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 12)
                if !list.isEmpty {
                    PlayShuffleButtons(play: { player.play(list) }, shuffle: { player.play(list, shuffled: true) })
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)

            ForEach(Array(list.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track)
                    .onTapGesture { player.play(list, startAt: i) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if list.isEmpty {
                ContentUnavailableView("Rien pour l'instant", systemImage: "music.note.list",
                                       description: Text("Cette playlist se remplira toute seule avec tes écoutes."))
            }
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Section « Faites pour toi » en haut de la liste des playlists.
struct SmartPlaylistRows: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var store = SmartPlaylistStore.shared

    var body: some View {
        ForEach(store.playlists) { playlist in
            NavigationLink(value: playlist) {
                HStack(spacing: 14) {
                    SmartPlaylistCover(playlist: playlist, cornerRadius: 6)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.title)
                        Text(playlist.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { store.attach(library) }
    }
}
