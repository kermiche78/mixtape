import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                SmartPlaylistRows()
            } header: {
                Text("Faites pour toi").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
            }
            Section {
            Button {
                newName = ""
                showNew = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundStyle(Color.accentPink)
                        .frame(width: 56, height: 56)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("Nouvelle playlist…").foregroundStyle(Color.accentPink)
                }
            }
            ForEach(library.playlists) { playlist in
                NavigationLink(value: playlist) {
                    HStack(spacing: 14) {
                        PlaylistArtwork(playlist: playlist).frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                            Text("\(playlist.trackIds.count) morceau\(playlist.trackIds.count > 1 ? "x" : "")")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { offsets in
                let toDelete = offsets.map { library.playlists[$0] }
                Task { for p in toDelete { await library.deletePlaylist(p) } }
            }
            } header: {
                Text("Mes playlists").font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .refreshable { await library.refresh() }
        .alert("Nouvelle playlist", isPresented: $showNew) {
            TextField("Titre", text: $newName)
            Button("Annuler", role: .cancel) {}
            Button("Créer") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                Task { await library.createPlaylist(name: name.isEmpty ? "Nouvelle playlist" : name) }
            }
        }
    }
}

/// Mosaïque de 4 pochettes, comme dans Apple Music.
struct PlaylistArtwork: View {
    @EnvironmentObject private var library: LibraryStore
    let playlist: Playlist
    var cornerRadius: CGFloat = 6

    var body: some View {
        let covers = uniqueCovers()
        Group {
            if covers.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ArtworkView(url: library.coverURL(covers[0]), cornerRadius: 0, placeholderSeed: covers[0].albumKey)
                        ArtworkView(url: library.coverURL(covers[1]), cornerRadius: 0, placeholderSeed: covers[1].albumKey)
                    }
                    GridRow {
                        ArtworkView(url: library.coverURL(covers[2]), cornerRadius: 0, placeholderSeed: covers[2].albumKey)
                        ArtworkView(url: library.coverURL(covers[3]), cornerRadius: 0, placeholderSeed: covers[3].albumKey)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else if let first = covers.first {
                ArtworkView(url: library.coverURL(first), cornerRadius: cornerRadius, placeholderSeed: first.albumKey)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemFill))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "music.note.list").font(.title).foregroundStyle(.secondary)
                    }
            }
        }
    }

    private func uniqueCovers() -> [Track] {
        var seen = Set<String>()
        return library.tracks(of: playlist).filter { seen.insert($0.albumKey).inserted }
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    let playlistID: String

    @State private var showPicker = false
    @State private var showRename = false
    @State private var newName = ""

    private var playlist: Playlist? { library.playlists.first { $0.id == playlistID } }

    var body: some View {
        if let playlist {
            let tracks = library.tracks(of: playlist)
            List {
                VStack(spacing: 8) {
                    PlaylistArtwork(playlist: playlist, cornerRadius: 10)
                        .frame(width: 250, height: 250)
                        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                        .padding(.bottom, 10)
                    Text(playlist.name).font(.title2.bold()).multilineTextAlignment(.center)
                    if !tracks.isEmpty {
                        PlayShuffleButtons(play: { player.play(tracks) }, shuffle: { player.play(tracks, shuffled: true) })
                            .padding(.top, 12)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))

                Button {
                    showPicker = true
                } label: {
                    Label("Ajouter des morceaux", systemImage: "plus.circle.fill")
                        .foregroundStyle(Color.accentPink)
                }

                ForEach(Array(tracks.enumerated()), id: \.offset) { i, track in
                    TrackRowInPlaylist(track: track, playlist: playlist)
                        .onTapGesture { player.play(tracks, startAt: i) }
                }
                .onDelete { offsets in
                    var p = playlist
                    p.trackIds.remove(atOffsets: offsets)
                    Task { await library.savePlaylist(p) }
                }
                .onMove { from, to in
                    var p = playlist
                    p.trackIds.move(fromOffsets: from, toOffset: to)
                    Task { await library.savePlaylist(p) }
                }

                if !tracks.isEmpty {
                    Text("\(tracks.count) morceau\(tracks.count > 1 ? "x" : ""), \(formatTotal(tracks.reduce(0) { $0 + $1.duration }))")
                        .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Menu {
                        Button { newName = playlist.name; showRename = true } label: { Label("Renommer", systemImage: "pencil") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showPicker) { TrackPickerSheet(playlist: playlist) }
            .alert("Renommer la playlist", isPresented: $showRename) {
                TextField("Titre", text: $newName)
                Button("Annuler", role: .cancel) {}
                Button("OK") {
                    var p = playlist
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { p.name = name }
                    Task { await library.savePlaylist(p) }
                }
            }
        } else {
            ContentUnavailableView("Playlist introuvable", systemImage: "music.note.list")
        }
    }
}

private struct TrackRowInPlaylist: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    let track: Track
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: library.coverURL(track), cornerRadius: 5, placeholderSeed: track.albumKey)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                    .foregroundStyle(player.current?.id == track.id ? Color.accentPink : .primary)
                Text(track.displayArtist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            TrackMenu(track: track, playlistContext: playlist)
        }
        .contentShape(Rectangle())
    }
}

/// Liste de toute la bibliothèque avec des cases à cocher pour remplir une playlist.
struct TrackPickerSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist

    @State private var selected: [String] = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { track in
                    Button {
                        if let i = selected.firstIndex(of: track.id) { selected.remove(at: i) } else { selected.append(track.id) }
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: library.coverURL(track), cornerRadius: 5, placeholderSeed: track.albumKey)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).lineLimit(1).foregroundStyle(.primary)
                                Text(track.displayArtist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "plus.circle")
                                .font(.title3)
                                .foregroundStyle(Color.accentPink)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Rechercher")
            .navigationTitle("Ajouter à « \(playlist.name) »")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        var p = playlist
                        p.trackIds.append(contentsOf: selected)
                        Task { await library.savePlaylist(p) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selected.isEmpty)
                }
            }
        }
        .tint(Color.accentPink)
    }

    private var filtered: [Track] {
        let all = library.tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(q) }
    }
}
