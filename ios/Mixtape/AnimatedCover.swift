import AVFoundation
import CryptoKit
import SwiftUI
import UIKit

// MARK: - Pochettes animées
//
// Une vidéo nommée « cover animé » (mp4 ou mov) dans le dossier d'un album sur le PC
// tourne en boucle à la place de la pochette, sur la page de l'album et dans le lecteur.
// Réglages → Lecture → Pochettes animées pour tout couper, ou menu « … » d'un album
// pour choisir la pochette fixe sur cet album seulement.

/// Garde les vidéos sur l'iPhone : chaque pochette animée n'est téléchargée qu'une fois.
actor AnimatedCoverCache {
    static let shared = AnimatedCoverCache()

    private var inFlight: [String: Task<URL?, Never>] = [:]
    private let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("pochettes-animees", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func name(albumKey: String, version: Int) -> String {
        let hash = SHA256.hash(data: Data(albumKey.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return "\(hash)-\(version).mp4"
    }

    func file(albumKey: String, version: Int, remote: URL) async -> URL? {
        let fileName = name(albumKey: albumKey, version: version)
        let dest = folder.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        if let task = inFlight[fileName] { return await task.value }
        let folder = folder
        let task = Task<URL?, Never> {
            do {
                let (tmp, response) = try await URLSession.shared.download(from: remote)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                // Les anciennes versions de cette pochette ne servent plus.
                let prefix = String(fileName.split(separator: "-").first ?? "")
                for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                where old.lastPathComponent.hasPrefix(prefix + "-") {
                    try? FileManager.default.removeItem(at: old)
                }
                try FileManager.default.moveItem(at: tmp, to: dest)
                return dest
            } catch {
                return nil
            }
        }
        inFlight[fileName] = task
        let result = await task.value
        inFlight[fileName] = nil
        return result
    }
}

/// Lecture en boucle, muette (le son de Mixtape n'est jamais coupé).
@MainActor
final class LoopingVideo: ObservableObject {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var url: URL?

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
    }

    func load(_ newURL: URL) {
        guard newURL != url else { return }
        url = newURL
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: newURL))
        player.play()
    }

    func resume() { if url != nil { player.play() } }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        url = nil
    }
}

/// Couche vidéo transparente tant que la première image n'est pas prête : la pochette fixe reste visible dessous.
struct LoopingVideoLayer: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// Pochette d'un son : animée si l'album en a une (et si c'est activé), sinon la pochette normale.
struct AnimatedArtworkView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("animatedCoversOn") private var animatedOn = true
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var video = LoopingVideo()
    @State private var localFile: URL?

    let track: Track?
    var cornerRadius: CGFloat = 8
    var placeholderSeed: String = ""

    private var wanted: (key: String, version: Int, remote: URL)? {
        guard animatedOn, let track, let info = library.animatedCover(for: track) else { return nil }
        return (track.albumKey, info.version, info.url)
    }

    var body: some View {
        ArtworkView(url: library.coverURL(track), cornerRadius: cornerRadius, placeholderSeed: placeholderSeed)
            .overlay {
                if localFile != nil {
                    LoopingVideoLayer(player: video.player)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .transition(.opacity)
                }
            }
            .task(id: wanted.map { "\($0.key)#\($0.version)" } ?? "") {
                guard let target = wanted else {
                    video.stop()
                    withAnimation(.easeOut(duration: 0.3)) { localFile = nil }
                    return
                }
                guard let file = await AnimatedCoverCache.shared.file(albumKey: target.key, version: target.version,
                                                                      remote: target.remote),
                      !Task.isCancelled else { return }
                video.load(file)
                withAnimation(.easeIn(duration: 0.4)) { localFile = file }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { video.resume() } }
            .onDisappear { video.stop(); localFile = nil }
    }
}

/// Choix « animée / fixe » pour un album, dans son menu « … ».
struct AnimatedCoverMenuButton: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("animatedCoversOn") private var animatedOn = true
    let album: Album

    var body: some View {
        if library.hasAnimatedCover(album) {
            if !animatedOn {
                Button { animatedOn = true; library.setStaticCover(false, for: album) } label: {
                    Label("Activer les pochettes animées", systemImage: "play.square.stack")
                }
            } else if library.usesStaticCover(album) {
                Button { library.setStaticCover(false, for: album) } label: {
                    Label("Pochette animée", systemImage: "play.square")
                }
            } else {
                Button { library.setStaticCover(true, for: album) } label: {
                    Label("Pochette fixe", systemImage: "photo")
                }
            }
        }
    }
}
