import SwiftUI

// MARK: - Navigation commune

extension View {
    func libraryDestinations() -> some View {
        self
            .navigationDestination(for: LibrarySection.self) { section in
                switch section {
                case .favorites: FavoritesView()
                case .favoriteAlbums: FavoriteAlbumsView()
                case .playlists: PlaylistsView()
                case .artists: ArtistsView()
                case .albums: AlbumsView()
                case .songs: SongsView()
                case .downloads: DownloadsView()
                case .history: HistoryView()
                case .replay: ReplayView()
                }
            }
            .navigationDestination(for: Album.self) { AlbumDetailView(albumID: $0.id).zoomDestination(id: $0.id) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(name: $0.name) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlistID: $0.id) }
            .navigationDestination(for: SmartPlaylist.self) { SmartPlaylistView(playlist: $0).zoomDestination(id: $0.id) }
            .navigationDestination(for: DiscographyRoute.self) { DiscographyView(route: $0) }
            .navigationDestination(for: ArtistSongsRoute.self) { ArtistSongsView(artistName: $0.artist) }
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
    case plays = "Plus écoutés"
    case year = "Année"
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
    @ObservedObject private var stats = Stats.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @AppStorage("albumSort") private var order: SortOrder = .title
    @AppStorage("albumFilter") private var filter: LibraryFilter = .all
    @State private var query = ""
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    private var shown: [Album] {
        let base = library.albums.filter { $0.matches(filter, stats: stats, downloads: downloads) && $0.matchesSearch(query) }
        switch order {
        case .title: return base
        case .artist: return base.sorted {
            let c = $0.artist.localizedCaseInsensitiveCompare($1.artist)
            return c == .orderedSame ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : c == .orderedAscending
        }
        case .recent: return base.sorted { $0.latestAdded > $1.latestAdded }
        case .plays:
            let plays = Dictionary(base.map { a in (a.id, a.tracks.reduce(0) { $0 + stats.plays($1) }) }, uniquingKeysWith: { x, _ in x })
            return base.sorted { (plays[$0.id] ?? 0) > (plays[$1.id] ?? 0) }
        case .year: return base.sorted { $0.sortYear != $1.sortYear ? $0.sortYear > $1.sortYear : $0.name < $1.name }
        }
    }

