import CoreImage
import SwiftUI
import UIKit

// MARK: - Chargement des pochettes

actor ImageLoader {
    static let shared = ImageLoader()
    private let memory = NSCache<NSURL, UIImage>()
    /// Copie des pochettes sur l'iPhone : elles s'affichent même sans réseau.
    private let folder: URL = {
        let f = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pochettes", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()

    /// Nom de fichier stable (sans le mot de passe de l'adresse) : « chemin_version.jpg ».
    private func diskNames(for url: URL) -> (prefix: String, file: String) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let version = comps?.queryItems?.first(where: { $0.name == "v" })?.value ?? "0"
        let path = url.path.unicodeScalars.reduce(into: UInt64(1469598103934665603)) { h, c in
            h = (h ^ UInt64(c.value)) &* 1099511628211
        }
        let prefix = String(path, radix: 36)
        return (prefix, "\(prefix)_\(version).jpg")
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        let names = diskNames(for: url)
        let file = folder.appendingPathComponent(names.file)
        // 1. Déjà sur l'iPhone, dans la bonne version.
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: url as NSURL)
            return img
        }
        // 2. Depuis le PC.
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 12
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let full = UIImage(data: data) {
            // Les pochettes du serveur peuvent faire 3000 px : on les réduit et on les décode
            // ici, hors de l'écran, pour que le défilement reste fluide.
            let image = await Self.prepared(full)
            memory.setObject(image, forKey: url as NSURL)
            removeOldVersions(prefix: names.prefix)
            if let jpeg = image.jpegData(compressionQuality: 0.85) { try? jpeg.write(to: file, options: .atomic) }
            return image
        }
        // 3. Hors ligne : une ancienne version de la pochette vaut mieux que rien.
        if let old = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            .first(where: { $0.hasPrefix(names.prefix + "_") }),
           let data = try? Data(contentsOf: folder.appendingPathComponent(old)),
           let img = UIImage(data: data) {
            memory.setObject(img, forKey: url as NSURL)
            return img
        }
        return nil
    }

    private func removeOldVersions(prefix: String) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in files where name.hasPrefix(prefix + "_") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static func prepared(_ image: UIImage) async -> UIImage {
        let maxSide: CGFloat = 900
        let side = max(image.size.width, image.size.height)
        if side > maxSide {
            let scale = maxSide / side
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            if let small = await image.byPreparingThumbnail(ofSize: size) { return small }
        }
        return await image.byPreparingForDisplay() ?? image
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
                // On garde l'image affichée jusqu'à ce que la nouvelle soit prête : pas de flash.
                guard let url else { image = nil; return }
                let loaded = await ImageLoader.shared.image(for: url)
                if !Task.isCancelled { image = loaded }
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
        guard let c = hsb(of: image) else { return nil }
        // Couleur vive mais assez sombre pour que le texte blanc reste lisible.
        return Color(hue: c.h, saturation: min(max(c.s * 1.3, 0.25), 0.85), brightness: min(max(c.b, 0.35), 0.6))
    }

    /// Fond de page d'album : la couleur de la pochette, en plus sombre (comme Apple Music).
    static func background(of image: UIImage) -> Color? {
        guard let c = hsb(of: image) else { return nil }
        return Color(hue: c.h, saturation: min(c.s * 1.15, 0.7), brightness: min(max(c.b * 0.6, 0.1), 0.3))
    }

    /// Fond de page artiste : la couleur du BAS de la photo, assez soutenue (comme Apple Music),
    /// pour que la photo se fonde dans la page sans démarcation.
    static func bottomBackground(of image: UIImage) -> Color? {
        guard let c = hsb(of: image, bottomFraction: 0.3) else { return nil }
        return Color(hue: c.h, saturation: min(c.s * 1.1, 0.75), brightness: min(max(c.b * 0.85, 0.22), 0.5))
    }

    private static func hsb(of image: UIImage, bottomFraction: CGFloat = 1) -> (h: Double, s: Double, b: Double)? {
        guard let input = CIImage(image: image) else { return nil }
        // (Core Image compte les y depuis le bas : la bande du bas commence à minY.)
        var area = input.extent
        area.size.height *= bottomFraction
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: area)]),
              let output = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h: Double(h), s: Double(s), b: Double(b))
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
    /// Menu « … » du lecteur plein écran : ajoute annoter, minuterie et écoute à plusieurs.
    var nowPlaying = false
    var onAnnotate: (() -> Void)? = nil
    var onParty: (() -> Void)? = nil

    // Lus sans « observer » : sinon le menu ouvert se redessine (et clignote)
    // à chaque pour-cent d'un téléchargement en cours.
    private var downloads: DownloadManager { DownloadManager.shared }
    private var stats: Stats { Stats.shared }
    @State private var showCredits = false
    @State private var showEditor = false
    @State private var showAnnotations = false
    @State private var showStory = false
    @AppStorage("manageMode") private var manageMode = false

    var body: some View {
        Menu {
            // Rangé comme Apple Music : une rangée d'icônes en haut, puis quelques lignes.
            ControlGroup {
                Button { player.playNext(track) } label: { Label("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button { player.addToQueue(track) } label: { Label("Lire en dernier", systemImage: "text.line.last.and.arrowtriangle.forward") }
                if downloads.isDownloaded(track) {
                    Button(role: .destructive) { downloads.remove([track]) } label: { Label("Retirer", systemImage: "trash") }
                } else {
                    Button { downloads.download([track], api: library.api) } label: { Label("Télécharger", systemImage: "arrow.down.circle") }
                }
            }
            .controlGroupStyle(.compactMenu)
            Section {
                Menu {
                    Button {
                        Task { await library.createPlaylist(name: track.title, trackIds: [track.id]) }
                    } label: { Label("Nouvelle playlist", systemImage: "plus") }
                    ForEach(library.playlists) { p in
                        Button(p.name) { Task { await library.add(track, to: p) } }
                    }
                } label: { Label("Ajouter à une playlist", systemImage: "text.badge.plus") }
                Menu {
                    Button { ShareManager.shared.share(track, api: library.api) } label: {
                        Label("Partager le son", systemImage: "square.and.arrow.up")
                    }
                    Button { ShareManager.shared.shareListenLink(track, api: library.api) } label: {
                        Label("Lien d'écoute (24 h)", systemImage: "link")
                    }
                    Button { showStory = true } label: {
                        Label("Carte pour story", systemImage: "rectangle.portrait.on.rectangle.portrait")
                    }
                } label: { Label("Partager", systemImage: "square.and.arrow.up") }
                if !nowPlaying {
                    // (Dans le lecteur, le cœur est déjà à côté du titre.)
                    Button { stats.toggleFavorite(track) } label: {
                        stats.isFavorite(track)
                            ? Label("Retirer des favoris", systemImage: "heart.slash")
                            : Label("Ajouter aux favoris", systemImage: "heart")
                    }
                }
            }
            Section {
                Button { player.navRequest = .album(track.albumKey) } label: {
                    Label(track.albumKey.hasPrefix("single:") ? "Aller au single" : "Aller à l'album", systemImage: "square.stack")
                }
                Button { player.navRequest = .artist(library.album(for: track)?.artist ?? track.artist) } label: {
                    Label("Aller à l'artiste", systemImage: "music.mic")
                }
            }
            Section {
                Menu {
                    if let onAnnotate {
                        Button(action: onAnnotate) { Label("Annoter ce passage", systemImage: "square.and.pencil") }
                    }
                    Button { showAnnotations = true } label: {
                        let n = AnnotationStore.shared.count(for: track.id)
                        Label(n > 0 ? "Voir les annotations (\(n))" : "Voir les annotations", systemImage: "text.bubble")
                    }
                    if library.albumCredits[track.albumKey] != nil {
                        Button { showCredits = true } label: { Label("Crédits", systemImage: "person.2") }
                    }
                    if manageMode {
                        Button { showEditor = true } label: { Label("Modifier le son", systemImage: "pencil") }
                    }
                } label: { Label("Plus", systemImage: "ellipsis.circle") }
                if nowPlaying {
                    sleepTimerMenu
                }
                if let onParty {
                    Button(action: onParty) { Label("Écouter avec quelqu'un", systemImage: "person.2.wave.2") }
                }
                if let playlistContext {
                    Button(role: .destructive) {
                        var p = playlistContext
                        if let i = p.trackIds.firstIndex(of: track.id) { p.trackIds.remove(at: i) }
                        Task { await library.savePlaylist(p) }
                    } label: { Label("Retirer de la playlist", systemImage: "minus.circle") }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(nowPlaying ? Color.white : Color.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Plus d'options")
        .sheet(isPresented: $showCredits) { TrackCreditsSheet(track: track) }
        .sheet(isPresented: $showEditor) { TrackEditorView(track: track) }
        .sheet(isPresented: $showAnnotations) { AnnotationsListSheet(track: track) }
        .sheet(isPresented: $showStory) { StoryCardSheet(track: track) }
    }

    /// Minuterie de mise en veille (avant : un bouton « lune » dans le lecteur).
    private var sleepTimerMenu: some View {
        let active = player.sleepTimerEnd != nil || player.stopAtEndOfTrack
        return Menu {
            if let end = player.sleepTimerEnd {
                Text("Arrêt à \(end.formatted(date: .omitted, time: .shortened))")
            } else if player.stopAtEndOfTrack {
                Text("Arrêt à la fin du morceau")
            }
            Button("15 minutes") { player.setSleepTimer(minutes: 15) }
            Button("30 minutes") { player.setSleepTimer(minutes: 30) }
            Button("45 minutes") { player.setSleepTimer(minutes: 45) }
            Button("1 heure") { player.setSleepTimer(minutes: 60) }
            Button("À la fin du morceau") { player.sleepAtEndOfTrack() }
            if active {
                Button("Désactiver la minuterie", role: .destructive) { player.setSleepTimer(minutes: nil) }
            }
        } label: {
            Label(active ? "Minuterie (active)" : "Minuterie", systemImage: active ? "moon.zzz.fill" : "moon.zzz")
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
                .zoomSource(id: album.id)
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
            Button {
                ShareManager.shared.shareAlbum(album, api: library.api, coverURL: library.coverURL(album.coverTrack))
            } label: {
                Label(album.isSingle ? "Partager le single" : "Partager l'album", systemImage: "square.and.arrow.up")
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

// MARK: - Balayer vers la droite = « Lire ensuite »

/// Pour les listes qui ne sont pas des `List` (page album, artiste, téléchargements…) :
/// on glisse le son vers la droite, une pastille rose apparaît, et en lâchant il passe en prochain titre.
struct SwipeToPlayNext: ViewModifier {
    @EnvironmentObject private var player: PlayerModel
    let track: Track
    @State private var offset: CGFloat = 0
    @State private var horizontal: Bool? = nil
    @State private var done = 0
    private let threshold: CGFloat = 80

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .leading) {
                if offset > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        if offset > threshold { Text("Lire ensuite").font(.subheadline.weight(.semibold)) }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(maxHeight: .infinity)
                    .frame(width: max(offset, 0), alignment: .leading)
                    .background(Color.accentPink.opacity(offset > threshold ? 1 : 0.6))
                    .clipped()
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { g in
                        // On décide une fois pour toutes : glissement horizontal, ou défilement normal.
                        if horizontal == nil {
                            horizontal = abs(g.translation.width) > abs(g.translation.height) * 1.5 && g.translation.width > 0
                        }
                        guard horizontal == true else { return }
                        let x = max(0, g.translation.width)
                        offset = x > threshold ? threshold + (x - threshold) * 0.3 : x
                    }
                    .onEnded { _ in
                        if horizontal == true, offset > threshold {
                            player.playNext(track)
                            done += 1
                        }
                        horizontal = nil
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
                    }
            )
            .sensoryFeedback(.success, trigger: done)
    }
}

extension View {
    func swipeToPlayNext(_ track: Track) -> some View { modifier(SwipeToPlayNext(track: track)) }
}
