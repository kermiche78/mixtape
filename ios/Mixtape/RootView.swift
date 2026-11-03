import SwiftUI

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore

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

    var body: some View {
        TabView {
            NavigationStack { LibraryView() }
                .miniPlayerInset()
                .tabItem { Label("Bibliothèque", systemImage: "square.stack.fill") }

            NavigationStack { SearchView() }
                .miniPlayerInset()
                .tabItem { Label("Recherche", systemImage: "magnifyingglass") }

            NavigationStack { SettingsView() }
                .miniPlayerInset()
                .tabItem { Label("Réglages", systemImage: "gearshape.fill") }
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
        .task { await library.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await library.refresh() } }
        }
    }
}

extension View {
    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
    }
}

/// Le petit lecteur flottant au-dessus des onglets.
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
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 40, height: 40)
                        .contentTransition(.symbolEffect(.replace))
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
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
                    .padding(.vertical, 15)
                    .background(Color.accentPink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
                }
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
    }
}
