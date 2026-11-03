import SwiftUI
import UIKit

extension Color {
    /// Rouge rosé façon Apple Music.
    static let accentPink = Color(red: 0.98, green: 0.18, blue: 0.28)
}

// MARK: - Chargement des pochettes

actor ImageLoader {
    static let shared = ImageLoader()
    private let memory = NSCache<NSURL, UIImage>()

    func image(for url: URL) async -> UIImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    var placeholderSeed: String = ""

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
            .task(id: url) {
                image = nil
                if let url { image = await ImageLoader.shared.image(for: url) }
            }
    }

    private var placeholder: some View {
        // Couleur stable d'un lancement à l'autre, propre à chaque album.
        let seed = placeholderSeed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = Double(seed % 360) / 360
        return LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85),
                                       Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.55)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                GeometryReader { geo in
                    Image(systemName: "music.note")
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: geo.size.width * 0.4, height: geo.size.height * 0.4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }
}

/// Image chargée pour les fonds flous (lecteur plein écran).
struct BlurredBackdrop: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 70, opaque: true)
                    .saturation(1.6)
                    .overlay(Color.black.opacity(0.35))
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .task(id: url) {
            guard let url else { image = nil; return }
            let loaded = await ImageLoader.shared.image(for: url)
            withAnimation(.easeInOut(duration: 0.4)) { image = loaded }
        }
    }
}

// MARK: - Lignes de morceaux

struct TrackRow: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    let track: Track
    var number: Int? = nil
    var showArtwork = true

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Group {
                    if player.current?.id == track.id {
                        NowPlayingBars(animating: player.isPlaying)
                    } else {
                        Text("\(number)").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22)
            } else if showArtwork {
                ArtworkView(url: library.coverURL(track), cornerRadius: 5, placeholderSeed: track.albumKey)
                    .frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(player.current?.id == track.id && number == nil ? Color.accentPink : .primary)
                if number == nil || track.artist != (library.album(for: track)?.artist ?? "") {
                    Text(track.displayArtist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            TrackMenu(track: track)
        }
        .contentShape(Rectangle())
    }
}

struct TrackMenu: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    let track: Track
    var playlistContext: Playlist? = nil

    var body: some View {
        Menu {
            Button { player.playNext(track) } label: { Label("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { player.addToQueue(track) } label: { Label("Lire en dernier", systemImage: "text.line.last.and.arrowtriangle.forward") }
            Menu {
                Button {
                    Task { await library.createPlaylist(name: track.title, trackIds: [track.id]) }
                } label: { Label("Nouvelle playlist", systemImage: "plus") }
                ForEach(library.playlists) { p in
                    Button(p.name) { Task { await library.add(track, to: p) } }
                }
            } label: { Label("Ajouter à une playlist", systemImage: "text.badge.plus") }
            if let playlistContext {
                Button(role: .destructive) {
                    var p = playlistContext
                    if let i = p.trackIds.firstIndex(of: track.id) { p.trackIds.remove(at: i) }
                    Task { await library.savePlaylist(p) }
                } label: { Label("Retirer de la playlist", systemImage: "minus.circle") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
    }
}

/// Petites barres animées à la place du numéro de piste en cours.
struct NowPlayingBars: View {
    let animating: Bool
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3) { i in
                Capsule()
                    .fill(Color.accentPink)
                    .frame(width: 3, height: animating ? (phase ? [12, 6, 10][i] : [5, 13, 7][i]) : 4)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .animation(animating ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true) : .default, value: phase)
        .onAppear { phase.toggle() }
    }
}

/// Boutons « Lecture » et « Aléatoire » en haut des albums et playlists.
struct PlayShuffleButtons: View {
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            button("Lecture", icon: "play.fill", action: play)
            button("Aléatoire", icon: "shuffle", action: shuffle)
        }
    }

    private func button(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(Color.accentPink)
        }
        .buttonStyle(.plain)
    }
}

struct AlbumCell: View {
    @EnvironmentObject private var library: LibraryStore
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: library.coverURL(album.coverTrack), cornerRadius: 8, placeholderSeed: album.id)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.name).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                Text(album.artist).font(.subheadline).lineLimit(1).foregroundStyle(.secondary)
            }
        }
    }
}

struct EmptyLibraryView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Aucune musique", systemImage: "music.note.house")
        } description: {
            Text("Dépose des sons dans le dossier Mixtape de ton PC : ils apparaîtront ici.")
        }
    }
}
