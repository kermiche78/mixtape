import SwiftUI

// MARK: - Annotations de sons

/// Un commentaire posé sur un passage d'un son.
struct Annotation: Codable, Identifiable, Equatable {
    var id: String
    var trackId: String
    var start: Double
    var end: Double?
    var text: String
    var createdAt: Double
    /// Visible par tout le monde (gardée sur le PC) ou seulement sur cet iPhone.
    var isPublic = false

    private enum CodingKeys: String, CodingKey { case id, trackId, start, end, text, createdAt }

    /// Moment où la bulle disparaît (8 secondes si aucune fin n'est donnée).
    var shownUntil: Double { end ?? start + 8 }
}

/// Annotations privées (sur l'iPhone) et publiques (sur le PC).
@MainActor
final class AnnotationStore: ObservableObject {
    static let shared = AnnotationStore()

    @Published private(set) var publicNotes: [Annotation]
    @Published private(set) var privateNotes: [Annotation]

    private static let privateKey = "annotations"
    private static let publicCacheKey = "publicAnnotationsCache"

    private init() {
        let d = UserDefaults.standard
        privateNotes = (d.data(forKey: Self.privateKey)).flatMap { try? JSONDecoder().decode([Annotation].self, from: $0) } ?? []
        publicNotes = (d.data(forKey: Self.publicCacheKey))
            .flatMap { try? JSONDecoder().decode([Annotation].self, from: $0) }?
            .map { var n = $0; n.isPublic = true; return n } ?? []
    }

    func notes(for trackId: String) -> [Annotation] {
        (publicNotes.filter { $0.trackId == trackId } + privateNotes.filter { $0.trackId == trackId })
            .sorted { $0.start < $1.start }
    }

    func count(for trackId: String) -> Int {
        publicNotes.reduce(0) { $0 + ($1.trackId == trackId ? 1 : 0) }
            + privateNotes.reduce(0) { $0 + ($1.trackId == trackId ? 1 : 0) }
    }

    /// Relit les annotations publiques depuis le PC.
    func refresh(api: APIClient?) async {
        guard let api, let fresh = try? await api.annotations() else { return }
        let marked = fresh.map { var n = $0; n.isPublic = true; return n }
        if marked != publicNotes {
            publicNotes = marked
            UserDefaults.standard.set(try? JSONEncoder().encode(marked), forKey: Self.publicCacheKey)
        }
    }

    /// Relit les annotations privées (après une restauration de la sauvegarde du PC).
    func reloadPrivate() {
        privateNotes = (UserDefaults.standard.data(forKey: Self.privateKey))
            .flatMap { try? JSONDecoder().decode([Annotation].self, from: $0) } ?? []
    }

    private func savePrivate() {
        UserDefaults.standard.set(try? JSONEncoder().encode(privateNotes), forKey: Self.privateKey)
    }

    /// Enregistre (ou déplace entre « pour moi » et « pour tout le monde »).
    func save(_ note: Annotation, isPublic: Bool, api: APIClient?) async throws {
        let wasPublic = publicNotes.contains { $0.id == note.id }
        if isPublic {
            guard let api else { throw APIError.unreachable }
            var saved = try await api.saveAnnotation(note)
            saved.isPublic = true
            publicNotes.removeAll { $0.id == saved.id }
            publicNotes.append(saved)
            if privateNotes.contains(where: { $0.id == note.id }) {
                privateNotes.removeAll { $0.id == note.id }
                savePrivate()
            }
        } else {
            if wasPublic {
                guard let api else { throw APIError.unreachable }
                try await api.deleteAnnotation(id: note.id)
                publicNotes.removeAll { $0.id == note.id }
            }
            var mine = note
            mine.isPublic = false
            privateNotes.removeAll { $0.id == note.id }
            privateNotes.append(mine)
            savePrivate()
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(publicNotes), forKey: Self.publicCacheKey)
    }

    func delete(_ note: Annotation, api: APIClient?) async throws {
        if note.isPublic {
            guard let api else { throw APIError.unreachable }
            try await api.deleteAnnotation(id: note.id)
            publicNotes.removeAll { $0.id == note.id }
            UserDefaults.standard.set(try? JSONEncoder().encode(publicNotes), forKey: Self.publicCacheKey)
        } else {
            privateNotes.removeAll { $0.id == note.id }
            savePrivate()
        }
    }
}

// MARK: - Bulle pendant l'écoute

/// Bulle posée sur la pochette quand la lecture arrive sur un passage annoté.
struct AnnotationBubble: View {
    @ObservedObject var clock: PlaybackClock
    @ObservedObject private var store = AnnotationStore.shared
    @AppStorage("showAnnotations") private var showAnnotations = true
    let trackId: String

    var body: some View {
        let t = clock.currentTime
        let note = showAnnotations ? store.notes(for: trackId).first(where: { t >= $0.start && t < $0.shownUntil }) : nil
        ZStack {
            if let note {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(formatTime(note.start))
                        Text("·")
                        Text(note.isPublic ? "POUR TOUT LE MONDE" : "TON ANNOTATION")
                        if note.isPublic { Image(systemName: "globe") }
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentPink)
                    Text(note.text)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                .padding(10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .id(note.id)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: note?.id)
        .allowsHitTesting(false)
    }
}

// MARK: - Écrire une annotation

struct AnnotationEditor: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("manageMode") private var manageMode = false
    let track: Track
    let existing: Annotation?

