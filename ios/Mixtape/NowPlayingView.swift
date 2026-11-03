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
        GeometryReader { geo in
            // Taille de la pochette calculée sur la largeur de l'écran : rien ne peut déborder.
            let side = max(min(geo.size.width - 56, geo.size.height * 0.42), 120)
            VStack(spacing: 0) {
                Capsule()
                    .fill(.white.opacity(0.45))
                    .frame(width: 38, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 14)

                if showQueue {
                    QueuePanel()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Spacer(minLength: 0)
                    ArtworkView(url: library.coverURL(track), cornerRadius: 14, placeholderSeed: track?.albumKey ?? "")
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
                        .scaleEffect(player.isPlaying ? 1 : 0.84)
                        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
                        .frame(maxWidth: .infinity)
                        .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                            if g.translation.width < -60 { player.next() } else if g.translation.width > 60 { player.previous() }
                        })
                        .transition(.opacity)
                    Spacer(minLength: 0)
                }

                // Titre + artiste
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track?.title ?? "Pas de lecture")
                            .font(.title3.bold())
                            .lineLimit(1)
                        if let track {
                            // Touche l'artiste ou l'album pour ouvrir sa page.
                            HStack(spacing: 5) {
                                Button { player.navRequest = .artist(library.album(for: track)?.artist ?? track.artist) } label: {
                                    Text(track.displayArtist).lineLimit(1)
                                }
                                .layoutPriority(1)
                                Text("—")
                                Button { player.navRequest = .album(track.albumKey) } label: {
                                    Text(track.displayAlbum).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.65))
                        } else {
                            Text(" ").font(.body)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let track {
                        FavoriteButton(track: track, size: 20)
                            .frame(width: 36, height: 36)
                            .liquidGlass(in: Circle(), interactive: true)
                        TrackMenu(track: track)
                            .tint(.white)
                            .frame(width: 36, height: 36)
                            .liquidGlass(in: Circle(), interactive: true)
                    }
                }
                .padding(.top, 24)

                Scrubber(value: player.currentTime, total: max(player.duration, 0.1), buffered: player.bufferedTime) { player.seek(to: $0) }
                    .padding(.top, 18)

                // Commandes
                HStack {
                    controlButton("backward.fill", size: 32) { player.previous() }
                        .frame(maxWidth: .infinity)
                    Button { player.togglePlayPause() } label: {
                        Group {
                            if player.isBuffering {
                                ProgressView().controlSize(.large).tint(.white)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 50))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .frame(width: 80, height: 80)
                    }
                    .buttonStyle(PressableStyle())
                    .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
                    .frame(maxWidth: .infinity)
                    controlButton("forward.fill", size: 32) { player.next() }
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 12)

                VolumeSlider()
                    .frame(height: 34)

                // Rangée du bas : aléatoire, AirPlay, minuterie, file d'attente, répétition
                GlassGroup(spacing: 16) {
                    HStack {
                        toggleButton("shuffle", on: player.shuffle) { player.toggleShuffle() }
                        Spacer(minLength: 0)
                        AirPlayButton()
                            .frame(width: 28, height: 28)
                            .frame(width: 44, height: 44)
                            .liquidGlass(in: Circle())
                        Spacer(minLength: 0)
                        SleepTimerButton()
                        Spacer(minLength: 0)
                        toggleButton("list.bullet", on: showQueue) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showQueue.toggle() }
                        }
                        Spacer(minLength: 0)
                        toggleButton(player.repeatMode.icon, on: player.repeatMode != .off) { player.cycleRepeat() }
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
            .padding(.horizontal, 28)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .foregroundStyle(.white)
        .background { BlurredBackdrop(url: library.coverURL(track)) }
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
        .sensoryFeedback(.impact(weight: .light), trigger: player.current?.id)
    }

    private func toggleButton(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(on ? Color.accentPink : .white.opacity(0.75))
                .frame(width: 44, height: 44)
                .liquidGlass(in: Circle(), interactive: true, tint: on ? .white.opacity(0.35) : nil)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
    }
}

