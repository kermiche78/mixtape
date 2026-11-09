import SwiftUI

@main
struct MixtapeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerModel()

    init() {
        // Cache disque pour les pochettes (50 Mo en mémoire, 300 Mo sur le disque).
        URLCache.shared = URLCache(memoryCapacity: 50_000_000, diskCapacity: 300_000_000)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .onAppear {
                    player.library = library
                    AppObjects.shared.library = library
                    AppObjects.shared.player = player
                    SmartPlaylistStore.shared.attach(library)
                    player.restoreSession()
                }
        }
    }
}
