import AVFoundation
import Combine
import SwiftUI

// MARK: - Modèle

/// Un reel : un extrait de 20 à 30 secondes d'un son.
struct Reel: Identifiable, Equatable {
    let id = UUID()
    let track: Track
    let start: Double
    let length: Double
}

/// Position dans l'extrait (4 fois par seconde). Seul le reel affiché l'écoute.
@MainActor
final class ReelClock: ObservableObject {
    @Published var time: Double = 0
}

/// Choisit les extraits et les joue. Deux lecteurs : celui du reel affiché, et celui du
/// suivant, déjà chargé au bon endroit pour démarrer tout de suite quand on glisse.
@MainActor
final class ReelsEngine: ObservableObject {
    @Published private(set) var reels: [Reel] = []
    @Published private(set) var isRunning = false
    @Published private(set) var muted = false
    let clock = ReelClock()

    private weak var library: LibraryStore?
    private var players = [AVPlayer(), AVPlayer()]
    private var loaded: [UUID?] = [nil, nil]
    private var active = 0
    private var currentID: UUID?
    private var observers: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var colors: [String: Color] = [:]
    /// Artistes dont tu as demandé « moins de sons comme ça ».
    private var penalties: [String: Int] = UserDefaults.standard.dictionary(forKey: "reelsPenalties") as? [String: Int] ?? [:]