/// Bouton « lune » : arrêter la musique au bout d'un moment.
struct SleepTimerButton: View {
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        let active = player.sleepTimerEnd != nil || player.stopAtEndOfTrack
        Menu {
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
            Image(systemName: active ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? Color.accentPink : .white.opacity(0.75))
                .frame(width: 44, height: 44)
                .liquidGlass(in: Circle(), interactive: true, tint: active ? .white.opacity(0.35) : nil)
        }
        .accessibilityLabel("Minuterie de mise en veille")
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
    var buffered: Double = 0
    let onSeek: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        let shown = dragValue ?? value
        let progress = min(max(shown / total, 0), 1)
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    // Partie déjà chargée (gris clair), qui avance pendant le chargement.
                    Capsule().fill(.white.opacity(0.38))
                        .frame(width: geo.size.width * min(max(buffered / total, 0), 1))
                        .animation(.linear(duration: 0.5), value: buffered)
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

/// « À suivre » dans le lecteur plein écran : réordonner en glissant, supprimer en balayant.
private struct QueuePanel: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current = player.current {
                HStack(spacing: 12) {
                    ArtworkView(url: library.coverURL(current), cornerRadius: 6, placeholderSeed: current.albumKey)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title).font(.headline).lineLimit(1)
                        Text(current.displayArtist).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack {
                Text("À suivre").font(.headline)
                Spacer()
                if !player.upNext.isEmpty {
                    Button("Effacer") { withAnimation { player.clearUpNext() } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.top, 6)

            if player.upNext.isEmpty {
                Text("Rien à suivre")
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { _, track in
                        Button { player.jump(to: track) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(url: library.coverURL(track), cornerRadius: 5, placeholderSeed: track.albumKey)
                                    .frame(width: 42, height: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title).lineLimit(1)
                                    Text(track.displayArtist).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.12))
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                    .onDelete { player.removeFromUpNext(at: $0) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
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

    // Ne réclame jamais plus de largeur que celle proposée par l'écran.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: 34)
    }
}

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.75)
        view.activeTintColor = UIColor(Color.accentPink)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
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
        GeometryReader { geo in
            // Taille de la pochette calculée sur la largeur de l'écran : rien ne peut déborder.
            let side = max(min(geo.size.width - 56, geo.size.height * 0.42), 120)
            VStack(spacing: 0) {
                Capsule()
                    .fill(.white.opacity(0.45))
                    .frame(width: 38, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 14)

                if showQueue {
                    QueuePanel()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Spacer(minLength: 0)
                    ArtworkView(url: library.coverURL(track), cornerRadius: 14, placeholderSeed: track?.albumKey ?? "")
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
                        .scaleEffect(player.isPlaying ? 1 : 0.84)
                        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
                        .frame(maxWidth: .infinity)
                        .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                            if g.translation.width < -60 { player.next() } else if g.translation.width > 60 { player.previous() }
                        })
                        .transition(.opacity)
                    Spacer(minLength: 0)
                }

                // Titre + artiste
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track?.title ?? "Pas de lecture")
                            .font(.title3.bold())
                            .lineLimit(1)
                        Text(track.map { "\($0.displayArtist) — \($0.displayAlbum)" } ?? " ")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let track {
                        FavoriteButton(track: track, size: 20)
                            .frame(width: 36, height: 36)
                            .liquidGlass(in: Circle(), interactive: true)
                        TrackMenu(track: track)
                            .tint(.white)
                            .frame(width: 36, height: 36)
                            .liquidGlass(in: Circle(), interactive: true)
                    }
                }
                .padding(.top, 24)

                Scrubber(value: player.currentTime, total: max(player.duration, 0.1), buffered: player.bufferedTime) { player.seek(to: $0) }
                    .padding(.top, 18)

