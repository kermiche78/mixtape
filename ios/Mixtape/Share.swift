import SwiftUI
import UIKit

/// Partage du fichier audio d'un son (iMessage, WhatsApp, AirDrop…).
@MainActor
final class ShareManager: ObservableObject {
    static let shared = ShareManager()

    /// Titre du son en cours de préparation (pour afficher « Préparation… »).
    @Published private(set) var preparing: String?

    private init() {}

    func share(_ track: Track, api: APIClient?) {
        guard preparing == nil else { return }
        preparing = track.title
        Task {
            let file = await prepareFile(for: track, api: api)
            preparing = nil
            if let file {
                present(file)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
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

    private func present(_ file: URL) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let root = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
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
                Text("Préparation de « \(title) »…")
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
