import AVKit
import MediaPlayer
import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false

    var body: some View {
        let track = player.current
        ZStack {
            BlurredBackdrop(url: library.coverURL(track))

            VStack(spacing: 0) {
                Capsule()
                    .fill(.white.opacity(0.45))
                    .frame(width: 38, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 18)

                if showQueue {
                    QueuePanel()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Spacer(minLength: 0)
                    ArtworkView(url: library.coverURL(track), cornerRadius: 12, placeholderSeed: track?.albumKey ?? "")
                        .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                        .scaleEffect(player.isPlaying ? 1 : 0.82)
                        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
                        .padding(.horizontal, 6)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                }

                // Titre + artiste
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track?.title ?? "Pas de lecture")
                            .font(.title3.bold())
                            .lineLimit(1)
                        Text(track?.displayArtist ?? " ")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    Spacer()
                    if let track {
                        TrackMenu(track: track)
                            .tint(.white)
                            .frame(width: 36, height: 36)
                            .liquidGlass(in: Circle(), interactive: true)
                    }
                }
                .padding(.top, 28)

                Scrubber(value: player.currentTime, total: max(player.duration, 0.1)) { player.seek(to: $0) }
                    .padding(.top, 22)

                // Commandes
                HStack {
                    Spacer()
                    controlButton("backward.fill", size: 34) { player.previous() }
                    Spacer()
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 52))
                            .frame(width: 80, height: 80)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Spacer()
                    controlButton("forward.fill", size: 34) { player.next() }
                    Spacer()
                }
                .padding(.vertical, 18)

                VolumeSlider()
                    .frame(height: 34)

                // Rangée du bas : aléatoire, file d'attente, répétition
                GlassGroup(spacing: 20) { HStack {
                    toggleButton("shuffle", on: player.shuffle) { player.toggleShuffle() }
                    Spacer()
                    AirPlayButton().frame(width: 30, height: 30)
                        .frame(width: 44, height: 44)
                        .liquidGlass(in: Circle())
                    Spacer()
                    toggleButton("list.bullet", on: showQueue) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showQueue.toggle() }
                    }
                    Spacer()
                    toggleButton(player.repeatMode.icon, on: player.repeatMode != .off) { player.cycleRepeat() }
                } }
                .padding(.top, 14)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 28)
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.hidden)
        .onChange(of: player.current == nil) { _, isEmpty in if isEmpty { dismiss() } }
    }

    private func controlButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func toggleButton(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(on ? Color.accentPink : .white.opacity(0.75))
                .frame(width: 44, height: 44)
                .liquidGlass(in: Circle(), interactive: true, tint: on ? .white.opacity(0.35) : nil)
        }
        .buttonStyle(.plain)
        .frame(width: 48, height: 48)
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Barre de progression qui grossit quand on la touche.
struct Scrubber: View {
    let value: Double
    let total: Double
    let onSeek: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        let shown = dragValue ?? value
        let progress = min(max(shown / total, 0), 1)
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(dragValue == nil ? 0.75 : 1))
                        .frame(width: geo.size.width * progress)
                }
                .frame(height: dragValue == nil ? 7 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragValue = min(max(g.location.x / max(geo.size.width, 1), 0), 1) * total
                        }
                        .onEnded { _ in
                            if let d = dragValue { onSeek(d) }
                            dragValue = nil
                        }
                )
                .animation(.easeOut(duration: 0.15), value: dragValue == nil)
            }
            .frame(height: 20)

            HStack {
                Text(formatTime(shown))
                Spacer()
                Text("-" + formatTime(max(total - shown, 0)))
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(dragValue == nil ? 0.55 : 0.9))
        }
    }
}

/// Liste « À suivre » dans le lecteur plein écran.
private struct QueuePanel: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let current = player.current {
                HStack(spacing: 12) {
                    ArtworkView(url: library.coverURL(current), cornerRadius: 6, placeholderSeed: current.albumKey)
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title).font(.headline).lineLimit(1)
                        Text(current.displayArtist).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                }
            }
            Text("À suivre").font(.headline).padding(.top, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { _, track in
                        Button { player.jump(to: track) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(url: library.coverURL(track), cornerRadius: 5, placeholderSeed: track.albumKey)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title).lineLimit(1)
                                    Text(track.displayArtist).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if player.upNext.isEmpty {
                        Text("Rien à suivre").foregroundStyle(.white.opacity(0.5)).padding(.top, 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Curseur de volume du système (le même que dans le centre de contrôle).
private struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let low = UIImageView(image: UIImage(systemName: "speaker.fill"))
        let high = UIImageView(image: UIImage(systemName: "speaker.wave.3.fill"))
        [low, high].forEach {
            $0.tintColor = UIColor.white.withAlphaComponent(0.6)
            $0.contentMode = .scaleAspectFit
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        let volume = MPVolumeView()
        volume.showsVolumeSlider = true
        volume.showsRouteButton = false
        volume.tintColor = .white
        volume.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(volume)
        NSLayoutConstraint.activate([
            low.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            low.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            low.widthAnchor.constraint(equalToConstant: 14),
            high.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            high.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            high.widthAnchor.constraint(equalToConstant: 22),
            volume.leadingAnchor.constraint(equalTo: low.trailingAnchor, constant: 12),
            volume.trailingAnchor.constraint(equalTo: high.leadingAnchor, constant: -12),
            volume.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            volume.heightAnchor.constraint(equalToConstant: 30),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.7)
        view.activeTintColor = UIColor(Color.accentPink)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