                // Commandes
                HStack {
                    controlButton("backward.fill", size: 32) { player.previous() }
                        .frame(maxWidth: .infinity)
                    Button { player.togglePlayPause() } label: {
                        Group {
                            if player.isBuffering {
                                ProgressView().controlSize(.large).tint(.white)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 50))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .frame(width: 80, height: 80)
                    }
                    .buttonStyle(PressableStyle())
                    .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
                    .frame(maxWidth: .infinity)
                    controlButton("forward.fill", size: 32) { player.next() }
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 12)

                VolumeSlider()
                    .frame(height: 34)

                // Rangée du bas : aléatoire, AirPlay, minuterie, file d'attente, répétition
                GlassGroup(spacing: 16) {
                    HStack {
                        toggleButton("shuffle", on: player.shuffle) { player.toggleShuffle() }
                        Spacer(minLength: 0)
                        AirPlayButton()
                            .frame(width: 28, height: 28)
                            .frame(width: 44, height: 44)
                            .liquidGlass(in: Circle())
                        Spacer(minLength: 0)
                        SleepTimerButton()
                        Spacer(minLength: 0)
                        toggleButton("list.bullet", on: showQueue) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showQueue.toggle() }
                        }
                        Spacer(minLength: 0)
                        toggleButton(player.repeatMode.icon, on: player.repeatMode != .off) { player.cycleRepeat() }
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
            .padding(.horizontal, 28)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .foregroundStyle(.white)
        .background { BlurredBackdrop(url: library.coverURL(track)) }
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
        .sensoryFeedback(.impact(weight: .light), trigger: player.current?.id)
    }

    private func toggleButton(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(on ? Color.accentPink : .white.opacity(0.75))
                .frame(width: 44, height: 44)
                .liquidGlass(in: Circle(), interactive: true, tint: on ? .white.opacity(0.35) : nil)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
    }
}

/// Bouton « lune » : arrêter la musique au bout d'un moment.
struct SleepTimerButton: View {
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        let active = player.sleepTimerEnd != nil || player.stopAtEndOfTrack
        Menu {
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
            Image(systemName: active ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? Color.accentPink : .white.opacity(0.75))
                .frame(width: 44, height: 44)
                .liquidGlass(in: Circle(), interactive: true, tint: active ? .white.opacity(0.35) : nil)
        }
        .accessibilityLabel("Minuterie de mise en veille")
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
    var buffered: Double = 0
    let onSeek: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        let shown = dragValue ?? value
        let progress = min(max(shown / total, 0), 1)
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    // Partie déjà chargée (gris clair), qui avance pendant le chargement.
                    Capsule().fill(.white.opacity(0.38))
                        .frame(width: geo.size.width * min(max(buffered / total, 0), 1))
                        .animation(.linear(duration: 0.5), value: buffered)
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

/// « À suivre » dans le lecteur plein écran : réordonner en glissant, supprimer en balayant.
private struct QueuePanel: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current = player.current {
                HStack(spacing: 12) {
                    ArtworkView(url: library.coverURL(current), cornerRadius: 6, placeholderSeed: current.albumKey)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title).font(.headline).lineLimit(1)
                        Text(current.displayArtist).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack {
                Text("À suivre").font(.headline)
                Spacer()
                if !player.upNext.isEmpty {
                    Button("Effacer") { withAnimation { player.clearUpNext() } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.top, 6)

            if player.upNext.isEmpty {
                Text("Rien à suivre")
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { _, track in
                        Button { player.jump(to: track) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(url: library.coverURL(track), cornerRadius: 5, placeholderSeed: track.albumKey)
                                    .frame(width: 42, height: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title).lineLimit(1)
                                    Text(track.displayArtist).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.12))
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                    .onDelete { player.removeFromUpNext(at: $0) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
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

    // Ne réclame jamais plus de largeur que celle proposée par l'écran.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: 34)
    }
}

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.75)
        view.activeTintColor = UIColor(Color.accentPink)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
