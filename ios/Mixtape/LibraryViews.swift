import SwiftUI

// MARK: - Navigation commune

extension View {
    func libraryDestinations() -> some View {
        self
            .navigationDestination(for: LibrarySection.self) { section in
                switch section {
                case .playlists: PlaylistsView()
                case .artists: ArtistsView()
                case .albums: AlbumsView()
                case .songs: SongsView()
                case .downloads: DownloadsView()
                }
            }
            .navigationDestination(for: Album.self) { AlbumDetailView(albumID: $0.id) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(name: $0.name) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlistID: $0.id) }
    }
}

// MARK: - Bibliothèque

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(LibrarySection.allCases) { section in
                    NavigationLink(value: section) {
                        HStack(spacing: 14) {
                            Image(systemName: section.icon)
                                .font(.title3)
                                .foregroundStyle(Color.accentPink)
                                .frame(width: 30)
                            Text(section.rawValue).font(.title3)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 44)
                }

                if library.tracks.isEmpty && !library.isLoading {
                    EmptyLibraryView().padding(.top, 40)
                } else {
                    Text("Ajouts récents")
                        .font(.title2.bold())
                        .padding(.top, 28)
                        .padding(.bottom, 12)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(library.recentlyAdded) { album in
                            NavigationLink(value: album) { AlbumCell(album: album) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .navigationTitle("Bibliothèque")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LibraryMenu() } }
        .refreshable { await library.refresh() }
        .libraryDestinations()
    }
}

// MARK: - Albums

enum SortOrder: String, CaseIterable, Identifiable {
    case title = "Titre"
    case artist = "Artiste"
    case recent = "Ajout récent"
    var id: String { rawValue }
}

struct SortMenu: View {
    @Binding var order: SortOrder
    var body: some View {
        Menu {
            Picker("Trier par", selection: $order) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Trier")
    }
}

struct AlbumsView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("albumSort") private var order: SortOrder = .title
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    private var sorted: [Album] {
        switch order {
        case .title: return library.albums
        case .artist: return library.albums.sorted {
            let c = $0.artist.localizedCaseInsensitiveCompare($1.artist)
            return c == .orderedSame ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : c == .orderedAscending
        }
        case .recent: return library.albums.sorted { $0.latestAdded > $1.latestAdded }
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(sorted) { album in
                    NavigationLink(value: album) { AlbumCell(album: album) }.buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .overlay { if library.albums.isEmpty { EmptyLibraryView() } }
        .navigationTitle("Albums")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SortMenu(order: $order) } }
        .refreshable { await library.refresh() }
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    let albumID: String

    private var album: Album? { library.albums.first { $0.id == albumID } }

    var body: some View {
        if let album {
            List {
                VStack(spacing: 6) {
                    ArtworkView(url: library.coverURL(album.coverTrack), cornerRadius: 10, placeholderSeed: album.id)
                        .frame(width: 250, height: 250)
                        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                        .padding(.bottom, 12)
                    Text(album.name).font(.title2.bold()).multilineTextAlignment(.center)
                    NavigationLink(value: library.artist(named: album.artist) ?? Artist(name: album.artist, tracks: [], albums: [])) {
                        Text(album.artist).font(.title3).foregroundStyle(Color.accentPink)
                    }
                    .buttonStyle(.plain)
                    if album.isSingle {
                        Text("Single").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    PlayShuffleButtons(play: { player.play(album.tracks) },
                                       shuffle: { player.play(album.tracks, shuffled: true) })
                        .padding(.top, 14)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))

                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, track in
                    TrackRow(track: track, number: track.trackNumber ?? i + 1)
                        .onTapGesture { player.play(album.tracks, startAt: i) }
                }

                Text("\(album.tracks.count) morceau\(album.tracks.count > 1 ? "x" : ""), \(formatTotal(album.totalDuration))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { DownloadAllButton(tracks: album.tracks) } }
        } else {
            ContentUnavailableView("Album introuvable", systemImage: "square.stack")
        }
    }
}

// MARK: - Artistes

struct ArtistsView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        List(library.artists) { artist in
            NavigationLink(value: artist) {
                HStack(spacing: 14) {
                    ArtworkView(url: library.coverURL(artist.coverTrack), cornerRadius: 26, placeholderSeed: artist.id)
                        .frame(width: 52, height: 52)
                    Text(artist.name).font(.body)
                }
            }
        }
        .listStyle(.plain)
        .overlay { if library.artists.isEmpty { EmptyLibraryView() } }
        .navigationTitle("Artistes")
        .refreshable { await library.refresh() }
    }
}

struct ArtistDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    let name: String

    private var artist: Artist? { library.artist(named: name) }

    var body: some View {
        if let artist {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PlayShuffleButtons(play: { player.play(artist.tracks) },
                                       shuffle: { player.play(artist.tracks, shuffled: true) })

                    if !artist.albums.isEmpty {
                        Text("Albums").font(.title2.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(artist.albums) { album in
                                    NavigationLink(value: album) { AlbumCell(album: album).frame(width: 160) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    Text("Morceaux").font(.title2.bold())
                    LazyVStack(spacing: 0) {
                        ForEach(Array(artist.tracks.enumerated()), id: \.element.id) { i, track in
                            TrackRow(track: track)
                                .padding(.vertical, 6)
                                .onTapGesture { player.play(artist.tracks, startAt: i) }
                            Divider().padding(.leading, 60)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle(artist.name)
        } else {
            ContentUnavailableView("Artiste introuvable", systemImage: "music.mic")
        }
    }
}

// MARK: - Morceaux

struct SongsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @AppStorage("songSort") private var order: SortOrder = .title

    private var sorted: [Track] {
        switch order {
        case .title: return library.tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: return library.tracks.sorted {
            let c = $0.displayArtist.localizedCaseInsensitiveCompare($1.displayArtist)
            return c == .orderedSame ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : c == .orderedAscending
        }
        case .recent: return library.tracks.sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
        let songs = sorted
        List {
            if !songs.isEmpty {
                PlayShuffleButtons(play: { player.play(songs) }, shuffle: { player.play(songs, shuffled: true) })
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(songs.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track)
                    .onTapGesture { player.play(songs, startAt: i) }
            }
        }
        .listStyle(.plain)
        .overlay { if songs.isEmpty { EmptyLibraryView() } }
        .navigationTitle("Morceaux")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SortMenu(order: $order) } }
        .refreshable { await library.refresh() }
    }
}
