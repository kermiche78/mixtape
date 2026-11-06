import CoreImage
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

/// Couleur dominante d'une pochette (pour teinter les fonds).
enum ArtworkColor {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func average(of image: UIImage) -> Color? {
        guard let input = CIImage(image: image),
              let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let output = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Couleur vive mais assez sombre pour que le texte blanc reste lisible.
        return Color(hue: h, saturation: min(max(s * 1.3, 0.25), 0.85), brightness: min(max(b, 0.35), 0.6))
    }
}

/// Fond du lecteur plein écran : dégradé aux couleurs de la pochette + pochette floutée.
struct BlurredBackdrop: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var tint: Color = Color(white: 0.2)
    @State private var drift = false

    var body: some View {
        // Le fond remplit l'écran SANS dicter sa taille (sinon tout déborde).
        LinearGradient(colors: [tint, tint.opacity(0.75), .black], startPoint: drift ? .topLeading : .top, endPoint: drift ? .bottomTrailing : .bottom)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 80, opaque: true)
                        .saturation(1.5)
                        .opacity(0.55)
                        .blendMode(.plusLighter)
                        .scaleEffect(drift ? 1.25 : 1.1)
                        .transition(.opacity)
                }
            }
            .overlay(Color.black.opacity(0.25))
            .clipped()
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) { drift = true }
            }
            .task(id: url) {
                guard let url else { image = nil; return }
                let loaded = await ImageLoader.shared.image(for: url)
                withAnimation(.easeInOut(duration: 0.6)) {
                    image = loaded
                    if let loaded, let c = ArtworkColor.average(of: loaded) { tint = c }
                }
            }
    }
}

// MARK: - Lignes de morceaux

struct TrackRow: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var stats = Stats.shared
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
                HStack(spacing: 6) {
                    if stats.isNew(track) {
                        Circle().fill(Color.accentPink).frame(width: 7, height: 7)
                            .accessibilityLabel("Nouveau")
                    }
                    Text(track.title)
                        .lineLimit(1)
                        .foregroundStyle(player.current?.id == track.id && number == nil ? Color.accentPink : .primary)
                }
                if number == nil || track.artist != (library.album(for: track)?.artist ?? "") {
                    Text(track.displayArtist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            DownloadBadge(track: track)
            TrackMenu(track: track)
        }
        .contentShape(Rectangle())
        // Balayer vers la droite : ajouter à la file d'attente.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { player.playNext(track) } label: { Label("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") }
                .tint(Color.accentPink)
            Button { player.addToQueue(track) } label: { Label("À la fin", systemImage: "text.line.last.and.arrowtriangle.forward") }
                .tint(.orange)
        }
    }
}

struct TrackMenu: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    let track: Track
    var playlistContext: Playlist? = nil

    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var stats = Stats.shared

    var body: some View {
        Menu {
            Button { stats.toggleFavorite(track) } label: {
                stats.isFavorite(track)
                    ? Label("Retirer des favoris", systemImage: "heart.slash")
                    : Label("Ajouter aux favoris", systemImage: "heart")
            }
            if downloads.isDownloaded(track) {
                Button(role: .destructive) { downloads.remove([track]) } label: {
                    Label("Supprimer le téléchargement", systemImage: "trash")
                }
            } else {
                Button { downloads.download([track], api: library.api) } label: {
                    Label("Télécharger", systemImage: "arrow.down.circle")
                }
            }
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
            Divider()
            Button { player.navRequest = .album(track.albumKey) } label: {
                Label(track.albumKey.hasPrefix("single:") ? "Aller au single" : "Aller à l'album", systemImage: "square.stack")
            }
            Button { player.navRequest = .artist(library.album(for: track)?.artist ?? track.artist) } label: {
                Label("Aller à l'artiste", systemImage: "music.mic")
            }
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
        GlassGroup(spacing: 14) {
            HStack(spacing: 14) {
                button("Lecture", icon: "play.fill", action: play)
                button("Aléatoire", icon: "shuffle", action: shuffle)
            }
        }
    }

    private func button(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(Color.accentPink)
        }
        .glassButton()
        .controlSize(.large)
    }
}

struct AlbumCell: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var stats = Stats.shared
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: library.coverURL(album.coverTrack), cornerRadius: 8, placeholderSeed: album.id)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .overlay(alignment: .topLeading) {
                    if stats.isNew(album) { NewBadge().padding(6) }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(album.name).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                Text(album.artist).font(.subheadline).lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        // Appui long : actions rapides sur l'album.
        .contextMenu {
            Button { player.play(album.tracks) } label: { Label("Lire", systemImage: "play.fill") }
            Button { player.play(album.tracks, shuffled: true) } label: { Label("Lecture aléatoire", systemImage: "shuffle") }
            Button { album.tracks.reversed().forEach { player.playNext($0) } } label: {
                Label("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { album.tracks.forEach { player.addToQueue($0) } } label: {
                Label("Lire en dernier", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Divider()
            if album.tracks.allSatisfy({ downloads.isDownloaded($0) }) {
                Button(role: .destructive) { downloads.remove(album.tracks) } label: { Label("Supprimer le téléchargement", systemImage: "trash") }
            } else {
                Button { downloads.download(album.tracks, api: library.api) } label: { Label("Télécharger", systemImage: "arrow.down.circle") }
            }
        } preview: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(url: library.coverURL(album.coverTrack), cornerRadius: 12, placeholderSeed: album.id)
                    .frame(width: 260, height: 260)
                Text(album.name).font(.headline)
                Text("\(album.artist) · \(album.tracks.count) morceau\(album.tracks.count > 1 ? "x" : "")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}

/// Pastille « NOUVEAU » sur les pochettes.
struct NewBadge: View {
    var body: some View {
        Text("NOUVEAU")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentPink, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
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
