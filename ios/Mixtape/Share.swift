import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Partage du fichier audio d'un son (iMessage, WhatsApp, AirDrop…).
@MainActor
final class ShareManager: ObservableObject {
    static let shared = ShareManager()

    /// Titre du son ou de l'album en cours de préparation (pour afficher « Préparation… »).
    @Published private(set) var preparing: String?
    /// Avancement pour un album : « 3/12 ».
    @Published private(set) var progress: String?

    private init() {}

    func share(_ track: Track, api: APIClient?) {
        guard preparing == nil else { return }
        preparing = track.title
        Task {
            let file = await prepareFile(for: track, api: api)
            preparing = nil
            if let file {
                presentAsDocument(file)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    /// Envoie le son comme un vrai fichier MP3 (pièce jointe « document »)
    /// et non comme un message audio : on le présente aux autres apps comme
    /// un fichier générique, en gardant son nom « Artiste - Titre.mp3 ».
    private func presentAsDocument(_ file: URL) {
        let provider = NSItemProvider()
        provider.suggestedName = file.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier,
                                            fileOptions: [],
                                            visibility: .all) { completion in
            completion(file, false, nil)
            return nil
        }
        presentItems([provider])
    }

    /// Envoie un lien d'écoute (valable 24 h) : ton pote écoute le son dans Safari, sans rien installer.
    func shareListenLink(_ track: Track, api: APIClient?) {
        guard preparing == nil, let api else { return }
        preparing = track.title
        Task {
            let url = try? await api.listenLink(trackId: track.id)
            preparing = nil
            if let url {
                presentItems(["\(track.title) · \(track.artist) — écoute-le ici (lien valable 24 h) :", url])
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    /// Partage un album entier : tous ses sons + la pochette, dans un seul fichier .zip.
    func shareAlbum(_ album: Album, api: APIClient?, coverURL: URL?) {
        guard preparing == nil, !album.tracks.isEmpty else { return }
        preparing = album.isSingle ? (album.tracks.first?.title ?? album.name) : album.name
        progress = "0/\(album.tracks.count)"
        Task {
            let zip = await prepareAlbum(album, api: api, coverURL: coverURL)
            preparing = nil
            progress = nil
            if let zip {
                present(zip)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func prepareAlbum(_ album: Album, api: APIClient?, coverURL: URL?) async -> URL? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Partage", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let name = Self.cleanName("\(album.artist) - \(album.isSingle ? (album.tracks.first?.title ?? album.name) : album.name)")
        let folder = root.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (i, track) in album.tracks.enumerated() {
                let number = String(format: "%02d", track.trackNumber ?? (i + 1))
                let target = folder.appendingPathComponent("\(number) - \(Self.cleanName(track.title)).\(track.ext)")
                if let local = DownloadManager.shared.localURL(for: track) {
                    try FileManager.default.copyItem(at: local, to: target)
                } else if let api {
                    let (tmp, response) = try await URLSession.shared.download(from: api.streamURL(for: track))
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    try FileManager.default.moveItem(at: tmp, to: target)
                } else {
                    return nil
                }
                progress = "\(i + 1)/\(album.tracks.count)"
            }
            // La pochette, si le serveur en a une.
            if let coverURL, let image = await ImageLoader.shared.image(for: coverURL), let data = image.jpegData(compressionQuality: 0.9) {
                try? data.write(to: folder.appendingPathComponent("Pochette.jpg"))
            }
            return Self.zip(folder, into: root, name: name)
        } catch {
            return nil
        }
    }

    /// iOS sait compresser un dossier en .zip tout seul (comme « Compresser » dans Fichiers).
    private static func zip(_ folder: URL, into destination: URL, name: String) -> URL? {
        var result: URL?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipped in
            let target = destination.appendingPathComponent("\(name).zip")
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.copyItem(at: zipped, to: target)) != nil { result = target }
        }
        return result
    }

    /// Copie le son avec un joli nom (« Artiste - Titre.mp3 ») dans un dossier temporaire.
    private func prepareFile(for track: Track, api: APIClient?) async -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Partage", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Self.cleanName("\(track.displayArtist) - \(track.title)")
        let target = folder.appendingPathComponent("\(name).\(track.ext)")

        do {
            if let local = DownloadManager.shared.localURL(for: track) {
                try FileManager.default.copyItem(at: local, to: target)
            } else if let api {
                let (tmp, response) = try await URLSession.shared.download(from: api.streamURL(for: track))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                try FileManager.default.moveItem(at: tmp, to: target)
            } else {
                return nil
            }
            return target
        } catch {
            return nil
        }
    }

    private func present(_ file: URL) { presentItems([file]) }

    private func presentItems(_ items: [Any]) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let root = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        top.present(sheet, animated: true)
    }

    private static func cleanName(_ text: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = text.components(separatedBy: forbidden).joined(separator: " ")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Petite bulle « Préparation du partage… » en haut de l'écran.
struct SharePreparingBanner: View {
    @ObservedObject private var share = ShareManager.shared

    var body: some View {
        ZStack {
            banner
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: share.preparing)
    }

    @ViewBuilder
    private var banner: some View {
        if let title = share.preparing {
            HStack(spacing: 10) {
                ProgressView()
                Text("Préparation de « \(title) »…" + (share.progress.map { " \($0)" } ?? ""))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .liquidGlass(in: Capsule())
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
