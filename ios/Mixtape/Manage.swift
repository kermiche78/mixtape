import LocalAuthentication
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Mode Gestion

/// Ouvre le mode Gestion avec Face ID (ou le code de l'iPhone).
enum ManageAccess {
    static func unlock() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: "Ouvrir le mode Gestion de Mixtape")) ?? false
    }
}

/// Interrupteur des Réglages : Face ID pour l'allumer, éteint d'un geste.
struct ManageModeToggle: View {
    @AppStorage("manageMode") private var manageMode = false

    var body: some View {
        Toggle(isOn: Binding(get: { manageMode }, set: { on in
            if on {
                Task { if await ManageAccess.unlock() { manageMode = true } }
            } else {
                manageMode = false
            }
        })) {
            Label("Mode Gestion", systemImage: "pencil.and.list.clipboard")
        }
        .tint(Color.accentPink)
    }
}

/// Photo choisie dans la galerie, prête à envoyer (JPEG, 1600 px max).
private func jpegData(from item: PhotosPickerItem) async -> Data? {
    guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return nil }
    let maxSide: CGFloat = 1600
    let scale = min(1, maxSide / max(image.size.width, image.size.height))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    return resized.jpegData(compressionQuality: 0.9)
}

// MARK: - Crédits d'un seul son dans le fichier de l'album

enum CreditsText {
    private static func headerKey(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        return AlbumCredits.normalize(String(t.dropFirst().dropLast()))
    }

