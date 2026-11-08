import SwiftUI

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("accentColor") private var accent = AccentChoice.rose.rawValue

    var body: some View {
        Group {
            if library.isConfigured {
                MainTabs()
            } else {
                LoginView()
            }
        }
        .tint(Color.accentPink)
    }
}

struct MainTabs: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var paths: [NavigationPath] = Array(repeating: NavigationPath(), count: 5)
    @Namespace private var zoomNamespace
    @StateObject private var standby = StandbyMonitor()
    @AppStorage("accentColor") private var accent = AccentChoice.rose.rawValue
    @Environment(\.scenePhase) private var phase

    var body: some View {
        tabs
            // Nouvelle couleur choisie : tous les écrans se redessinent avec.
            .id(accent)
            .environment(\.zoomNamespace, zoomNamespace)
            .overlay(alignment: .top) { SharePreparingBanner() }
            // Mode veille : iPhone à l'horizontale et en charge.
            .overlay {
                if standby.isActive {
                    StandbyView(angle: standby.angle) { standby.dismiss() }
                        .transition(.opacity)
                }
            }
            .onChange(of: standby.isActive) { _, active in
                if active { player.showNowPlaying = false }
            }
            .fullScreenCover(isPresented: $player.showParty) { PartyView() }
            .onChange(of: player.showParty) { _, on in
                standby.suspended = on
                if on { player.showNowPlaying = false }
            }
            // Sauvegarde sur le PC dès que l'app passe en arrière-plan.
            .onChange(of: phase) { _, p in
                if p == .background {
                    let api = library.api
                    Task { await BackupManager.shared.upload(api: api) }
                } else if p == .active, AlarmManager.shared.enabled {
                    Task { await AlarmManager.shared.reschedule() }
                }
            }
            .sheet(isPresented: $player.showNowPlaying) {
                NowPlayingView()
            }
            .alert("Oups", isPresented: Binding(get: { library.errorMessage != nil },
                                                 set: { if !$0 { library.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.errorMessage ?? "")
            }
            .task {
                AlarmManager.shared.attach(library: library, player: player)
                await library.refresh()
                // App réinstallée (vide) : on récupère tout depuis le PC.
                await BackupManager.shared.restore(api: library.api, player: player, onlyIfEmpty: true)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await library.refresh() } }
            }
            .onChange(of: player.navRequest) { _, request in
                guard let request else { return }
                player.navRequest = nil
                open(request)
            }
    }

    /// Ferme le lecteur puis ouvre la page de l'artiste ou de l'album dans l'onglet en cours.
    private func open(_ request: NavRequest) {
        let artist: Artist?
        let album: Album?
        switch request {
        case .artist(let name):
            artist = library.artist(named: name); album = nil
        case .album(let id):
            artist = nil; album = library.album(id: id)
        }
        guard artist != nil || album != nil else { return }
        player.showNowPlaying = false
        // L'onglet Réglages n'a pas de pages musique : on passe sur Bibliothèque.
        if tab == 2 { tab = 1 }
        let target = tab
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if let artist { paths[target].append(artist) }
            if let album { paths[target].append(album) }
        }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26.0, *) {
            // iOS 26 : barre d'onglets en verre liquide, recherche à part,
            // mini-lecteur posé au-dessus des onglets, barre qui se réduit au défilement.
            TabView(selection: $tab) {
                Tab("Accueil", systemImage: "house.fill", value: 0) {
                    NavigationStack(path: $paths[0]) { HomeView() }
                }
                Tab("Reels", systemImage: "play.rectangle.on.rectangle.fill", value: 4) {
                    NavigationStack(path: $paths[4]) { ReelsView() }
                }
                Tab("Bibliothèque", systemImage: "square.stack.fill", value: 1) {
                    NavigationStack(path: $paths[1]) { LibraryView() }
                }
                Tab("Réglages", systemImage: "gearshape.fill", value: 2) {
                    NavigationStack(path: $paths[2]) { SettingsView() }
                }
                Tab(value: 3, role: .search) {
                    NavigationStack(path: $paths[3]) { SearchView() }
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory {
                GlassMiniPlayer()
            }
        } else {
            TabView(selection: $tab) {
                NavigationStack(path: $paths[0]) { HomeView() }
                    .miniPlayerInset()
                    .tabItem { Label("Accueil", systemImage: "house.fill") }
                    .tag(0)

                NavigationStack(path: $paths[4]) { ReelsView() }
                    .tabItem { Label("Reels", systemImage: "play.rectangle.on.rectangle.fill") }
                    .tag(4)

                NavigationStack(path: $paths[1]) { LibraryView() }
                    .miniPlayerInset()
                    .tabItem { Label("Bibliothèque", systemImage: "square.stack.fill") }
                    .tag(1)

                NavigationStack(path: $paths[3]) { SearchView() }
                    .miniPlayerInset()
                    .tabItem { Label("Recherche", systemImage: "magnifyingglass") }
                    .tag(3)

                NavigationStack(path: $paths[2]) { SettingsView() }
                    .miniPlayerInset()
                    .tabItem { Label("Réglages", systemImage: "gearshape.fill") }
                    .tag(2)
            }
        }
    }
}