    @State private var start: Double
    @State private var hasEnd: Bool
    @State private var end: Double
    @State private var text: String
    @State private var isPublic: Bool
    @State private var isSaving = false
    @State private var error: String?

    init(track: Track, start: Double, existing: Annotation? = nil) {
        self.track = track
        self.existing = existing
        let s = existing?.start ?? max(0, start.rounded(.down))
        _start = State(initialValue: s)
        _hasEnd = State(initialValue: existing?.end != nil)
        _end = State(initialValue: existing?.end ?? min(s + 10, max(track.duration, s + 1)))
        _text = State(initialValue: existing?.text ?? "")
        _isPublic = State(initialValue: existing?.isPublic ?? false)
    }

    private var isCurrent: Bool { player.current?.id == track.id }
    private var maxTime: Double { max(track.duration, 1) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    timeRow("Début", value: $start)
                    Toggle("Fin du passage", isOn: $hasEnd).tint(Color.accentPink)
                    if hasEnd { timeRow("Fin", value: $end) }
                    Button {
                        if isCurrent {
                            player.seek(to: start)
                            if !player.isPlaying { player.togglePlayPause() }
                        } else {
                            player.play([track], resumeAt: start)
                        }
                    } label: {
                        Label("Écouter le passage", systemImage: "play.circle")
                    }
                } footer: {
                    Text(hasEnd ? "La bulle reste affichée pendant tout le passage."
                                : "Sans fin, la bulle reste affichée 8 secondes.")
                }

                Section("Ton commentaire") {
                    TextEditor(text: $text).frame(minHeight: 110)
                }

                if manageMode {
                    Section {
                        Picker("Visible par", selection: $isPublic) {
                            Text("Moi seulement").tag(false)
                            Text("Tout le monde").tag(true)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Visible par")
                    } footer: {
                        Text(isPublic ? "Enregistrée sur le PC : tous ceux qui ont Mixtape la voient, et tes invités aussi pendant l'écoute à deux."
                                      : "Gardée sur ton iPhone (et dans ta sauvegarde). Personne d'autre ne la voit.")
                    }
                }

                if let existing {
                    Section {
                        Button("Supprimer l'annotation", role: .destructive) {
                            Task {
                                do {
                                    try await AnnotationStore.shared.delete(existing, api: library.api)
                                    dismiss()
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Annoter « \(track.title) »" : "Modifier l'annotation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving { ProgressView() } else {
                        Button("Enregistrer") { Task { await save() } }
                            .bold()
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .alert("Pas enregistrée", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSaving)
    }

    private func timeRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Button { value.wrappedValue = max(0, value.wrappedValue - 1) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
            Text(formatTime(value.wrappedValue))
                .font(.body.monospacedDigit())
                .frame(minWidth: 52)
            Button { value.wrappedValue = min(maxTime, value.wrappedValue + 1) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
            if isCurrent {
                Button("Maintenant") { value.wrappedValue = player.currentTime.rounded(.down) }
                    .buttonStyle(.borderless)
                    .font(.footnote.weight(.semibold))
                    .padding(.leading, 6)
            }
        }
        .foregroundStyle(.primary)
        .tint(Color.accentPink)
    }

    private func save() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        var note = existing ?? Annotation(id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)),
                                          trackId: track.id, start: 0, end: nil, text: "",
                                          createdAt: Date().timeIntervalSince1970)
        note.start = start
        note.end = hasEnd && end > start ? end : nil
        note.text = body
        do {
            try await AnnotationStore.shared.save(note, isPublic: manageMode ? isPublic : false, api: library.api)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Toutes les annotations d'un son

struct AnnotationsListSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var store = AnnotationStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("manageMode") private var manageMode = false
    let track: Track
    @State private var editing: Annotation?
    @State private var adding = false

    private func canEdit(_ note: Annotation) -> Bool { !note.isPublic || manageMode }

    var body: some View {
        NavigationStack {
            List {
                let notes = store.notes(for: track.id)
                if notes.isEmpty {
                    Text("Aucune annotation sur ce son. Pendant l'écoute, touche la bulle dans le lecteur pour commenter un passage.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(notes) { note in
                    Button {
                        if player.current?.id == track.id {
                            player.seek(to: note.start)
                        } else {
                            player.play([track], resumeAt: note.start)
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(formatTime(note.start))
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(Color.accentPink)
                                .frame(minWidth: 40, alignment: .leading)
                            Text(note.text).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: note.isPublic ? "globe" : "lock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if canEdit(note) {
                            Button(role: .destructive) {
                                Task { try? await store.delete(note, api: library.api) }
                            } label: { Label("Supprimer", systemImage: "trash") }
                            Button { editing = note } label: { Label("Modifier", systemImage: "pencil") }
                        }
                    }
                }
            }
            .navigationTitle("Annotations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("OK") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Nouvelle annotation")
                }
            }
            .sheet(item: $editing) { note in AnnotationEditor(track: track, start: note.start, existing: note) }
            .sheet(isPresented: $adding) {
                AnnotationEditor(track: track, start: player.current?.id == track.id ? player.currentTime : 0)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
