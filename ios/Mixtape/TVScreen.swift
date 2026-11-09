import SwiftUI
import UIKit

// MARK: - Écran télé (AirPlay)
//
// Quand l'iPhone recopie son écran sur une Apple TV ou une télé AirPlay, la télé n'affiche
// plus la copie de l'iPhone mais son propre écran Mixtape : pochette, titre, paroles en rythme
// et sons à suivre. L'iPhone reste libre pendant ce temps.

/// Donne à l'écran télé la bibliothèque et le lecteur de l'app.
@MainActor
final class AppObjects: ObservableObject {
    static let shared = AppObjects()
    @Published var library: LibraryStore?
    @Published var player: PlayerModel?
}

/// Ouvre la fenêtre de la télé quand iOS en crée une (recopie AirPlay ou câble).
final class TVSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let host = UIHostingController(rootView: TVRoot())
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
    }
}

private struct TVRoot: View {
    @ObservedObject private var objects = AppObjects.shared

    var body: some View {
        if let library = objects.library, let player = objects.player {
            TVNowPlayingView()
                .environmentObject(library)
                .environmentObject(player)
                .environment(\.colorScheme, .dark)
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

struct TVNowPlayingView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var lyricsStore = LyricsStore.shared

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let track = player.current
            ZStack {
                BlurredBackdrop(url: library.coverURL(track))

                if let track {
                    HStack(spacing: w * 0.05) {
                        ArtworkView(url: library.coverURL(track), cornerRadius: h * 0.025, placeholderSeed: track.albumKey)
                            .frame(width: h * 0.66, height: h * 0.66)
                            .shadow(color: .black.opacity(0.55), radius: 40, y: 18)
                            .id(track.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))

                        VStack(alignment: .leading, spacing: h * 0.012) {
                            Text("EN CE MOMENT")
                                .font(.system(size: h * 0.022, weight: .heavy))
                                .tracking(2)
                                .foregroundStyle(Color.accentPink)
                            Text(track.title)
                                .font(.system(size: h * 0.075, weight: .heavy))
                                .lineLimit(2)
                                .minimumScaleFactor(0.5)
                            Text(track.displayArtist)
                                .font(.system(size: h * 0.038, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                            MiniProgressLine()
                                .frame(maxWidth: w * 0.35)
                                .scaleEffect(y: 2, anchor: .center)
                                .padding(.vertical, h * 0.015)

                            if let lyrics = lyricsStore.lyrics(for: track.id), !lyrics.lines.isEmpty {
                                TVLyrics(clock: player.clock, lines: lyrics.lines, height: h)
                            }

                            upNext(height: h)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, w * 0.06)
                    .padding(.vertical, h * 0.08)
                    .animation(.easeInOut(duration: 0.6), value: track.id)
                } else {
                    VStack(spacing: h * 0.02) {
                        Image(systemName: "music.note")
                            .font(.system(size: h * 0.12, weight: .semibold))
                        Text("Lance un son sur ton iPhone")
                            .font(.system(size: h * 0.05, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: w, height: h)
        }
        .ignoresSafeArea()
        .task(id: player.current?.id) {
            if let track = player.current { await lyricsStore.load(track, api: library.api) }
        }
    }

    @ViewBuilder
    private func upNext(height h: CGFloat) -> some View {
        let next = Array(player.upNext.prefix(4))
        if !next.isEmpty {
            Text("À SUIVRE")
                .font(.system(size: h * 0.02, weight: .heavy))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, h * 0.02)
            HStack(alignment: .top, spacing: h * 0.02) {
                ForEach(next) { t in
                    VStack(alignment: .leading, spacing: h * 0.006) {
                        ArtworkView(url: library.coverURL(t), cornerRadius: h * 0.01, placeholderSeed: t.albumKey)
                            .frame(width: h * 0.13, height: h * 0.13)
                        Text(t.title)
                            .font(.system(size: h * 0.018, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(width: h * 0.13)
                }
            }
        }
    }
}

/// Trois lignes de paroles : la précédente, celle chantée (en grand), la suivante.
private struct TVLyrics: View {
    @ObservedObject var clock: PlaybackClock
    let lines: [LyricLine]
    let height: CGFloat

    var body: some View {
        let i = lines.lastIndex(where: { $0.t <= clock.currentTime + 0.2 })
        VStack(alignment: .leading, spacing: height * 0.008) {
            line(i.map { $0 - 1 }, size: 0.026, opacity: 0.4)
            line(i, size: 0.042, opacity: 1)
            line(i.map { $0 + 1 } ?? 0, size: 0.026, opacity: 0.4)
        }
        .animation(.easeInOut(duration: 0.3), value: i)
        .padding(.top, height * 0.01)
    }

    @ViewBuilder
    private func line(_ index: Int?, size: CGFloat, opacity: Double) -> some View {
        let text = index.flatMap { lines.indices.contains($0) ? lines[$0].text : nil } ?? " "
        Text(text)
            .font(.system(size: height * size, weight: .bold))
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .id(text + "\(index ?? -1)")
            .transition(.opacity)
    }
}
