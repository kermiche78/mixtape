import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum RepeatMode {
    case off, all, one

    var icon: String { self == .one ? "repeat.1" : "repeat" }
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Position de lecture, mise à jour 2 fois par seconde. Séparée de PlayerModel pour que
/// seules les barres de progression se redessinent, pas toute l'app.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var bufferedTime: Double = 0
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    let clock = PlaybackClock()
    private(set) var currentTime: Double = 0 {
        didSet { if clock.currentTime != currentTime { clock.currentTime = currentTime } }
    }
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering = false
    /// Jusqu'où le son est déjà chargé (en secondes), comme la barre grise de YouTube.
    private(set) var bufferedTime: Double = 0 {
        didSet { if clock.bufferedTime != bufferedTime { clock.bufferedTime = bufferedTime } }
    }
    @Published private(set) var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var showNowPlaying = false
    /// Demande d'ouvrir une page depuis le lecteur (artiste ou album du son en cours).
    @Published var navRequest: NavRequest?
    /// Où tu t'es arrêté dans chaque album (pour « Reprendre »), gardé entre les lancements.
    private(set) var albumProgress: [String: AlbumProgress] = {
        guard let data = UserDefaults.standard.data(forKey: "albumProgress"),
              let saved = try? JSONDecoder().decode([String: AlbumProgress].self, from: data) else { return [:] }
        return saved
    }()
    private var lastSavedSecond = -1
    private var pendingResume: Double = 0
    private var resumeObserver: AnyCancellable?
    /// Derniers sons écoutés (du plus récent au plus ancien), gardés entre les lancements.
    /// Minuterie de mise en veille.
    @Published private(set) var sleepTimerEnd: Date?
    @Published private(set) var stopAtEndOfTrack = false
    private var sleepTask: Task<Void, Never>?
    @Published private(set) var recentlyPlayed: [String] = UserDefaults.standard.stringArray(forKey: "recentlyPlayed") ?? []

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [Track] { queue.indices.contains(index + 1) ? Array(queue[(index + 1)...]) : [] }

    weak var library: LibraryStore?

    /// File de lecture d'iOS : le son suivant y est préparé à l'avance pour enchaîner sans blanc.
    private let player = AVQueuePlayer()
    /// Son suivant déjà chargé (lecture sans coupure).
    private var preloadedItem: AVPlayerItem?
    private var preloadedIndex: Int?
    private var originalQueue: [Track] = []
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var artworkCache: [String: UIImage] = [:]
    private var isSeeking = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        configureRemoteCommands()

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isSeeking else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                // Ne republier la durée que si elle change vraiment (sinon toute l'app se redessine).
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - self.duration) > 0.5 { self.duration = d }
                self.bufferedTime = self.loadedEnd()
                // Mémorise la position toutes les 5 secondes.
                let s = Int(self.currentTime)
                if s % 5 == 0, s != self.lastSavedSecond { self.lastSavedSecond = s; self.saveAlbumProgress() }
            }
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                let playing = status == .playing || status == .waitingToPlayAtSpecifiedRate
                let buffering = status == .waitingToPlayAtSpecifiedRate
                if self.isPlaying != playing { self.isPlaying = playing }
                if self.isBuffering != buffering { self.isBuffering = buffering }
                if status == .paused { self.saveAlbumProgress() }
                self.updateNowPlayingInfo()
            }
            .store(in: &cancellables)

        // iOS est passé tout seul au son préparé : on met l'app à jour sans recharger.
        player.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                guard let self, let item, item === self.preloadedItem else { return }
                self.didAdvanceToPreloaded()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.trackDidEnd()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                      let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) else { return }
                self.player.play()
            }
            .store(in: &cancellables)
    }

    // MARK: Lecture

    /// Reprend un album là où tu t'étais arrêté.
    func resume(_ album: Album) {
        guard let p = albumProgress[album.id],
              let i = album.tracks.firstIndex(where: { $0.id == p.trackId }) else { play(album.tracks); return }
        play(album.tracks, startAt: i, resumeAt: p.time)
    }

    func play(_ tracks: [Track], startAt startIndex: Int = 0, shuffled: Bool = false, resumeAt: Double = 0) {
        guard !tracks.isEmpty else { return }
        originalQueue = tracks
        if shuffled {
            var rest = tracks
            let pick = startIndex == 0 ? Int.random(in: 0..<rest.count) : min(startIndex, rest.count - 1)
            let first = rest.remove(at: pick)
            queue = [first] + rest.shuffled()
            shuffle = true
        } else {
            queue = tracks
            shuffle = false
        }
        index = shuffled ? 0 : min(max(startIndex, 0), tracks.count - 1)
        pendingResume = resumeAt > 1 ? resumeAt : 0
        loadCurrent(autoplay: true)
    }

    func playNext(_ track: Track) {
        if queue.isEmpty { play([track]); return }
        queue.insert(track, at: index + 1)
        originalQueue.append(track)
        refreshPreload()
    }

    /// Fin de la plage déjà téléchargée qui contient la position actuelle.
    private func loadedEnd() -> Double {
        guard let item = player.currentItem else { return 0 }
        let now = player.currentTime().seconds
        var best: Double = 0
        for value in item.loadedTimeRanges {
            let r = value.timeRangeValue
            let start = r.start.seconds, end = (r.start + r.duration).seconds
            guard start.isFinite, end.isFinite else { continue }
            if start <= now + 1 { best = max(best, end) }
        }
        return best
    }

    func addToQueue(_ track: Track) {
        if queue.isEmpty { play([track]); return }
        queue.append(track)
        originalQueue.append(track)
        refreshPreload()
    }

    func jump(to track: Track) {
        guard let i = queue.firstIndex(of: track) else { return }
        index = i
        loadCurrent(autoplay: true)
    }

    func pause() { player.pause() }

    func togglePlayPause() {
        guard current != nil else { return }
        if isPlaying { player.pause() } else {
            if player.currentItem == nil { loadCurrent(autoplay: true) } else { player.play() }
        }
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all {
            index = 0
        } else if autoplayEnabled, appendAutoplay() {
            index += 1
        } else {
            player.pause()
            seek(to: 0)
            return
        }
        loadCurrent(autoplay: true)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 || index == 0 {
            seek(to: 0)
            return
        }
        index -= 1
        loadCurrent(autoplay: true)
    }

    func seek(to seconds: Double) {
        isSeeking = true
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.updateNowPlayingInfo()
            }
        }
    }

    func toggleShuffle() {
        guard let current else { shuffle.toggle(); return }
        if shuffle {
            queue = originalQueue
            index = originalQueue.firstIndex(of: current) ?? 0
            shuffle = false
        } else {
            var rest = queue
            rest.remove(at: index)
            queue = [current] + rest.shuffled()
            index = 0
            shuffle = true
        }
        refreshPreload()
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        refreshPreload()
    }

    // MARK: Lecture continue

    /// Réglable dans Réglages, activée par défaut.
    var autoplayEnabled: Bool { UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true }

    /// Quand la file est finie, ajoute des sons proches (même artiste, favoris, les plus écoutés).
    private func appendAutoplay() -> Bool {
        guard let library, let last = current else { return false }
        let suggestions = autoplaySuggestions(after: last, from: library.tracks)
        guard !suggestions.isEmpty else { return false }
        queue.append(contentsOf: suggestions)
        originalQueue.append(contentsOf: suggestions)
        return true
    }

    private func autoplaySuggestions(after track: Track, from all: [Track]) -> [Track] {
        var avoid = Set(queue.suffix(40).map { $0.id })
        for id in recentlyPlayed.prefix(30) { avoid.insert(id) }
        var source = all.filter { !avoid.contains($0.id) }
        if source.isEmpty { source = all.filter { $0.id != track.id } }
        guard !source.isEmpty else { return [] }

        let stats = Stats.shared
        let artist = track.displayArtist.lowercased()
        let sameArtist = source.filter { $0.displayArtist.lowercased() == artist }.shuffled()
        let liked = source.filter { stats.isFavorite($0) || stats.plays($0) > 1 }.shuffled()
        let others = source.shuffled()

        var picked: [Track] = []
        var seen = Set<String>()
        for (list, limit) in [(sameArtist, 4), (liked, 12), (others, 20)] {
            for t in list where picked.count < limit && !seen.contains(t.id) {
                seen.insert(t.id)
                picked.append(t)
            }
        }
        guard let first = picked.first else { return [] }
        // Un son du même artiste d'abord, puis le reste mélangé.
        return [first] + picked.dropFirst().shuffled()
    }

    // MARK: File d'attente modifiable

    func removeFromUpNext(at offsets: IndexSet) {
        for i in offsets.map({ index + 1 + $0 }).sorted(by: >) where queue.indices.contains(i) {
            let t = queue.remove(at: i)
            if let j = originalQueue.firstIndex(of: t) { originalQueue.remove(at: j) }
        }
        refreshPreload()
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        guard queue.indices.contains(index) else { return }
        var up = upNext
        up.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + up
        refreshPreload()
    }

    func clearUpNext() {
        guard queue.indices.contains(index) else { return }
        queue = Array(queue[...index])
        originalQueue = queue
        refreshPreload()
    }

    // MARK: Minuterie

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        stopAtEndOfTrack = false
        guard let minutes else { sleepTimerEnd = nil; return }
        sleepTimerEnd = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            self?.player.pause()
            self?.sleepTimerEnd = nil
        }
    }

    func sleepAtEndOfTrack() {
        sleepTask?.cancel()
        sleepTimerEnd = nil
        stopAtEndOfTrack = true
        refreshPreload()
    }

    private func trackDidEnd() {
        // Un son suivant est déjà prêt : iOS enchaîne tout seul (voir didAdvanceToPreloaded).
        if preloadedItem != nil, player.actionAtItemEnd == .advance { return }
        clearAlbumProgressIfFinished(current)
        if stopAtEndOfTrack {
            stopAtEndOfTrack = false
            player.pause()
            seek(to: 0)
            return
        }
        if repeatMode == .one {
            seek(to: 0)
            player.play()
        } else {
            next()
        }
    }

    /// Son téléchargé : lu depuis l'iPhone, sans réseau. Sinon : depuis le PC.
    private func sourceURL(for track: Track) -> URL? {
        if let local = DownloadManager.shared.localURL(for: track) { return local }
        return library?.api?.streamURL(for: track)
    }

    private func clearAlbumProgressIfFinished(_ track: Track?) {
        // Dernier son de l'album terminé : plus rien à reprendre.
        if let track, let album = library?.album(for: track), album.tracks.last?.id == track.id {
            albumProgress[album.id] = nil
            persistAlbumProgress()
        }
    }

    // MARK: Lecture sans coupure

    /// Index du son qui doit suivre naturellement (nil = on s'arrête après celui-ci).
    private func naturalNextIndex() -> Int? {
        guard !queue.isEmpty, repeatMode != .one, !stopAtEndOfTrack else { return nil }
        if index + 1 < queue.count { return index + 1 }
        if repeatMode == .all { return 0 }
        if autoplayEnabled, appendAutoplay() { return index + 1 }
        return nil
    }

    /// Prépare le son suivant dans la file d'iOS pendant que le son actuel joue.
    private func prepareNext() {
        guard player.currentItem != nil,
              let next = naturalNextIndex(),
              queue.indices.contains(next),
              let url = sourceURL(for: queue[next]) else {
            player.actionAtItemEnd = .pause
            return
        }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 30
        player.insert(item, after: player.currentItem)
        preloadedItem = item
        preloadedIndex = next
        player.actionAtItemEnd = .advance
    }

    /// La file a changé : on remplace le son préparé.
    private func refreshPreload() {
        if let item = preloadedItem, item !== player.currentItem { player.remove(item) }
        preloadedItem = nil
        preloadedIndex = nil
        prepareNext()
    }

    /// iOS a enchaîné sur le son préparé, sans blanc.
    private func didAdvanceToPreloaded() {
        guard let next = preloadedIndex, queue.indices.contains(next) else { return }
        clearAlbumProgressIfFinished(current)
        preloadedItem = nil
        preloadedIndex = nil
        index = next
        let track = queue[next]
        rememberPlayed(track)
        resumeObserver = nil
        bufferedTime = 0
        currentTime = 0
        duration = track.duration
        lastSavedSecond = -1
        updateNowPlayingInfo()
        loadArtwork(for: track)
        prepareNext()
    }

    private func loadCurrent(autoplay: Bool, countPlay: Bool = true) {
        guard let track = current, let url = sourceURL(for: track) else { return }
        let item = AVPlayerItem(url: url)
        if countPlay { rememberPlayed(track) }
        preloadedItem = nil
        preloadedIndex = nil
        player.removeAllItems()
        player.insert(item, after: nil)
        prepareNext()
        // Reprise : on se place au bon endroit dès que le son est prêt.
        resumeObserver = nil
        if pendingResume > 0 {
            let target = pendingResume
            pendingResume = 0
            resumeObserver = item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .first { $0 == .readyToPlay }
                .sink { [weak self] _ in self?.seek(to: target) }
        }
        bufferedTime = 0
        currentTime = 0
        duration = track.duration
        if autoplay {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        }
        updateNowPlayingInfo()
        loadArtwork(for: track)
    }

    // MARK: Reprendre où j'en étais

    private struct Session: Codable {
        var trackIds: [String]
        var currentId: String
        var time: Double
    }

    /// Garde la file, le son et la position, pour tout retrouver au prochain lancement.
    private func saveSession() {
        // Rien à reprendre au tout début d'un son (et évite d'écraser la position pendant la reprise).
        guard let track = current, currentTime >= 1 else { return }
        let start = max(0, index - 50)
        let end = min(queue.count, start + 200)
        let session = Session(trackIds: queue[start..<end].map(\.id), currentId: track.id, time: currentTime)
        if let data = try? JSONEncoder().encode(session) { UserDefaults.standard.set(data, forKey: "lastSession") }
    }

    /// Au lancement : le dernier son revient dans le mini-lecteur, en pause, au bon moment.
    func restoreSession() {
        guard queue.isEmpty, let library,
              let data = UserDefaults.standard.data(forKey: "lastSession"),
              let session = try? JSONDecoder().decode(Session.self, from: data) else { return }
        let tracks = session.trackIds.compactMap { library.track($0) }
        guard let i = tracks.firstIndex(where: { $0.id == session.currentId }) else { return }
        queue = tracks
        originalQueue = tracks
        shuffle = false
        index = i
        pendingResume = session.time > 1 ? session.time : 0
        loadCurrent(autoplay: false, countPlay: false)
        // Affiche tout de suite la bonne position dans le mini-lecteur.
        if session.time > 1 { currentTime = session.time }
    }

    private func saveAlbumProgress() {
        saveSession()
        guard let track = current, !track.albumKey.hasPrefix("single:") else { return }
        albumProgress[track.albumKey] = AlbumProgress(trackId: track.id, time: currentTime, updatedAt: Date().timeIntervalSince1970)
        persistAlbumProgress()
    }

    private func persistAlbumProgress() {
        if let data = try? JSONEncoder().encode(albumProgress) { UserDefaults.standard.set(data, forKey: "albumProgress") }
    }

    private func rememberPlayed(_ track: Track) {
        Stats.shared.countPlay(track)
        recentlyPlayed.removeAll { $0 == track.id }
        recentlyPlayed.insert(track.id, at: 0)
        if recentlyPlayed.count > 50 { recentlyPlayed.removeLast(recentlyPlayed.count - 50) }
        UserDefaults.standard.set(recentlyPlayed, forKey: "recentlyPlayed")
    }

    // MARK: Système (écran verrouillé, centre de contrôle, écouteurs)

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.displayAlbum,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let image = artworkCache[track.id] {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(image)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Hors du MainActor : iOS appelle ce bloc depuis un autre fil d'exécution.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func loadArtwork(for track: Track) {
        guard artworkCache[track.id] == nil, let url = library?.coverURL(track) else { return }
        Task {
            if let image = await ImageLoader.shared.image(for: url) {
                artworkCache[track.id] = image
                if current?.id == track.id { updateNowPlayingInfo() }
            }
        }
    }
}

/// Page à ouvrir depuis le lecteur plein écran.
enum NavRequest: Equatable {
    case artist(String)
    case album(String)
}

/// Position mémorisée dans un album.
struct AlbumProgress: Codable, Equatable {
    var trackId: String
    var time: Double
    var updatedAt: Double
}
