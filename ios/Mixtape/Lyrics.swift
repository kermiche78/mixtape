import SwiftUI

// MARK: - Paroles (écrites par l'IA sur le PC)

struct LyricLine: Codable, Hashable {
    var t: Double
    var end: Double?
    var text: String
    var fr: String?
}

struct Lyrics: Codable, Equatable {
    var language: String?
    var source: String?
    var translated: Bool?
    var lines: [LyricLine]

    var hasTranslation: Bool { lines.contains { ($0.fr ?? "").isEmpty == false } }
}

/// Garde les paroles déjà chargées (une petite requête par son).
@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()

    @Published private(set) var cache: [String: Lyrics] = [:]
    /// Sons pour lesquels le PC n'a pas (encore) de paroles.
    @Published private(set) var missing: Set<String> = []
    private var loading: Set<String> = []

    func lyrics(for id: String) -> Lyrics? { cache[id] }
    func isMissing(_ id: String) -> Bool { missing.contains(id) }

    func load(_ track: Track, api: APIClient?, force: Bool = false) async {
        guard let api, !loading.contains(track.id) else { return }
        if !force, cache[track.id] != nil { return }
        loading.insert(track.id)
        defer { loading.remove(track.id) }
        do {
            let l = try await api.lyrics(trackId: track.id)
            cache[track.id] = l
            missing.remove(track.id)
        } catch APIError.server(404), APIError.message(_) {
            cache[track.id] = nil
            missing.insert(track.id)
        } catch {
            // PC injoignable : on réessaiera plus tard.
        }
    }

    func store(_ lyrics: Lyrics, for id: String) {
        cache[id] = lyrics
        missing.remove(id)
    }
}

/// Bouton « Paroles » (blanc quand les paroles sont ouvertes, comme sur Tidal).
struct LyricsPill: View {
    let title: String
    let on: Bool
    var dimmed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? Color.black : .white.opacity(dimmed ? 0.45 : 1))
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background {
                    if on {
                        Capsule().fill(.white)
                    } else {
                        Capsule().fill(.white.opacity(0.12))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    }
                }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: on)
    }
}

/// Paroles qui défilent avec la musique : la ligne chantée en blanc, les autres en gris.
struct LyricsScrollView: View {
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject var clock: PlaybackClock
    let lyrics: Lyrics
    let translate: Bool

    @State private var userScrollUntil = Date.distantPast

    private func activeIndex(at t: Double) -> Int? {
        // Petite avance : la ligne s'allume juste avant d'être chantée.
        let now = t + 0.25
        guard let i = lyrics.lines.lastIndex(where: { $0.t <= now }) else { return nil }
        return i
    }

    var body: some View {
        let active = activeIndex(at: clock.currentTime)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 30)
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                        Button {
                            player.seek(to: line.t)
                            userScrollUntil = .distantPast
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.text)
                                    .font(.system(size: 28, weight: .bold))
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                if translate, let fr = line.fr, !fr.isEmpty {
                                    Text(fr)
                                        .font(.system(size: 17, weight: .semibold))
                                        .opacity(0.75)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .foregroundStyle(.white)
                            .opacity(opacity(i, active))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(i)
                        .animation(.easeInOut(duration: 0.3), value: active)
                    }
                    Color.clear.frame(height: 220)
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                userScrollUntil = Date().addingTimeInterval(3.5)
            })
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.72),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: active) { _, i in
                guard let i, Date() > userScrollUntil else { return }
                withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0, y: 0.22)) }
            }
            .onAppear {
                if let active { proxy.scrollTo(active, anchor: UnitPoint(x: 0, y: 0.22)) }
            }
        }
    }

    private func opacity(_ i: Int, _ active: Int?) -> Double {
        guard let active else { return 0.45 }
        if i == active { return 1 }
        return i < active ? 0.35 : 0.5
    }
}

