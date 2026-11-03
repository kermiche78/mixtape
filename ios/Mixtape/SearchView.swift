import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @State private var query = ""

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let artists = q.isEmpty ? [] : library.artists.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let albums = q.isEmpty ? [] : library.albums.filter { "\($0.name) \($0.artist)".localizedCaseInsensitiveContains(q) }
        let songs = q.isEmpty ? [] : library.tracks.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(q) }

        List {
            if q.isEmpty {
                Section {
                    ForEach(library.albums.shuffledStable(seed: library.tracks.count).prefix(6)) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 12) {
                                ArtworkView(url: library.coverURL(album.coverTrack), cornerRadius: 5, placeholderSeed: album.id)
                                    .frame(width: 52, height: 52)
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
                                ArtworkView(url: library.coverURL(artist.coverTrack), cornerRadius: 26, placeholderSeed: artist.id)
                                    .frame(width: 52, height: 52)
                                Text(artist.name)
                            }
                        }
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
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name).lineLimit(1)
                                    Text("Album · \(album.artist)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            if !songs.isEmpty {
                Section("Morceaux") {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, track in
                        TrackRow(track: track)
                            .onTapGesture { player.play(songs, startAt: i) }
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
        .libraryDestinations()
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
