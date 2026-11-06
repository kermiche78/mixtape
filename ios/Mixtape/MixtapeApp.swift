import SwiftUI

@main
struct MixtapeApp: App {
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
                    SmartPlaylistStore.shared.attach(library)
                }
        }
    }
}
