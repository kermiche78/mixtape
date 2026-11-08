import AVFoundation
import SwiftUI
import UIKit

// MARK: - Clips vidéo

/// Vidéo muette calée sur le son en cours (le son vient toujours du lecteur).
/// Un seul lecteur vidéo pour tout l'app : passer en plein écran réutilise la vidéo déjà chargée,
/// sans écran noir ni nouveau téléchargement.
@MainActor
final class ClipVideo: ObservableObject {
    static let shared = ClipVideo()

    let player = AVPlayer()
    private var url: URL?
    private var lastSeek = Date.distantPast
    private var users = 0

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.automaticallyWaitsToMinimizeStalling = false
    }

    func attach(_ newURL: URL, at time: Double, playing: Bool) {
        users += 1
        load(newURL, at: time, playing: playing)
    }

    /// Un affichage du clip disparaît : on ne coupe la vidéo que si plus personne ne l'affiche.
    func detach() {
        users = max(users - 1, 0)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if self.users == 0 { self.stop() }
        }
    }

    func load(_ newURL: URL, at time: Double, playing: Bool) {
        guard newURL != url else {
            follow(time: time, playing: playing, force: true)
            return
        }
        url = newURL
        player.replaceCurrentItem(with: AVPlayerItem(url: newURL))
        seek(time)
        if playing { player.play() }
    }

    /// Recale la vidéo sur le son. Un saut (avancer, reculer) est suivi tout de suite.
    func follow(time: Double, playing: Bool, force: Bool = false) {
        let current = player.currentTime().seconds
        if current.isFinite {
            let gap = abs(current - time)
            if gap > 2.5 || force && gap > 0.3 || (gap > 0.8 && Date().timeIntervalSince(lastSeek) > 1.5) {
                seek(time)
            }
        }
        if playing, player.rate == 0 {
            player.play()
        } else if !playing, player.rate != 0 {
            player.pause()
        }
    }

    private func seek(_ time: Double) {
        lastSeek = Date()
        player.seek(to: CMTime(seconds: max(time, 0), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        url = nil
    }
}

/// Affichage de la vidéo, sans les commandes d'iOS.
struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// Clip calé sur le son en cours.
struct ClipPlayerView: View {
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject var clock: PlaybackClock
    @ObservedObject private var video = ClipVideo.shared
    let url: URL

    var body: some View {
        VideoLayerView(player: video.player)
            .onAppear { video.attach(url, at: clock.currentTime, playing: player.isPlaying) }
            .onChange(of: url) { _, newURL in video.load(newURL, at: clock.currentTime, playing: player.isPlaying) }
            .onChange(of: clock.currentTime) { _, t in video.follow(time: t, playing: player.isPlaying) }
            .onChange(of: player.isPlaying) { _, playing in video.follow(time: clock.currentTime, playing: playing) }
            .onDisappear { video.detach() }
    }
}

/// Clip en plein écran (à l'horizontale).
struct ClipFullScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let track = player.current, library.hasClip(track), let url = library.api?.clipURL(for: track) {
                ClipPlayerView(clock: player.clock, url: url).ignoresSafeArea()
            } else {
                Text("Pas de clip pour ce son").foregroundStyle(.white.opacity(0.7))
            }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .liquidGlass(in: Circle(), interactive: true)
            }
            .padding(20)
            .accessibilityLabel("Fermer le clip")
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                ClipScrubber(clock: player.clock)
                HStack(spacing: 26) {
                    Button { player.previous() } label: { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Son précédent")
                    Button { jump(-10) } label: { Image(systemName: "gobackward.10") }
                        .accessibilityLabel("Reculer de 10 secondes")
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Button { jump(10) } label: { Image(systemName: "goforward.10") }
                        .accessibilityLabel("Avancer de 10 secondes")
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                        .accessibilityLabel("Son suivant")
                }
                .font(.title2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: 560)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.bottom, 16)
            .padding(.horizontal, 30)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { AppDelegate.lock(.landscape) }
        .onDisappear { AppDelegate.lock(.portrait) }
    }

    private func jump(_ seconds: Double) {
        let target = min(max(player.clock.currentTime + seconds, 0), max(player.duration - 1, 0))
        player.seek(to: target)
    }
}

/// Barre de lecture du clip en plein écran : on fait glisser pour avancer ou reculer.
struct ClipScrubber: View {
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject var clock: PlaybackClock
    @State private var dragging: Double?

    var body: some View {
        let duration = max(player.duration, 1)
        let shown = dragging ?? min(clock.currentTime, duration)
        HStack(spacing: 10) {
            Text(Self.format(shown)).monospacedDigit()
            Slider(value: Binding(get: { shown }, set: { dragging = $0 }), in: 0...duration) { editing in
                if !editing, let target = dragging {
                    player.seek(to: target)
                    dragging = nil
                }
            }
            .tint(.white)
            Text("-" + Self.format(max(duration - shown, 0))).monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.85))
    }

    static func format(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Icône de l'app

/// Icônes au choix (fabriquées pendant la compilation) + celle de l'utilisateur.
struct AppIconPicker: View {
    @State private var current: String? = UIApplication.shared.alternateIconName
    @State private var error: String?

    private static let labels: [String: String] = [
        "AppIcon-Noir": "Noir", "AppIcon-Blanc": "Blanc", "AppIcon-Vinyle": "Vinyle", "AppIcon-Casque": "Casque",
        "AppIcon-Studio": "Studio", "AppIcon-Neon": "Néon", "AppIcon-Perso": "La tienne",
    ]
    private static let order = ["AppIcon-Noir", "AppIcon-Blanc", "AppIcon-Vinyle", "AppIcon-Casque",
                                "AppIcon-Studio", "AppIcon-Neon", "AppIcon-Perso"]

    /// Icônes réellement présentes dans l'app installée.
    private var available: [String] {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let alternates = (icons?["CFBundleAlternateIcons"] as? [String: Any]).map { Array($0.keys) } ?? []
        return Self.order.filter { alternates.contains($0) } + alternates.filter { !Self.order.contains($0) }.sorted()
    }

    var body: some View {
        let names: [String?] = [nil] + available.map { Optional($0) }
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                ForEach(names, id: \.self) { name in
                    Button { choose(name) } label: {
                        VStack(spacing: 6) {
                            preview(name)
                                .frame(width: 58, height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(.primary.opacity(current == name ? 0.9 : 0), lineWidth: 2.5)
                                        .padding(-4)
                                )
                            Text(name.flatMap { Self.labels[$0] } ?? (name == nil ? "Classique" : name!.replacingOccurrences(of: "AppIcon-", with: "")))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
                if !available.contains("AppIcon-Perso") {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .foregroundStyle(.secondary)
                            .frame(width: 58, height: 58)
                            .overlay(Image(systemName: "photo.badge.plus").foregroundStyle(.secondary))
                        Text("La tienne").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func preview(_ name: String?) -> some View {
        let asset = "IconPreview-" + (name.map { $0.replacingOccurrences(of: "AppIcon-", with: "") } ?? "Classique")
        if let image = UIImage(named: asset) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.accentPink.overlay(Image(systemName: "music.note").foregroundStyle(.white))
        }
    }

    private func choose(_ name: String?) {
        guard UIApplication.shared.supportsAlternateIcons, name != current else { return }
        UIApplication.shared.setAlternateIconName(name) { err in
            Task { @MainActor in
                if let err {
                    error = "Impossible de changer l'icône : \(err.localizedDescription)"
                } else {
                    error = nil
                    current = name
                }
            }
        }
    }
}