    var body: some View {
        let albums = shown
        ScrollView {
            // Les pastilles font partie de la page (et plus d'une barre posée par-dessus) :
            // le grand titre « Albums » s'affiche correctement.
            FilterChips(selection: $filter, options: LibraryFilter.albumOptions)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink(value: album) { AlbumCell(album: album) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .padding(.top, 4)
        }
        .searchable(text: $query, prompt: "Rechercher un album ou un artiste")
        .overlay {
            if library.albums.isEmpty {
                EmptyLibraryView()
            } else if albums.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("Aucun album", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Aucun album ne correspond à « \(filter.rawValue) »."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle("Albums")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SortMenu(order: $order) } }
        .refreshable { await library.refresh() }
    }
}

/// « Albums favoris » : les albums mis en favori avec le cœur, rangés par artiste.
struct FavoriteAlbumsView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var stats = Stats.shared
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        let albums = library.albums.filter { stats.isFavorite($0) }
            .sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink(value: album) { AlbumCell(album: album) }.buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .overlay {
            if albums.isEmpty {
                ContentUnavailableView {
                    Label("Aucun album favori", systemImage: "heart.square")
                } description: {
                    Text("Touche le cœur à côté de « Lire » sur la page d'un album pour le ranger ici.")
                }
            }
        }
        .navigationTitle("Albums favoris")
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var stats = Stats.shared
    @State private var tint: Color = .clear
    @State private var pageColor: Color = Color(white: 0.09)
    @AppStorage("manageMode") private var manageMode = false
    @State private var showEditor = false
    let albumID: String

    private var album: Album? { library.album(id: albumID) }

    var body: some View {
        if let album {
            ScrollView {
                VStack(spacing: 0) {
                    header(album)
                    AlbumDownloadCard(tracks: album.tracks)
                    resumeCard(album)
                    tracks(album)
                    footer(album)
                }
                .padding(.bottom, 30)
            }
            .background {
                // Toute la page prend la couleur de la pochette, un peu plus claire en haut.
                ZStack(alignment: .top) {
                    pageColor
                    LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 620)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            // Texte blanc sur le fond coloré, même si l'iPhone est en mode clair.
            .environment(\.colorScheme, .dark)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if manageMode, !album.isSingle {
                        Button { showEditor = true } label: { Image(systemName: "pencil") }
                            .accessibilityLabel("Modifier l'album")
                    }
                    DownloadAllButton(tracks: album.tracks)
                    Menu {
                        Button { player.play(album.tracks) } label: { Label("Lire", systemImage: "play.fill") }
                        Button { player.play(album.tracks, shuffled: true) } label: { Label("Lecture aléatoire", systemImage: "shuffle") }
                        Button { album.tracks.reversed().forEach { player.playNext($0) } } label: {
                            Label("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button { album.tracks.forEach { player.addToQueue($0) } } label: {
                            Label("Lire en dernier", systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                        Divider()
                        let fav = stats.isFavorite(album)
                        Button { stats.toggleFavorite(album) } label: {
                            Label(fav ? "Retirer l'album des favoris" : "Mettre l'album en favori", systemImage: fav ? "heart.slash" : "heart")
                        }
                        Button { album.tracks.forEach { if !stats.isFavorite($0) { stats.toggleFavorite($0) } } } label: {
                            Label("Ajouter tous les sons aux favoris", systemImage: "heart.text.square")
                        }
                        Button {
                            ShareManager.shared.shareAlbum(album, api: library.api, coverURL: library.coverURL(album.coverTrack))
                        } label: {
                            Label(album.isSingle ? "Partager le single" : "Partager l'album", systemImage: "square.and.arrow.up")
                        }
                        AnimatedCoverMenuButton(album: album)
                        if manageMode {
                            Button {
                                Task { try? await library.api?.lyricsPriority(trackIds: album.tracks.map(\.id)) }
                            } label: {
                                Label("Générer les paroles en priorité", systemImage: "quote.bubble")
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .sheet(isPresented: $showEditor) { AlbumEditorView(album: album) }
            .task(id: album.coverTrack?.id) {
                guard let url = library.coverURL(album.coverTrack),
                      let img = await ImageLoader.shared.image(for: url),
                      let c = ArtworkColor.average(of: img) else { return }
                let page = ArtworkColor.background(of: img) ?? pageColor
                withAnimation(.easeInOut(duration: 0.5)) {
                    tint = c
                    pageColor = page
                }
            }
        } else {
            ContentUnavailableView("Album introuvable", systemImage: "square.stack")
        }
    }

    // Pochette, titre, artiste, infos, puis aléatoire · Lire · +
    private func header(_ album: Album) -> some View {
        VStack(spacing: 0) {
            AnimatedArtworkView(track: album.coverTrack, cornerRadius: 10, placeholderSeed: album.id)
                .frame(width: 270, height: 270)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                .padding(.top, 8)
                .padding(.bottom, 20)

            Text(album.isSingle ? (album.tracks.first?.title ?? album.name) : album.name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            NavigationLink(value: library.artist(named: album.artist) ?? Artist(name: album.artist, tracks: [], albums: [])) {
                Text(album.artist).font(.title3).foregroundStyle(Color.primary.opacity(0.85))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            Text([album.kindLabel, album.addedYear].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            HStack(spacing: 14) {
                circleButton("shuffle") { player.play(album.tracks, shuffled: true) }
                    .accessibilityLabel("Lecture aléatoire")
                Button { player.play(album.tracks) } label: {
                    Label("Lire", systemImage: "play.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                let fav = stats.isFavorite(album)
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { stats.toggleFavorite(album) }
                } label: {
                    Image(systemName: fav ? "heart.fill" : "heart")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(fav ? Color.accentPink : .primary)
                        .symbolEffect(.bounce, value: fav)
                        .frame(width: 50, height: 50)
                        .liquidGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.success, trigger: fav)
                .accessibilityLabel(fav ? "Retirer l'album des favoris" : "Mettre l'album en favori")
            }
            .padding(.horizontal, 44)
            .padding(.top, 20)
            .padding(.bottom, 22)

            if let text = library.description(for: album), !text.isEmpty {
                AlbumDescription(title: album.name, text: text)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// « Reprendre la lecture de l'album », comme YouTube Music.
    @ViewBuilder
    private func resumeCard(_ album: Album) -> some View {
        let playingThis = player.current.map { $0.albumKey == album.id } ?? false
        if !playingThis,
           let p = player.albumProgress[album.id],
           let i = album.tracks.firstIndex(where: { $0.id == p.trackId }),
           i > 0 || p.time > 15 {
            let track = album.tracks[i]
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reprendre la lecture de l'album").font(.headline)
                    Text("\(track.trackNumber ?? i + 1). \(track.title) · \(formatTime(p.time))")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { player.resume(album) } label: {
                    Text("Reprendre")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .liquidGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
    }

    // Liste épurée : point (favori), numéro, titre, menu « … ».
    private func tracks(_ album: Album) -> some View {
        LazyVStack(spacing: 0) {
            Divider().padding(.horizontal, 20)
            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, track in
                HStack(spacing: 0) {
                    Circle()
                        .fill(stats.isFavorite(track) ? Color.secondary : .clear)
                        .frame(width: 5, height: 5)
                        .frame(width: 16)
                    TrackRow(track: track, number: track.trackNumber ?? i + 1)
                        .padding(.vertical, 12)
                        .padding(.trailing, 16)
                }
                .contentShape(Rectangle())
                .onTapGesture { player.play(album.tracks, startAt: i) }
                .swipeToPlayNext(track)
                Divider().padding(.leading, 54).padding(.trailing, 20)
            }
        }
    }

    private func footer(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("\(album.tracks.count) titre\(album.tracks.count > 1 ? "s" : ""), \(formatTotal(album.totalDuration))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            if let credits = library.credits(for: album) {
                AlbumCreditsSection(album: album, credits: credits)
            }

            let others = (library.artist(named: album.artist)?.albums ?? []).filter { $0.id != album.id }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Plus de \(album.artist)").font(.title3.bold()).padding(.horizontal, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(others) { other in
                                NavigationLink(value: other) { AlbumCell(album: other).frame(width: 150) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Artistes

struct ArtistsView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        List(library.artists) { artist in
            NavigationLink(value: artist) {
                HStack(spacing: 14) {
                    ArtworkView(url: library.artistImageURL(artist), cornerRadius: 26, placeholderSeed: artist.id)
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

/// Routes « Tout voir » (navigation par valeur, pour éviter les retours en arrière intempestifs).
struct DiscographyRoute: Hashable { let artist: String; let kind: ReleaseKind }
struct ArtistSongsRoute: Hashable { let artist: String }

extension Artist {
    @MainActor func releases(_ kind: ReleaseKind) -> [Album] {
        let stats = Stats.shared
        switch kind {
        case .popular:
            return albums.sorted { a, b in
                let pa = a.tracks.reduce(0) { $0 + stats.plays($1) }
                let pb = b.tracks.reduce(0) { $0 + stats.plays($1) }
                return pa == pb ? a.latestAdded > b.latestAdded : pa > pb
            }
        case .albums: return albums.filter(\.isFullAlbum).sorted { $0.latestAdded > $1.latestAdded }
        case .eps: return albums.filter { !$0.isFullAlbum }.sorted { $0.latestAdded > $1.latestAdded }
        }
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
    @State private var collapsed = false
    @AppStorage("manageMode") private var manageMode = false
    let name: String

    private var artist: Artist? { library.artist(named: name) }
    private let heroHeight: CGFloat = 400

    var body: some View {
        if let artist {
          ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    hero(artist)

                    // Résumé Wikipédia, juste sous la photo.
                    ArtistAboutSection(name: artist.name)

                    let top = Stats.shared.top(artist.tracks, limit: 5)
                    let topSongs = top.isEmpty ? Array(artist.tracks.prefix(5)) : top
                    if !topSongs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            sectionTitle("Top titres", value: ArtistSongsRoute(artist: artist.name))
                            LazyVStack(spacing: 0) {
                                ForEach(Array(topSongs.enumerated()), id: \.element.id) { i, track in
                                    HStack(spacing: 12) {
                                        Text("\(i + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                                        TrackRow(track: track)
                                    }
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                    .onTapGesture { player.play(topSongs, startAt: i) }
                                    .swipeToPlayNext(track)
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
            // Va chercher le résumé Wikipédia dès que la page s'ouvre.
            .task(id: artist.name) { await ArtistBios.shared.load(artist.name) }
            .onPreferenceChange(HeaderOffsetKey.self) { y in
                let c = y < -(heroHeight - 110)
                if c != collapsed { withAnimation(.easeInOut(duration: 0.2)) { collapsed = c } }
            }
            .ignoresSafeArea(edges: .top)

            // Barre compacte avec le nom, qui apparaît quand la photo est passée.
            if collapsed {
                Text(artist.name)
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.horizontal, 70)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(.bar, ignoresSafeAreaEdges: .top)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
          }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if manageMode {
                    ToolbarItem(placement: .topBarTrailing) { ArtistPhotoPicker(artist: artist.name) }
                }
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
        } else {
            ContentUnavailableView("Artiste introuvable", systemImage: "music.mic")
        }
    }

    // Grande photo de l'artiste, nom en bas à gauche, bouton lecture en bas à droite.
    private func hero(_ artist: Artist) -> some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .named("artistScroll")).minY
            let stretch = max(minY, 0)
            ZStack(alignment: .bottomLeading) {
                let side = max(geo.size.width, heroHeight + stretch)
                ArtworkView(url: library.artistImageURL(artist), cornerRadius: 0, placeholderSeed: artist.id)
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

    private func sectionTitle<V: Hashable>(_ title: String, value: V) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold())
            Spacer()
            NavigationLink(value: value) {
                Text("Tout voir").font(.body.weight(.medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // « Discographie » : filtres en pastilles + grille 2 colonnes.
    private func discography(_ artist: Artist) -> some View {
        let kinds = ReleaseKind.allCases.filter { $0 == .popular || !artist.releases($0).isEmpty }
        let list = artist.releases(filter)
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Discographie", value: DiscographyRoute(artist: artist.name, kind: filter))
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
                            .zoomSource(id: album.id)
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
    @EnvironmentObject private var library: LibraryStore
    let route: DiscographyRoute

    var body: some View {
        ScrollView {
            ReleaseGrid(albums: library.artist(named: route.artist)?.releases(route.kind) ?? []).padding(20)
        }
        .navigationTitle(route.kind.rawValue)
        .navigationBarTitleDisplayMode(.large)
    }
}

/// « Tout voir » des titres d'un artiste.
struct ArtistSongsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    let artistName: String

    var body: some View {
        let tracks = library.artist(named: artistName)?.tracks ?? []
        List {
            PlayShuffleButtons(play: { player.play(tracks) }, shuffle: { player.play(tracks, shuffled: true) })
                .listRowSeparator(.hidden)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track).onTapGesture { player.play(tracks, startAt: i) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(artistName)
    }
}

// MARK: - Morceaux

struct SongsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var stats = Stats.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @AppStorage("songSort") private var order: SortOrder = .title
    @AppStorage("songFilter") private var filter: LibraryFilter = .all
    @State private var query = ""

    private var shown: [Track] {
        let base = library.tracks.filter { $0.matches(filter, stats: stats, downloads: downloads) && $0.matchesSearch(query) }
        switch order {
        case .title: return base.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: return base.sorted {
            let c = $0.displayArtist.localizedCaseInsensitiveCompare($1.displayArtist)
            return c == .orderedSame ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : c == .orderedAscending
        }
        case .recent: return base.sorted { $0.createdAt > $1.createdAt }
        case .plays: return base.sorted { stats.plays($0) > stats.plays($1) }
        case .year:
            let years = Dictionary(base.map { t in (t.id, library.album(for: t)?.sortYear ?? 0) }, uniquingKeysWith: { x, _ in x })
            return base.sorted { (years[$0.id] ?? 0) > (years[$1.id] ?? 0) }
        }
    }

    var body: some View {
        let songs = shown
        List {
            FilterChips(selection: $filter, options: LibraryFilter.songOptions)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
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
        .searchable(text: $query, prompt: "Rechercher un son, un artiste, un album")
        .overlay {
            if library.tracks.isEmpty {
                EmptyLibraryView()
            } else if songs.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("Aucun son", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Aucun son ne correspond à « \(filter.rawValue) »."))
                        .padding(.top, 60)
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle("Morceaux")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SortMenu(order: $order) } }
        .refreshable { await library.refresh() }
    }
}

/// Explication de l'album (fichier « description » sur le PC) : 3 lignes puis « PLUS », comme Apple Music.
struct AlbumDescription: View {
    let title: String
    let text: String
    @State private var showAll = false

    var body: some View {
        Button { showAll = true } label: {
            VStack(alignment: .trailing, spacing: 2) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("PLUS")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showAll) {
            NavigationStack {
                ScrollView {
                    Text(text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .textSelection(.enabled)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("OK") { showAll = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