extension View {
    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
    }
}

/// Mini-lecteur d'iOS 26, dans la capsule de verre au-dessus des onglets.
@available(iOS 26.0, *)
struct GlassMiniPlayer: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        let track = player.current
        HStack(spacing: 10) {
            ArtworkView(url: library.coverURL(track), cornerRadius: 6, placeholderSeed: track?.albumKey ?? "")
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(track?.title ?? "Pas de lecture")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if placement != .inline, let track {
                    Text(track.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button { player.togglePlayPause() } label: {
                Group {
                    if player.isBuffering {
                        ProgressView()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 36, height: 36)
            }
            .disabled(track == nil)
            if placement != .inline {
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 36, height: 36)
                }
                .disabled(track == nil)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .overlay(alignment: .bottom) {
            if track != nil, placement != .inline { MiniProgressLine().padding(.horizontal, 18) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if track != nil { player.showNowPlaying = true } }
    }
}

/// Le petit lecteur flottant (iOS 17 et 18).
struct MiniPlayerBar: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                ArtworkView(url: library.coverURL(track), cornerRadius: 6, placeholderSeed: track.albumKey)
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(track.displayArtist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { player.togglePlayPause() } label: {
                    Group {
                        if player.isBuffering {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 40, height: 40)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
            }
            .foregroundStyle(.primary)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { MiniProgressLine().padding(.horizontal, 14).padding(.bottom, 3) }
            .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .contentShape(Rectangle())
            .onTapGesture { player.showNowPlaying = true }
            .gesture(DragGesture(minimumDistance: 20).onEnded { g in
                if g.translation.height < -20 { player.showNowPlaying = true }
                else if g.translation.width < -50 { player.next() }
                else if g.translation.width > 50 { player.previous() }
            })
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Connexion au serveur

struct LoginView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var address = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Field { case address, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color.accentPink.opacity(0.35), radius: 16, y: 8)
                    .padding(.top, 60)

                VStack(spacing: 6) {
                    Text("Mixtape").font(.largeTitle.bold())
                    Text("Connecte-toi au serveur de ton PC.\nL'adresse et le mot de passe sont affichés sur sa page « Gérer ma musique ».")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    TextField("Adresse (ex. 100.64.12.3:4533)", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    SecureField("Mot de passe", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(connect)
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let error {
                    Text(error).font(.footnote).foregroundStyle(Color.accentPink).multilineTextAlignment(.center)
                }

                Button(action: connect) {
                    Group {
                        if isConnecting { ProgressView().tint(.white) } else { Text("Se connecter").fontWeight(.semibold) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .glassButton(prominent: true)
                .controlSize(.large)
                .disabled(isConnecting || address.isEmpty || password.isEmpty)
            }
            .padding(.horizontal, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func connect() {
        guard !address.isEmpty, !password.isEmpty else { return }
        isConnecting = true
        error = nil
        Task {
            do {
                try await library.connect(address: address, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

// MARK: - Réglages

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @State private var confirmLogout = false
    @ObservedObject private var downloads = DownloadManager.shared
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("standbyEnabled") private var standbyEnabled = true
    @ObservedObject private var backup = BackupManager.shared
    @State private var confirmRestore = false
    @State private var showListenTogether = false

    var body: some View {
        List {
            Section("Serveur") {
                LabeledContent("Adresse", value: library.serverAddress)
                LabeledContent("Morceaux", value: "\(library.tracks.count)")
                LabeledContent("Albums", value: "\(library.albums.count)")
                Button {
                    Task { await library.refresh() }
                } label: {
                    HStack {
                        Text("Actualiser la bibliothèque")
                        Spacer()
                        if library.isLoading { ProgressView() }
                    }
                }
            }
            Section {
                Label("Pour ajouter des sons, dépose-les dans le dossier Mixtape du PC. Ils apparaissent ici tout seuls.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Lecture continue", isOn: $autoplay)
                    .tint(Color.accentPink)
            } header: {
                Text("Lecture")
            } footer: {
                Text("Quand ta file d'attente est finie, Mixtape enchaîne sur des sons du même artiste et sur tes favoris.")
            }
            Section {
                Toggle("Mode veille", isOn: $standbyEnabled)
                    .tint(Color.accentPink)
            } footer: {
                Text("Quand l'iPhone est posé à l'horizontale et en charge, Mixtape affiche la pochette, l'heure et les commandes en grand.")
            }
            Section("Couleur de l'app") {
                AccentPicker()
            }
            Section {
                NavigationLink {
                    AlarmSettingsView()
                } label: {
                    Label("Réveil Mixtape", systemImage: "alarm")
                }
                Button {
                    player.showParty = true
                } label: {
                    Label("Lancer le mode soirée", systemImage: "party.popper")
                }
                Button {
                    showListenTogether = true
                } label: {
                    Label("Écouter avec quelqu'un", systemImage: "person.2.wave.2")
                }
            } header: {
                Text("Extras")
            } footer: {
                Text("Mode soirée : pour l'afficher sur ta télé, ouvre le Centre de contrôle puis « Recopie de l'écran ».")
            }
            Section {
                LabeledContent("Dernière sauvegarde",
                               value: backup.lastBackup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Jamais")
                Button {
                    Task { await backup.upload(api: library.api, manual: true) }
                } label: {
                    HStack {
                        Text("Sauvegarder maintenant")
                        Spacer()
                        if backup.isWorking { ProgressView() }
                    }
                }
                Button("Récupérer la sauvegarde du PC") { confirmRestore = true }
            } header: {
                Text("Sauvegarde sur le PC")
            } footer: {
                Text(backup.message ?? "Favoris, historique, stats, réglages et réveil sont envoyés sur ton PC à chaque fois que tu quittes l'app. Si tu réinstalles Mixtape, tout revient tout seul.")
            }
            Section {
                ManageModeToggle()
            } header: {
                Text("Gestion")
            } footer: {
                Text("Avec Face ID. Fait apparaître « Modifier » sur les albums, les sons et les artistes : pochettes, crédits, descriptions, photos, titres. Tout est enregistré sur le PC.")
            }
            Section("Téléchargements") {
                LabeledContent("Sons téléchargés", value: "\(downloads.downloaded.count)")
                LabeledContent("Espace utilisé", value: downloads.totalSize)
                Button("Supprimer tous les téléchargements", role: .destructive) { downloads.removeAll() }
                    .disabled(downloads.downloaded.isEmpty)
            }
            Section {
                Button("Se déconnecter", role: .destructive) { confirmLogout = true }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            }
        }
        .navigationTitle("Réglages")
        .confirmationDialog("Se déconnecter du serveur ?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Se déconnecter", role: .destructive) { library.disconnect() }
        }
        .sheet(isPresented: $showListenTogether) { PartySheet() }
        .confirmationDialog("Remplacer les données de l'iPhone par la sauvegarde du PC ?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Récupérer la sauvegarde") {
                Task { await backup.restore(api: library.api, player: player, onlyIfEmpty: false) }
            }
        }
    }
}

/// Fine ligne sous le mini-lecteur : partie chargée (gris) et partie écoutée (rose).
struct MiniProgressLine: View {
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        MiniProgressContent(clock: player.clock, duration: player.duration)
    }
}

private struct MiniProgressContent: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double

    var body: some View {
        let total = max(duration, 0.1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(Color.primary.opacity(0.25))
                    .frame(width: geo.size.width * min(max(clock.bufferedTime / total, 0), 1))
                    .animation(.linear(duration: 0.5), value: clock.bufferedTime)
                Capsule().fill(Color.accentPink)
                    .frame(width: geo.size.width * min(max(clock.currentTime / total, 0), 1))
            }
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }
}
