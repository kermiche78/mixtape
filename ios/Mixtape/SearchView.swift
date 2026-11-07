import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @State private var query = ""
    @State private var recents: [String] = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let artists = q.isEmpty ? [] : library.artists.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let albums = q.isEmpty ? [] : library.albums.filter { "\($0.name) \($0.artist)".localizedCaseInsensitiveContains(q) }
        let songs = q.isEmpty ? [] : library.tracks.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(q) }

        List {
            if q.isEmpty && !recents.isEmpty {
                Section {
                    ForEach(recents, id: \.self) { text in
                        Button { query = text } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Text(text).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.left").font(.footnote).foregroundStyle(.tertiary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { removeRecent(text) } label: { Label("Supprimer", systemImage: "trash") }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recherches récentes").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                        Spacer()
                        Button("Effacer") { setRecents([]) }
                            .font(.subheadline)
                            .textCase(nil)
                    }
                }
            }
            if q.isEmpty {
                Section {
                    ForEach(library.albums.shuffledStable(seed: library.tracks.count).prefix(6)) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 12) {
                                ArtworkView(url: library.coverURL(album.coverTrack), cornerRadius: 5, placeholderSeed: album.id)
                                    .frame(width: 52, height: 52)
                                    .zoomSource(id: album.id)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name).lineLimit(1)
                                    Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                } header: {
                    Text("À écouter").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                }
            }
            if !artists.isEmpty {
                Section("Artistes") {
                    ForEach(artists.prefix(5)) { artist in
                        NavigationLink(value: artist) {
                            HStack(spacing: 12) {
                                ArtworkView(url: library.artistImageURL(artist), cornerRadius: 26, placeholderSeed: artist.id)
                                    .frame(width: 52, height: 52)
                                Text(artist.name)
                            }
                        }
                        .simultaneousGesture(TapGesture().onEnded { remember(q) })
                    }
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums.prefix(8)) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 12) {
                                ArtworkView(url: library.coverURL(album.coverTrack), cornerRadius: 5, placeholderSeed: album.id)
                                    .frame(width: 52, height: 52)
                                    .zoomSource(id: album.id)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name).lineLimit(1)
                                    Text("Album · \(album.artist)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .simultaneousGesture(TapGesture().onEnded { remember(q) })
                    }
                }
            }
            if !songs.isEmpty {
                Section("Morceaux") {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, track in
                        TrackRow(track: track)
                            .onTapGesture {
                                remember(q)
                                player.play(songs, startAt: i)
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if !q.isEmpty && artists.isEmpty && albums.isEmpty && songs.isEmpty {
                ContentUnavailableView.search(text: q)
            }
        }
        .navigationTitle("Recherche")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artistes, albums, morceaux")
        .onSubmit(of: .search) { remember(q) }
        .libraryDestinations()
    }

    /// Garde les 10 dernières recherches, la plus récente en premier.
    private func remember(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var list = recents.filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        list.insert(t, at: 0)
        setRecents(Array(list.prefix(10)))
    }

    private func removeRecent(_ text: String) {
        setRecents(recents.filter { $0 != text })
    }

    private func setRecents(_ list: [String]) {
        recents = list
        UserDefaults.standard.set(list, forKey: "recentSearches")
    }
}

private extension Array {
    /// Mélange qui ne change pas à chaque rafraîchissement de l'écran.
    func shuffledStable(seed: Int) -> [Element] {
        var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: seed &+ 7))
        return shuffled(using: &generator)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