    init() {
        for (i, p) in players.enumerated() {
            p.automaticallyWaitsToMinimizeStalling = false
            let obs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in self?.tick(player: i, time: time.seconds) }
            }
            observers.append(obs)
        }
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, let item = note.object as? AVPlayerItem,
                      item === self.players[self.active].currentItem else { return }
                self.restartCurrent()
            }
            .store(in: &cancellables)
    }

    func attach(_ library: LibraryStore, player: PlayerModel) {
        guard self.library !== library else { return }
        self.library = library
        // Si la vraie musique repart (mini-lecteur, écouteurs…), les reels se taisent.
        player.$isPlaying
            .filter { $0 }
            .sink { [weak self] _ in self?.pause() }
            .store(in: &cancellables)
        if reels.isEmpty { reels = makeBatch(count: 20) }
    }

    // MARK: Lecture

    func activate(_ id: UUID) {
        guard let i = reels.firstIndex(where: { $0.id == id }) else { return }
        let changed = currentID != id
        currentID = id
        if i >= reels.count - 5 { reels += makeBatch(count: 20) }
        if changed {
            if loaded[1 - active] == id {
                // Le reel suivant était déjà prêt : on bascule simplement de lecteur.
                players[active].pause()
                active = 1 - active
            } else if loaded[active] != id {
                players[1 - active].pause()
                load(reels[i], into: active)
            }
            clock.time = 0
            // Prépare le suivant dans l'autre lecteur.
            if i + 1 < reels.count { load(reels[i + 1], into: 1 - active) }
        }
        players[active].isMuted = muted
        if isRunning { players[active].play() }
    }

    func start() {
        isRunning = true
        if let id = currentID { activate(id) }
    }

    func pause() {
        isRunning = false
        players.forEach { $0.pause() }
    }

    func togglePlay() {
        if isRunning { pause() } else { start() }
    }

    func toggleMute() {
        muted.toggle()
        players.forEach { $0.isMuted = muted }
    }

    /// Fait baisser cet artiste dans le mélange.
    func lessLike(_ artist: String) {
        let key = artist.lowercased()
        penalties[key, default: 0] += 1
        UserDefaults.standard.set(penalties, forKey: "reelsPenalties")
    }

    func next(after id: UUID) -> Reel? {
        guard let i = reels.firstIndex(where: { $0.id == id }), i + 1 < reels.count else { return nil }
        return reels[i + 1]
    }

    private func load(_ reel: Reel, into index: Int) {
        guard let url = sourceURL(reel.track) else { return }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 12
        let p = players[index]
        p.pause()
        p.replaceCurrentItem(with: item)
        p.isMuted = muted
        p.seek(to: CMTime(seconds: reel.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        loaded[index] = reel.id
    }

    private func sourceURL(_ track: Track) -> URL? {
        if let local = DownloadManager.shared.localURL(for: track) { return local }
        return library?.api?.streamURL(for: track)
    }

    private var currentReel: Reel? {
        guard let id = loaded[active] else { return nil }
        return reels.first { $0.id == id }
    }

    private func tick(player index: Int, time: Double) {
        guard index == active, let reel = currentReel, time.isFinite else { return }
        let t = time - reel.start
        if t >= reel.length {
            restartCurrent()
        } else if t >= 0, abs(clock.time - t) > 0.05 {
            clock.time = t
        }
    }

    /// L'extrait tourne en boucle.
    private func restartCurrent() {
        guard let reel = currentReel else { return }
        clock.time = 0
        players[active].seek(to: CMTime(seconds: reel.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if isRunning { players[active].play() }
    }

    // MARK: Couleur de fond (calculée une fois par album)

    func color(for track: Track, library: LibraryStore) async -> Color {
        if let c = colors[track.albumKey] { return c }
        guard let url = library.coverURL(track),
              let image = await ImageLoader.shared.image(for: url),
              let c = ArtworkColor.background(of: image) else { return Color(white: 0.09) }
        colors[track.albumKey] = c
        return c
    }

    // MARK: Algorithme

    /// 40 % sons peu écoutés · 30 % artistes que tu likes · 20 % hasard · 10 % favoris.
    /// Jamais un son déjà vu dans les 50 derniers reels, jamais deux fois le même artiste à la suite.
    private func makeBatch(count: Int) -> [Reel] {
        guard let library, !library.tracks.isEmpty else { return [] }
        let all = library.tracks
        let stats = Stats.shared

        var artistScore: [String: Int] = [:]
        for t in all {
            let score = (stats.isFavorite(t) ? 3 : 0) + stats.plays(t)
            if score > 0 { artistScore[t.displayArtist.lowercased(), default: 0] += score }
        }
        let lovedArtists = Set(artistScore.sorted { $0.value > $1.value }.prefix(5).map { $0.key })

        let fresh = all.filter { stats.plays($0) <= 1 }
        let loved = all.filter { lovedArtists.contains($0.displayArtist.lowercased()) }
        let favorites = all.filter { stats.isFavorite($0) }

        var recent = Array(reels.suffix(50).map { $0.track.id })
        var lastArtist = reels.last?.track.displayArtist.lowercased()
        var batch: [Reel] = []

        for _ in 0..<count {
            let roll = Int.random(in: 0..<100)
            let pool: [Track]
            switch roll {
            case ..<40: pool = fresh.isEmpty ? all : fresh
            case ..<70: pool = loved.isEmpty ? all : loved
            case ..<90: pool = all
            default: pool = favorites.isEmpty ? all : favorites
            }
            var picked: Track?
            for attempt in 0..<25 {
                guard let t = (attempt < 20 ? pool : all).randomElement() else { break }
                let artist = t.displayArtist.lowercased()
                if recent.contains(t.id) && all.count > 50 { continue }
                if artist == lastArtist && all.count > 5 && attempt < 20 { continue }
                if let p = penalties[artist], p > 0, Double.random(in: 0..<1) < min(0.85, 0.35 * Double(p)) { continue }
                picked = t
                break
            }
            guard let track = picked ?? all.randomElement() else { continue }
            recent.append(track.id)
            if recent.count > 50 { recent.removeFirst(recent.count - 50) }
            lastArtist = track.displayArtist.lowercased()
            batch.append(Self.makeReel(track))
        }
        return batch
    }

    /// Un moment au hasard dans le son, pas toujours l'intro.
    private static func makeReel(_ track: Track) -> Reel {
        let d = track.duration
        guard d > 35 else { return Reel(track: track, start: 0, length: max(d, 1)) }
        let length = Double.random(in: 20...30)
        let latest = max(d * 0.15, d - length - 5)
        let start = Double.random(in: (d * 0.15)...max(d * 0.15, min(d * 0.7, latest)))
        return Reel(track: track, start: start, length: length)
    }
}

// MARK: - Onglet Reels

struct ReelsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @StateObject private var engine = ReelsEngine()
    @State private var currentID: UUID?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { outer in
            let topInset = outer.safeAreaInsets.top
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(engine.reels) { reel in
                        ReelPage(reel: reel,
                                 next: reel.id == currentID ? engine.next(after: reel.id) : nil,
                                 isActive: reel.id == currentID,
                                 topInset: topInset,
                                 engine: engine) { goToNext(after: reel.id) }
                            .frame(width: outer.size.width, height: outer.size.height + topInset)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Color.black)
        .toolbar(.hidden, for: .navigationBar)
        .libraryDestinations()
        .overlay {
            if engine.reels.isEmpty {
                ContentUnavailableView("Aucun son", systemImage: "film.stack",
                                       description: Text("Ajoute des sons sur le PC pour voir des reels."))
            }
        }
        .onAppear {
            engine.attach(library, player: player)
            if player.isPlaying { player.pause() }
            if currentID == nil { currentID = engine.reels.first?.id }
            if let id = currentID { engine.activate(id) }
            engine.start()
        }
        .onDisappear { engine.pause() }
        .onChange(of: currentID) { _, id in
            if let id { engine.activate(id) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { engine.pause() }
        }
    }

    private func goToNext(after id: UUID) {
        guard let next = engine.next(after: id) else { return }
        withAnimation(.easeInOut(duration: 0.35)) { currentID = next.id }
    }
}

// MARK: - Une page de reel

struct ReelPage: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var stats = Stats.shared
    let reel: Reel
    let next: Reel?
    let isActive: Bool
    let topInset: CGFloat
    @ObservedObject var engine: ReelsEngine
    let onNext: () -> Void

    @State private var background = Color(white: 0.09)
    @State private var showHeart = false

    private var track: Track { reel.track }
    private var artistName: String { library.album(for: track)?.artist ?? track.displayArtist }

    var body: some View {
        VStack(spacing: 0) {
            cover
            info
            nextCard
        }
        .foregroundStyle(.white)
        .background(background)
        .environment(\.colorScheme, .dark)
        .task(id: track.albumKey) {
            let c = await engine.color(for: track, library: library)
            withAnimation(.easeInOut(duration: 0.3)) { background = c }
        }
    }

    // Pochette en grand : elle prend toute la place qui reste, pour qu'il n'y ait jamais de vide.
    private var cover: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                ReelCoverImage(url: library.coverURL(track), seed: track.albumKey,
                               reel: reel, clock: isActive ? engine.clock : nil)
            }
            .clipped()
            .overlay(alignment: .top) {
                HStack {
                    Text("Reels").font(.title3.bold())
                    Spacer()
                    Button { engine.toggleMute() } label: {
                        Image(systemName: engine.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .liquidGlass(in: Circle(), interactive: true)
                    }
                    .accessibilityLabel(engine.muted ? "Remettre le son" : "Couper le son")
                }
                .shadow(color: .black.opacity(0.4), radius: 6)
                .padding(.horizontal, 16)
                .padding(.top, topInset + 4)
            }
            .overlay {
                ZStack {
                    if showHeart {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 110))
                            .foregroundStyle(Color.accentPink)
                            .shadow(color: .black.opacity(0.3), radius: 12)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                    if isActive && !engine.isRunning {
                        Image(systemName: "play.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(color: .black.opacity(0.35), radius: 10)
                            .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if isActive {
                    ReelProgressBar(clock: engine.clock, length: reel.length)
                } else {
                    Rectangle().fill(.white.opacity(0.25)).frame(height: 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { like() }
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { engine.togglePlay() } }
    }

    private var info: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Button { player.navRequest = .artist(artistName) } label: {
                    HStack(spacing: 8) {
                        ArtworkView(url: library.artistImageURL(name: artistName, fallback: track),
                                    cornerRadius: 13, placeholderSeed: artistName)
                            .frame(width: 26, height: 26)
                        Text(artistName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("Voir")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 0.8))
                    }
                }
                .buttonStyle(.plain)

                Text(track.title)
                    .font(.title3.bold())
                    .lineLimit(1)
                    .padding(.top, 8)
                Label(track.displayAlbum, systemImage: "opticaldisc")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .padding(.top, 2)
                Group {
                    if isActive {
                        ReelTimeLabel(clock: engine.clock, length: reel.length)
                    } else {
                        Text("Extrait 0:00 / \(formatTime(reel.length))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 4)

                Spacer(minLength: 8)

                Button(action: listenFull) {
                    Label("Écouter en entier", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 14) {
                let liked = stats.isFavorite(track)
                actionButton(liked ? "heart.fill" : "heart", "J'aime", tint: liked ? Color.accentPink : .white) { like(toggle: true) }
                actionButton("paperplane", "Partager") { ShareManager.shared.share(track, api: library.api) }
                actionButton("square.stack", "Album") { player.navRequest = .album(track.albumKey) }
                moreMenu
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func actionButton(_ icon: String, _ label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, value: tint == Color.accentPink)
                Text(label).font(.caption2.weight(.medium))
            }
            .frame(width: 52)
        }
        .buttonStyle(.plain)
    }

    private var moreMenu: some View {
        Menu {
            Button { player.navRequest = .artist(artistName) } label: { Label("Aller à l'artiste", systemImage: "music.mic") }
            Menu {
                Button {
                    Task { await library.createPlaylist(name: track.title, trackIds: [track.id]) }
                } label: { Label("Nouvelle playlist", systemImage: "plus") }
                ForEach(library.playlists) { p in
                    Button(p.name) { Task { await library.add(track, to: p) } }
                }
            } label: { Label("Ajouter à une playlist", systemImage: "text.badge.plus") }
            Button { player.playNext(track) } label: { Label("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") }
            if !DownloadManager.shared.isDownloaded(track) {
                Button { DownloadManager.shared.download([track], api: library.api) } label: { Label("Télécharger", systemImage: "arrow.down.circle") }
            }
            Divider()
            Button {
                engine.lessLike(artistName)
                onNext()
            } label: { Label("Moins de sons comme ça", systemImage: "eye.slash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 52, height: 34)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var nextCard: some View {
        if let next {
            Button(action: onNext) {
                HStack(spacing: 10) {
                    ArtworkView(url: library.coverURL(next.track), cornerRadius: 6, placeholderSeed: next.track.albumKey)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ensuite").font(.caption).foregroundStyle(.white.opacity(0.55))
                        Text("\(next.track.title) · \(next.track.displayArtist)")
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up").foregroundStyle(.white.opacity(0.6))
                }
                .padding(8)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        } else {
            Color.clear.frame(height: 70)
        }
    }

    private func like(toggle: Bool = false) {
        if toggle {
            stats.toggleFavorite(track)
        } else if !stats.isFavorite(track) {
            stats.toggleFavorite(track)
        }
        guard stats.isFavorite(track) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { showHeart = true }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeOut(duration: 0.25)) { showHeart = false }
        }
    }

    /// Lance le son complet dans le vrai lecteur (avec la suite de l'album).
    private func listenFull() {
        engine.pause()
        if let album = library.album(for: track), let i = album.tracks.firstIndex(of: track) {
            player.play(album.tracks, startAt: i)
        } else {
            player.play([track])
        }
        player.showNowPlaying = true
    }
}

// MARK: - Petits morceaux qui suivent l'extrait (seul le reel affiché les met à jour)

/// Pochette en plein cadre, avec un zoom lent qui suit l'extrait (et se fige sur pause).
struct ReelCoverImage: View {
    let url: URL?
    let seed: String
    let reel: Reel
    let clock: ReelClock?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let clock {
                ReelZoom(clock: clock, length: reel.length) { picture }
            } else {
                picture
            }
        }
        .task(id: url) {
            image = nil
            if let url { image = await ImageLoader.shared.image(for: url) }
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ArtworkView(url: nil, cornerRadius: 0, placeholderSeed: seed)
                .scaledToFill()
        }
    }
}

/// Zoom lent : avance puis recule sur la durée de l'extrait, donc la boucle ne saute pas.
struct ReelZoom<Content: View>: View {
    @ObservedObject var clock: ReelClock
    let length: Double
    @ViewBuilder var content: Content

    var body: some View {
        let f = sin(.pi * min(max(clock.time / max(length, 1), 0), 1))
        content
            .scaleEffect(1 + 0.14 * f)
            .offset(x: -14 * f, y: -8 * f)
            .animation(.linear(duration: 0.3), value: clock.time)
    }
}

struct ReelProgressBar: View {
    @ObservedObject var clock: ReelClock
    let length: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.25))
                Rectangle().fill(.white)
                    .frame(width: geo.size.width * min(max(clock.time / max(length, 1), 0), 1))
                    .animation(.linear(duration: 0.25), value: clock.time)
            }
        }
        .frame(height: 3)
    }
}

struct ReelTimeLabel: View {
    @ObservedObject var clock: ReelClock
    let length: Double

    var body: some View {
        Text("Extrait \(formatTime(clock.time)) / \(formatTime(length))")
            .monospacedDigit()
    }
}