    /// Plage des lignes de la section du son (en-tête compris), si elle existe.
    private static func range(in lines: [String], keys: Set<String>) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { headerKey($0).map { keys.contains($0) } ?? false }) else { return nil }
        var end = start + 1
        while end < lines.count, headerKey(lines[end]) == nil { end += 1 }
        return start..<end
    }

    static func section(in text: String, keys: Set<String>) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let r = range(in: lines, keys: keys) else { return "" }
        return lines[(r.lowerBound + 1)..<r.upperBound].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remplace (ou ajoute, ou supprime si vide) la section du son.
    static func replacing(in text: String, keys: Set<String>, header: String, with body: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = content.isEmpty ? [] : ["[\(header)]"] + content.components(separatedBy: "\n") + [""]
        if let r = range(in: lines, keys: keys) {
            lines.replaceSubrange(r, with: block)
        } else if !block.isEmpty {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += block
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Modifier un album

struct AlbumEditorView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss
    let album: Album

    @State private var loaded: ManagedAlbum?
    @State private var name = ""
    @State private var descriptionText = ""
    @State private var creditsText = ""
    @State private var photo: PhotosPickerItem?
    @State private var newCover: UIImage?
    @State private var newCoverData: Data?
    @State private var isSaving = false
    @State private var error: String?

    private var anyTrack: Track? { album.tracks.first }

    var body: some View {
        NavigationStack {
            Form {
                if let loaded {
                    Section {
                        HStack(spacing: 14) {
                            Group {
                                if let newCover {
                                    Image(uiImage: newCover).resizable().scaledToFill()
                                } else {
                                    ArtworkView(url: library.coverURL(album.coverTrack), cornerRadius: 0, placeholderSeed: album.id)
                                }
                            }
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            PhotosPicker(selection: $photo, matching: .images) {
                                Label("Changer la pochette", systemImage: "photo")
                            }
                        }
                    } footer: {
                        Text("Enregistré sur le PC dans \(loaded.folder). L'ancienne pochette est gardée à côté.")
                    }

                    Section("Nom de l'album") {
                        TextField("Nom", text: $name)
                    }

                    Section {
                        TextEditor(text: $descriptionText).frame(minHeight: 120)
                    } header: {
                        Text("Description")
                    }

                    Section {
                        TextEditor(text: $creditsText)
                            .font(.callout.monospaced())
                            .frame(minHeight: 180)
                        if creditsText.isEmpty {
                            Button("Partir d'un modèle") {
                                creditsText = "Production : \nMix : \nMastering : \nPochette : "
                            }
                        }
                    } header: {
                        Text("Crédits")
                    } footer: {
                        Text("Une ligne par rôle : « Production : Nayz, K-Rhyme ». Pour un son précis, écris [3] ou [Titre] puis ses crédits en dessous. Tu peux aussi le faire depuis « Modifier le son ».")
                    }
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("Modifier l'album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving { ProgressView() } else {
                        Button("Enregistrer") { Task { await save() } }.bold().disabled(loaded == nil)
                    }
                }
            }
            .alert("Pas enregistré", isPresented: Binding(get: { error != nil && loaded != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .task { await load() }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let data = await jpegData(from: item) {
                        newCoverData = data
                        newCover = UIImage(data: data)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func load() async {
        guard let api = library.api, let track = anyTrack else { return }
        do {
            let info = try await api.managedAlbum(trackId: track.id)
            name = album.name
            descriptionText = info.description
            creditsText = info.credits
            loaded = info
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let api = library.api, let track = anyTrack, let loaded else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if let newCoverData { try await api.uploadAlbumCover(trackId: track.id, jpeg: newCoverData) }
            if descriptionText != loaded.description {
                try await api.setAlbumText(trackId: track.id, kind: "description", text: descriptionText)
            }
            if creditsText != loaded.credits {
                try await api.setAlbumText(trackId: track.id, kind: "credits", text: creditsText)
            }
            let newName = name.trimmingCharacters(in: .whitespaces)
            let renamed = !newName.isEmpty && newName != album.name
            if renamed { try await api.renameAlbum(trackId: track.id, name: newName) }
            await library.refresh()
            dismiss()
            if renamed { player.navRequest = .album("album:\(newName.lowercased())") }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Modifier un son

struct TrackEditorView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let track: Track

    @State private var title = ""
    @State private var number = ""
    @State private var credits = ""
    @State private var fullCredits: String?
    @State private var albumError: String?
    @State private var isSaving = false
    @State private var error: String?

    /// Position du son dans son album (sert si le son n'a pas de numéro).
    private var position: Int? {
        library.album(for: track)?.tracks.firstIndex(where: { $0.id == track.id }).map { $0 + 1 }
    }

    private var keys: Set<String> {
        var k: Set<String> = [AlbumCredits.normalize(track.title)]
        if let n = track.trackNumber ?? position { k.insert(String(n)) }
        return k
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Titre") {
                    TextField("Titre", text: $title)
                }
                Section {
                    TextField("Numéro", text: $number).keyboardType(.numberPad)
                } header: {
                    Text("Numéro dans l'album")
                } footer: {
                    Text("Laisse vide pour reprendre le numéro du fichier.")
                }
                Section {
                    if fullCredits != nil {
                        TextEditor(text: $credits)
                            .font(.callout.monospaced())
                            .frame(minHeight: 140)
                        if credits.isEmpty {
                            Button("Partir d'un modèle") { credits = "Feat : \nÉcriture : \nProduction : " }
                        }
                    } else if let albumError {
                        Text(albumError).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                } header: {
                    Text("Crédits de ce son")
                } footer: {
                    Text("Une ligne par rôle : « Feat : Dina ». Les rôles que tu ne remplis pas reprennent les crédits de l'album.")
                }
            }
            .navigationTitle("Modifier le son")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving { ProgressView() } else {
                        Button("Enregistrer") { Task { await save() } }.bold()
                    }
                }
            }
            .alert("Pas enregistré", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .task { await load() }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func load() async {
        title = track.title
        number = track.trackNumber.map(String.init) ?? ""
        guard let api = library.api else { return }
        do {
            let info = try await api.managedAlbum(trackId: track.id)
            fullCredits = info.credits
            credits = CreditsText.section(in: info.credits, keys: keys)
        } catch {
            albumError = error.localizedDescription
        }
    }

    private func save() async {
        guard let api = library.api else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let n = Int(number.trimmingCharacters(in: .whitespaces))
            if title != track.title || n != track.trackNumber {
                try await api.editTrack(trackId: track.id, title: title, trackNumber: n)
            }
            if let fullCredits, credits.trimmingCharacters(in: .whitespacesAndNewlines) != CreditsText.section(in: fullCredits, keys: keys) {
                let header = (n ?? track.trackNumber ?? position).map(String.init) ?? track.title
                let updated = CreditsText.replacing(in: fullCredits, keys: keys, header: header, with: credits)
                try await api.setAlbumText(trackId: track.id, kind: "credits", text: updated)
            }
            await library.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Photo d'un artiste

/// Bouton « Changer la photo » sur la page d'un artiste (mode Gestion).
struct ArtistPhotoPicker: View {
    @EnvironmentObject private var library: LibraryStore
    let artist: String
    @State private var item: PhotosPickerItem?
    @State private var isUploading = false
    @State private var error: String?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            if isUploading {
                ProgressView()
            } else {
                Image(systemName: "camera")
            }
        }
        .accessibilityLabel("Changer la photo de l'artiste")
        .onChange(of: item) { _, picked in
            guard let picked, let api = library.api else { return }
            Task {
                isUploading = true
                defer { isUploading = false; item = nil }
                guard let data = await jpegData(from: picked) else { error = "Image illisible."; return }
                do {
                    try await api.uploadArtistPhoto(artist: artist, jpeg: data)
                    await library.refresh()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .alert("Photo pas enregistrée", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}
