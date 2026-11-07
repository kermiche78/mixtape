import Combine
import SwiftUI
import UIKit

// MARK: - Mode veille

/// Surveille l'iPhone : à l'horizontale ET en charge → mode veille.
@MainActor
final class StandbyMonitor: ObservableObject {
    @Published private(set) var isActive = false
    /// Sens de rotation de l'écran (l'app reste en portrait, on tourne le contenu nous-mêmes).
    @Published private(set) var angle: Angle = .degrees(90)
    /// Fermé à la main : on attend que l'iPhone repasse à la verticale avant de le remontrer.
    private var dismissed = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        update()
    }

    func dismiss() {
        dismissed = true
        setActive(false)
    }

    func update() {
        let enabled = UserDefaults.standard.object(forKey: "standbyEnabled") as? Bool ?? true
        let device = UIDevice.current
        let orientation = device.orientation
        let charging = device.batteryState == .charging || device.batteryState == .full

        if orientation == .portrait || orientation == .portraitUpsideDown { dismissed = false }
        guard enabled, charging, !dismissed else { setActive(false); return }

        switch orientation {
        case .landscapeLeft:
            angle = .degrees(90)
            setActive(true)
        case .landscapeRight:
            angle = .degrees(-90)
            setActive(true)
        case .portrait, .portraitUpsideDown:
            setActive(false)
        default:
            break // à plat ou inconnu : on garde l'état actuel
        }
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        withAnimation(.easeInOut(duration: 0.35)) { isActive = active }
        // L'écran reste allumé tant que le mode veille est affiché.
        UIApplication.shared.isIdleTimerDisabled = active
    }
}

/// Grand écran façon borne musicale : pochette, heure, son en cours et commandes.
struct StandbyView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    let angle: Angle
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            // L'app est en portrait : on dessine en paysage puis on fait pivoter.
            let w = geo.size.height
            let h = geo.size.width
            content(width: w, height: h)
                .frame(width: w, height: h)
                .rotationEffect(angle)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    private func content(width w: CGFloat, height h: CGFloat) -> some View {
        let track = player.current
        let side = h * 0.66
        return ZStack {
            BlurredBackdrop(url: library.coverURL(track))
                .frame(width: w, height: h)
                .clipped()

            HStack(spacing: 36) {
                ArtworkView(url: library.coverURL(track), cornerRadius: 18, placeholderSeed: track?.albumKey ?? "standby")
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)

                VStack(alignment: .leading, spacing: 6) {
                    TimelineView(.everyMinute) { context in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.date, format: .dateTime.hour().minute())
                                .font(.system(size: h * 0.24, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                            Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }

                    if let track {
                        Text(track.title)
                            .font(.title2.bold())
                            .lineLimit(1)
                            .padding(.top, 10)
                        Text(track.displayArtist)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        MiniProgressLine()
                            .frame(maxWidth: 320)
                            .padding(.top, 8)
                        HStack(spacing: 40) {
                            controlButton("backward.fill", size: 30) { player.previous() }
                            controlButton(player.isPlaying ? "pause.fill" : "play.fill", size: 44) { player.togglePlayPause() }
                            controlButton("forward.fill", size: 30) { player.next() }
                        }
                        .padding(.top, 10)
                    } else {
                        Text("Pas de lecture")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 44)
            .foregroundStyle(.white)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .liquidGlass(in: Circle(), interactive: true)
            }
            .foregroundStyle(.white)
            .accessibilityLabel("Fermer le mode veille")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(20)
        }
    }

    private func controlButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 24, height: size + 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bandeau « Hors ligne »

struct OfflineBanner: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        if library.isOffline {
            HStack(spacing: 12) {
                Image(systemName: "wifi.slash")
                    .font(.title3)
                    .foregroundStyle(Color.accentPink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hors ligne").font(.subheadline.weight(.semibold))
                    Text("Le PC ne répond pas : seuls tes sons téléchargés sont affichés.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    Task { await library.refresh() }
                } label: {
                    if library.isLoading {
                        ProgressView()
                    } else {
                        Text("Réessayer").font(.subheadline.weight(.semibold))
                    }
                }
                .tint(Color.accentPink)
            }
            .padding(12)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

// MARK: - Filtres de la bibliothèque

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "Tout"
    case unplayed = "Jamais écoutés"
    case favorites = "Favoris"
    case downloaded = "Téléchargés"
    case albums = "Albums"
    case eps = "EP"
    case singles = "Singles"

    var id: String { rawValue }
    static let songOptions: [LibraryFilter] = [.all, .unplayed, .favorites, .downloaded]
    static let albumOptions: [LibraryFilter] = allCases
}

/// Rangée de pastilles qui défile horizontalement.
struct FilterChips: View {
    @Binding var selection: LibraryFilter
    let options: [LibraryFilter]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    let on = option == selection
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selection = option }
                    } label: {
                        Text(option.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(on ? Color.accentPink : Color(.secondarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 8)
    }
}

extension Album {
    /// Année de sortie lue dans le nom du dossier, par exemple « Gloyalty (2014) ».
    var releaseYear: Int? {
        guard let range = name.range(of: #"(19|20)\d{2}"#, options: .regularExpression) else { return nil }
        return Int(name[range])
    }

    /// Année pour trier : celle du nom, sinon l'année d'ajout sur le serveur.
    var sortYear: Int { releaseYear ?? Int(addedYear) ?? 0 }

    @MainActor
    func matches(_ filter: LibraryFilter, stats: Stats, downloads: DownloadManager) -> Bool {
        switch filter {
        case .all: return true
        case .unplayed: return tracks.allSatisfy { stats.plays($0) == 0 }
        case .favorites: return tracks.contains { stats.isFavorite($0) }
        case .downloaded: return tracks.contains { downloads.isDownloaded($0) }
        case .albums: return kindLabel == "Album"
        case .eps: return kindLabel == "EP"
        case .singles: return kindLabel == "Single"
        }
    }
}

extension Track {
    @MainActor
    func matches(_ filter: LibraryFilter, stats: Stats, downloads: DownloadManager) -> Bool {
        switch filter {
        case .unplayed: return stats.plays(self) == 0
        case .favorites: return stats.isFavorite(self)
        case .downloaded: return downloads.isDownloaded(self)
        default: return true
        }
    }
}
