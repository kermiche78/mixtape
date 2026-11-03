import SwiftUI

// MARK: - Navigation commune

extension View {
    func libraryDestinations() -> some View {
        self
            .navigationDestination(for: LibrarySection.self) { section in
                switch section {
                case .favorites: FavoritesView()
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

                let others = (library.artist(named: album.artist)?.albums ?? []).filter { $0.id != album.id }
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Plus de \(album.artist)").font(.title3.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(others) { other in
                                    NavigationLink(value: other) { AlbumCell(album: other).frame(width: 150) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 30, trailing: 0))
                }
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

// MARK: - Page artiste

/// Type de sortie, déduit du nombre de titres (comme sur les plateformes).
enum ReleaseKind: String, CaseIterable, Identifiable {
    case popular = "Sorties populaires"
    case albums = "Albums"
    case eps = "EP & Singles"
    var id: String { rawValue }
}

extension Album {
    var kindLabel: String {
        if isSingle || tracks.count == 1 { return "Single" }
        return tracks.count <= 6 ? "EP" : "Album"
    }
    var isFullAlbum: Bool { kindLabel == "Album" }
    var addedYear: String {
        let y = Calendar.current.component(.year, from: Date(timeIntervalSince1970: latestAdded))
        return latestAdded > 0 ? String(y) : ""
    }
}

private struct HeaderOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ArtistDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var stats = Stats.shared
    @State private var filter: ReleaseKind = .popular
    @State private var headerOffset: CGFloat = 0
    let name: String

    private var artist: Artist? { library.artist(named: name) }
    private let heroHeight: CGFloat = 400

    var body: some View {
        if let artist {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    hero(artist)

                    let top = Stats.shared.top(artist.tracks, limit: 5)
                    let topSongs = top.isEmpty ? Array(artist.tracks.prefix(5)) : top
                    if !topSongs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            sectionTitle("Top titres") {
                                SongListView(title: "Titres de \(artist.name)", tracks: artist.tracks)
                            }
                            LazyVStack(spacing: 0) {
                                ForEach(Array(topSongs.enumerated()), id: \.element.id) { i, track in
                                    HStack(spacing: 12) {
                                        Text("\(i + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                                        TrackRow(track: track)
                                    }
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                    .onTapGesture { player.play(topSongs, startAt: i) }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    discography(artist)
                }
                .padding(.bottom, 30)
            }
            .coordinateSpace(name: "artistScroll")
            .onPreferenceChange(HeaderOffsetKey.self) { headerOffset = $0 }
            .ignoresSafeArea(edges: .top)
            .navigationTitle(collapsed ? artist.name : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(collapsed ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { player.play(artist.tracks) } label: { Label("Tout lire", systemImage: "play.fill") }
                        Button { player.play(artist.tracks, shuffled: true) } label: { Label("Lecture aléatoire", systemImage: "shuffle") }
                        Button { artist.tracks.forEach { player.addToQueue($0) } } label: {
                            Label("Ajouter à la file d'attente", systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                        Button { DownloadManager.shared.download(artist.tracks, api: library.api) } label: {
                            Label("Tout télécharger", systemImage: "arrow.down.circle")
                        }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: collapsed)
        } else {
            ContentUnavailableView("Artiste introuvable", systemImage: "music.mic")
        }
    }

    private var collapsed: Bool { headerOffset < -(heroHeight - 140) }

    // Grande photo de l'artiste, nom en bas à gauche, bouton lecture en bas à droite.
    private func hero(_ artist: Artist) -> some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .named("artistScroll")).minY
            let stretch = max(minY, 0)
            ZStack(alignment: .bottomLeading) {
                let side = max(geo.size.width, heroHeight + stretch)
                ArtworkView(url: library.coverURL(artist.coverTrack), cornerRadius: 0, placeholderSeed: artist.id)
                    .frame(width: side, height: side)
                    .frame(width: geo.size.width, height: heroHeight + stretch)
                    .clipped()
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artist.name)
                            .font(.system(size: 38, weight: .heavy))
                            .lineLimit(2).minimumScaleFactor(0.6)
                        Text("\(artist.albums.count) sortie\(artist.albums.count > 1 ? "s" : "") · \(artist.tracks.count) titre\(artist.tracks.count > 1 ? "s" : "")")
                            .font(.subheadline.weight(.medium)).opacity(0.8)
                    }
                    .foregroundStyle(.white)
                    Spacer()
                    Button { player.play(artist.tracks, shuffled: true) } label: {
                        Image(systemName: "shuffle").font(.title3.weight(.bold)).frame(width: 30, height: 30)
                    }
                    .glassButton()
                    .controlSize(.large)
                    .tint(.white)
                    Button { player.play(artist.tracks) } label: {
                        Image(systemName: "play.fill").font(.title2).foregroundStyle(.white).frame(width: 34, height: 34)
                    }
                    .glassButton(prominent: true)
                    .controlSize(.large)
                    .tint(Color.accentPink)
                }
                .padding(20)
            }
            .frame(width: geo.size.width, height: heroHeight + stretch)
            .offset(y: -stretch)
            .preference(key: HeaderOffsetKey.self, value: minY)
        }
        .frame(height: heroHeight)
    }

    private func sectionTitle<D: View>(_ title: String, @ViewBuilder destination: () -> D) -> some View {
        let dest = destination()
        return HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold())
            Spacer()
            NavigationLink { dest } label: {
                Text("Tout voir").font(.body.weight(.medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func releases(_ artist: Artist, _ kind: ReleaseKind) -> [Album] {
        switch kind {
        case .popular:
            return artist.albums.sorted { a, b in
                let pa = a.tracks.reduce(0) { $0 + stats.plays($1) }
                let pb = b.tracks.reduce(0) { $0 + stats.plays($1) }
                return pa == pb ? a.latestAdded > b.latestAdded : pa > pb
            }
        case .albums: return artist.albums.filter(\.isFullAlbum).sorted { $0.latestAdded > $1.latestAdded }
        case .eps: return artist.albums.filter { !$0.isFullAlbum }.sorted { $0.latestAdded > $1.latestAdded }
        }
    }

    // « Discographie » : filtres en pastilles + grille 2 colonnes.
    private func discography(_ artist: Artist) -> some View {
        let kinds = ReleaseKind.allCases.filter { $0 == .popular || !releases(artist, $0).isEmpty }
        let list = releases(artist, filter)
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Discographie") {
                DiscographyView(artistName: artist.name, albums: list, title: filter.rawValue)
            }
            .padding(.horizontal, 20)

            if kinds.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(kinds) { kind in
                            let on = filter == kind
                            Button {
                                withAnimation(.snappy) { filter = kind }
                            } label: {
                                Text(kind.rawValue)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16).padding(.vertical, 9)
                                    .foregroundStyle(on ? Color.black : Color.primary)
                                    .background(on ? Color.white : Color.primary.opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .sensoryFeedback(.selection, trigger: filter)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }

            ReleaseGrid(albums: Array(list.prefix(4)))
                .padding(.horizontal, 20)
        }
    }
}

/// Grille 2 colonnes de pochettes, avec « Type · année » en dessous.
struct ReleaseGrid: View {
    @EnvironmentObject private var library: LibraryStore
    let albums: [Album]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 22) {
            ForEach(albums) { album in
                NavigationLink(value: album) {
                    VStack(alignment: .leading, spacing: 6) {
                        ArtworkView(url: library.coverURL(album.coverTrack), cornerRadius: 6, placeholderSeed: album.id)
                            .aspectRatio(1, contentMode: .fit)
                            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                        Text(album.isSingle ? (album.tracks.first?.title ?? album.name) : album.name)
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text([album.addedYear, album.kindLabel].filter { !$0.isEmpty }.joined(separator: " • "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// « Tout voir » de la discographie.
struct DiscographyView: View {
    let artistName: String
    let albums: [Album]
    let title: String

    var body: some View {
        ScrollView {
            ReleaseGrid(albums: albums).padding(20)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

/// « Tout voir » des titres d'un artiste.
struct SongListView: View {
    @EnvironmentObject private var player: PlayerModel
    let title: String
    let tracks: [Track]

    var body: some View {
        List {
            PlayShuffleButtons(play: { player.play(tracks) }, shuffle: { player.play(tracks, shuffled: true) })
                .listRowSeparator(.hidden)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track).onTapGesture { player.play(tracks, startAt: i) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
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
