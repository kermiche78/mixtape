import SwiftUI

/// Onglet « Accueil » : ce que tu as écouté, les nouveautés de tes potes, les artistes.
struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var stats = Stats.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if library.isOffline { OfflineBanner().padding(.horizontal, 20) }
                TodayListeningLine().padding(.horizontal, 20)
                if library.tracks.isEmpty && !library.isLoading {
                    EmptyLibraryView().padding(.top, 60)
                } else {
                    let recent = player.recentlyPlayed.compactMap { library.track($0) }
                    if !recent.isEmpty {
                        shelf("Écoutés récemment") {
                            ForEach(recentAlbums(from: recent)) { album in
                                NavigationLink(value: album) { AlbumCell(album: album).frame(width: 150) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }

                    SmartPlaylistsShelf()

                    let favs = library.tracks.filter { Stats.shared.isFavorite($0) }
                    let top = Stats.shared.top(library.tracks, limit: 8)
                    if !top.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Les plus écoutés").font(.title2.bold()).padding(.horizontal, 20)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHGrid(rows: Array(repeating: GridItem(.fixed(58), spacing: 4), count: 4), spacing: 18) {
                                    ForEach(Array(top.enumerated()), id: \.element.id) { i, track in
                                        TrackRow(track: track)
                                            .frame(width: 300)
                                            .onTapGesture { player.play(top, startAt: i) }
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                            .scrollTargetBehavior(.viewAligned)
                        }
                    }

                    if !favs.isEmpty {
                        NavigationLink(value: LibrarySection.favorites) {
                            HStack(spacing: 14) {
                                Image(systemName: "heart.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .frame(width: 56, height: 56)
                                    .background(LinearGradient(colors: [Color.accentPink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Tes favoris").font(.headline)
                                    Text("\(favs.count) son\(favs.count > 1 ? "s" : "")").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                    }

                    if !stats.playCounts.isEmpty {
                        ReplayCard()
                    }

                    shelf("Nouveautés") {
                        ForEach(library.recentlyAdded) { album in
                            NavigationLink(value: album) { AlbumCell(album: album).frame(width: 180) }
                                .buttonStyle(.plain)
                        }
                    }

                    if !library.artists.isEmpty {
                        shelf("Artistes") {
                            ForEach(library.artists) { artist in
                                NavigationLink(value: artist) {
                                    VStack(spacing: 8) {
                                        ArtworkView(url: library.artistImageURL(artist), cornerRadius: 60, placeholderSeed: artist.id)
                                            .frame(width: 120, height: 120)
                                        Text(artist.name).font(.subheadline).lineLimit(1)
                                    }
                                    .frame(width: 120)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !library.tracks.isEmpty {
                        Button {
                            player.play(Array(library.tracks.shuffled().prefix(30)))
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "shuffle")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 56, height: 56)
                                    .background(Color.accentPink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mix aléatoire").font(.headline)
                                    Text("Tous les sons de tes potes, mélangés").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "play.fill").foregroundStyle(Color.accentPink)
                            }
                            .padding(12)
                            .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("Accueil")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LibraryMenu() } }
        .refreshable { await library.refresh() }
        .libraryDestinations()
    }

    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold()).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.horizontal, 20)
            }
        }
    }

    private func recentAlbums(from tracks: [Track]) -> [Album] {
        var seen = Set<String>()
        return tracks.compactMap { library.album(for: $0) }.filter { seen.insert($0.id).inserted }.prefix(10).map { $0 }
    }
}

/// Bouton « … » en verre, en haut à droite : actualiser, télécharger, réglages rapides.
struct LibraryMenu: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        Menu {
            Button { Task { await library.refresh() } } label: {
                Label("Actualiser la bibliothèque", systemImage: "arrow.clockwise")
            }
            Button { DownloadManager.shared.download(library.tracks, api: library.api) } label: {
                Label("Tout télécharger", systemImage: "arrow.down.circle")
            }
            Button { player.play(library.tracks, shuffled: true) } label: {
                Label("Tout lire en aléatoire", systemImage: "shuffle")
            }
            Button { player.showParty = true } label: {
                Label("Mode soirée", systemImage: "party.popper")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Plus d'options")
    }
}