/// Ce qui s'affiche quand on ouvre les paroles dans le lecteur.
struct LyricsPanel: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var store = LyricsStore.shared
    @AppStorage("manageMode") private var manageMode = false
    @AppStorage("lyricsTranslate") private var translate = true
    let track: Track
    @State private var queued = false

    var body: some View {
        Group {
            if let lyrics = store.lyrics(for: track.id) {
                LyricsScrollView(clock: player.clock, lyrics: lyrics, translate: translate && lyrics.hasTranslation)
            } else if store.isMissing(track.id) {
                VStack(spacing: 14) {
                    Image(systemName: "quote.bubble").font(.system(size: 40)).opacity(0.6)
                    Text("Paroles pas encore disponibles").font(.title3.bold())
                    Text("L'IA du PC les écrira pendant sa plage horaire.")
                        .font(.subheadline).opacity(0.7).multilineTextAlignment(.center)
                    if manageMode {
                        Button(queued ? "Ajouté en priorité" : "Générer maintenant en priorité") {
                            Task {
                                try? await library.api?.lyricsPriority(trackIds: [track.id])
                                queued = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.2))
                        .disabled(queued)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: track.id) { await store.load(track, api: library.api) }
    }
}

// MARK: - Corriger les paroles (mode Gestion)

struct LyricsEditorSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var lines: [LyricLine] = []
    @State private var isSaving = false
    @State private var error: String?
    @State private var confirmRedo = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(lines.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button(formatTime(lines[i].t)) {
                                    if player.current?.id == track.id { player.seek(to: lines[i].t) }
                                }
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .buttonStyle(.borderless)
                                .tint(Color.accentPink)
                                Spacer()
                                if player.current?.id == track.id {
                                    Button("Caler ici") { lines[i].t = player.currentTime }
                                        .font(.caption.weight(.semibold))
                                        .buttonStyle(.borderless)
                                }
                            }
                            TextField("Ligne", text: $lines[i].text, axis: .vertical)
                            if lines[i].fr != nil {
                                TextField("Traduction", text: Binding(get: { lines[i].fr ?? "" }, set: { lines[i].fr = $0 }), axis: .vertical)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { lines.remove(atOffsets: $0) }
                } footer: {
                    Text("Touche le temps pour réécouter la ligne. « Caler ici » met la ligne au moment où en est la lecture. Balaie pour supprimer une ligne.")
                }
                Section {
                    Button("Refaire par l'IA", role: .destructive) { confirmRedo = true }
                }
            }
            .navigationTitle("Modifier les paroles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving { ProgressView() } else {
                        Button("Enregistrer") { Task { await save() } }.bold()
                    }
                }
            }
            .confirmationDialog("Effacer ces paroles et les refaire par l'IA ?", isPresented: $confirmRedo, titleVisibility: .visible) {
                Button("Refaire par l'IA", role: .destructive) {
                    Task {
                        try? await library.api?.lyricsPriority(trackIds: [track.id])
                        await LyricsStore.shared.load(track, api: library.api, force: true)
                        dismiss()
                    }
                }
            }
            .alert("Pas enregistré", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .onAppear { lines = LyricsStore.shared.lyrics(for: track.id)?.lines ?? [] }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        guard let api = library.api else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await api.saveLyrics(trackId: track.id, lines: lines)
            LyricsStore.shared.store(saved, for: track.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Réglages « Paroles IA » (mode Gestion)

struct LyricsEngineStatus: Decodable {
    struct Settings: Codable {
        var mode: String
        var start: Int
        var end: Int
        var days: [Int]
        var autoNew: Bool
        var model: String
        var voice: Bool
        var power: String?
    }
    struct Current: Decodable { let id: String; let title: String; let artist: String }
    var settings: Settings
    let running: Bool
    let phase: String?
    let message: String?
    let current: Current?
    let done: Int
    let total: Int
    let remaining: Int
    let averageSeconds: Double?
    let etaDays: Double?
    let inWindow: Bool
}

struct LyricsEngineView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var status: LyricsEngineStatus?
    @State private var settings: LyricsEngineStatus.Settings?
    @State private var error: String?

    private static let dayNames = ["L", "M", "M", "J", "V", "S", "D"]

    var body: some View {
        List {
            if let status {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle().fill(status.running ? Color.green : Color.secondary).frame(width: 8, height: 8)
                            Text(stateText(status)).font(.headline)
                        }
                        ProgressView(value: Double(min(status.done, status.total)), total: Double(max(status.total, 1)))
                            .tint(Color.accentPink)
                        Text("\(status.done) sons sur \(status.total) ont leurs paroles")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let cur = status.current {
                            Text("En cours : \(cur.title) · \(cur.artist)").font(.subheadline).lineLimit(1)
                        }
                        if let avg = status.averageSeconds {
                            Text("Environ \(Int(avg.rounded())) s par son" + (status.etaDays.map { " · fini dans ~\(formatDays($0))" } ?? ""))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let msg = status.message, !msg.isEmpty {
                            Text(msg).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if settings != nil {
                Section {
                    Picker("Quand", selection: binding(\.mode)) {
                        Text("Maintenant").tag("now")
                        Text("Plage horaire").tag("schedule")
                        Text("Pause").tag("off")
                    }
                    .pickerStyle(.segmented)
                    if settings?.mode == "schedule" {
                        Picker("De", selection: binding(\.start)) {
                            ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0) }
                        }
                        Picker("À", selection: binding(\.end)) {
                            ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0) }
                        }
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { d in
                                let on = settings?.days.contains(d) ?? false
                                Button(Self.dayNames[d]) {
                                    var s = settings!
                                    if on { s.days.removeAll { $0 == d } } else { s.days.append(d) }
                                    settings = s
                                    push()
                                }
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(on ? Color.accentPink : Color.secondary.opacity(0.15), in: Circle())
                                .foregroundStyle(on ? .white : .primary)
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("Quand l'IA travaille")
                } footer: {
                    Text(settings?.mode == "now" ? "L'IA travaille tout de suite, jusqu'à ce que tous les sons aient leurs paroles."
                         : settings?.mode == "off" ? "L'IA est en pause. Le son en cours se termine avant l'arrêt."
                         : "En dehors de cette plage, l'IA se met en pause toute seule et reprend là où elle s'était arrêtée.")
                }

                Section {
                    Picker("Puissance", selection: Binding(get: { settings?.power ?? "balanced" },
                                                           set: { settings?.power = $0; push() })) {
                        Text("Économe").tag("eco")
                        Text("Équilibrée").tag("balanced")
                        Text("Maximale").tag("max")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Puissance du PC utilisée")
                } footer: {
                    Text(powerText)
                }

                Section {
                    Toggle("Nouveaux sons automatiquement", isOn: binding(\.autoNew)).tint(Color.accentPink)
                    Toggle("Isoler la voix du beat", isOn: binding(\.voice)).tint(Color.accentPink)
                    Picker("Qualité", selection: binding(\.model)) {
                        Text("Rapide").tag("small")
                        Text("Précise").tag("medium")
                        Text("Maximale (lente)").tag("large-v3")
                    }
                } header: {
                    Text("Réglages")
                } footer: {
                    Text("Les sons que tu écoutes le plus passent en premier. Les sons pas en français sont traduits automatiquement.")
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Paroles IA")
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private var powerText: String {
        switch settings?.power ?? "balanced" {
        case "eco": return "Un quart du processeur : le PC reste très fluide, mais l'IA va environ 2 fois moins vite. Idéal en journée."
        case "max": return "Presque tout le processeur : l'IA va le plus vite possible, mais le PC peut ramer. Idéal la nuit."
        default: return "La moitié du processeur : bon équilibre entre vitesse de l'IA et fluidité du PC et de la musique."
        }
    }

    private func stateText(_ s: LyricsEngineStatus) -> String {
        if s.phase == "installation" { return "Installation de l'IA…" }
        if s.running { return "L'IA écrit des paroles" }
        if s.remaining == 0 { return "Tous les sons ont leurs paroles" }
        if s.settings.mode == "off" { return "En pause" }
        if s.settings.mode == "schedule" { return "En attente de la plage horaire" }
        return "Démarrage…"
    }

    private func formatDays(_ d: Double) -> String {
        if d < 1 { return "\(max(1, Int((d * 24).rounded()))) h" }
        return "\(Int(d.rounded())) jour\(d >= 1.5 ? "s" : "")"
    }

    private func binding<T>(_ key: WritableKeyPath<LyricsEngineStatus.Settings, T>) -> Binding<T> {
        Binding {
            settings![keyPath: key]
        } set: { value in
            settings![keyPath: key] = value
            push()
        }
    }

    private func refresh() async {
        guard let api = library.api else { return }
        do {
            let s = try await api.lyricsEngine()
            status = s
            if settings == nil { settings = s.settings }
            error = nil
        } catch {
            self.error = "Le PC ne répond pas : \(error.localizedDescription)"
        }
    }

    private func push() {
        guard let api = library.api, let settings else { return }
        Task {
            if let s = try? await api.setLyricsEngine(settings) { status = s }
        }
    }
}
