import SwiftUI

// MARK: - Lecture du fichier « credits » posé dans le dossier de l'album

/// Une ligne de crédits : « Production : Nayz, K-Rhyme ».
struct CreditLine: Hashable {
    let role: String
    let names: [String]
    /// Ligne reprise des crédits de l'album (le son n'a rien précisé pour ce rôle).
    var fromAlbum = false
}

/// Crédits d'un album : ceux de tout l'album, puis ceux de certains sons ([3] ou [Titre]).
struct AlbumCredits: Equatable {
    var album: [CreditLine] = []
    /// Clé : numéro du son (« 3 ») ou titre en minuscules.
    var tracks: [String: [CreditLine]] = [:]
    /// Ordre d'apparition des sections de sons dans le fichier.
    var trackKeys: [String] = []

    var isEmpty: Bool { album.isEmpty && tracks.isEmpty }

    init(text: String) {
        var current: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let key = Self.normalize(String(line.dropFirst().dropLast()))
                current = key.isEmpty ? nil : key
                if let key = current, !trackKeys.contains(key) { trackKeys.append(key) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let role = line[..<colon].trimmingCharacters(in: .whitespaces)
            let names = line[line.index(after: colon)...]
                .replacingOccurrences(of: " & ", with: ",")
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !role.isEmpty, !names.isEmpty else { continue }
            let credit = CreditLine(role: role, names: names)
            if let key = current { tracks[key, default: []].append(credit) } else { album.append(credit) }
        }
    }

    static func normalize(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        // « [03] » et « [3] » désignent le même son.
        if let n = Int(t) { return String(n) }
        return t
    }

    /// Crédits propres au son (par numéro, sinon par titre).
    func own(for track: Track, position: Int?) -> [CreditLine] {
        if let n = track.trackNumber ?? position, let lines = tracks[String(n)] { return lines }
        return tracks[Self.normalize(track.title)] ?? []
    }

    /// Crédits complets d'un son : les siens, puis ceux de l'album pour les rôles qu'il ne précise pas.
    func full(for track: Track, position: Int?) -> [CreditLine] {
        let mine = own(for: track, position: position)
        let roles = Set(mine.map { $0.role.lowercased() })
        let inherited = album.filter { !roles.contains($0.role.lowercased()) }.map {
            var line = $0
            line.fromAlbum = true
            return line
        }
        return mine + inherited
    }
}

extension LibraryStore {
    /// Crédits d'un son, ou vide s'il n'y en a pas.
    func credits(for track: Track) -> [CreditLine] {
        guard let album = album(for: track), let credits = credits(for: album) else { return [] }
        let position = album.tracks.firstIndex(where: { $0.id == track.id }).map { $0 + 1 }
        return credits.full(for: track, position: position)
    }
}

// MARK: - Affichage

/// Noms d'un rôle : ceux qui ont une page artiste dans Mixtape sont cliquables.
struct CreditNames: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    let names: [String]
    var onOpen: (() -> Void)? = nil

    var body: some View {
        FlowNames(names: names) { name in
            if library.artist(named: name) != nil {
                Button {
                    onOpen?()
                    player.navRequest = .artist(name)
                } label: {
                    Text(name).foregroundStyle(Color.accentPink)
                }
                .buttonStyle(.plain)
            } else {
                Text(name)
            }
        }
    }
}

/// Noms séparés par des virgules, qui passent à la ligne si besoin.
private struct FlowNames<Item: View>: View {
    let names: [String]
    @ViewBuilder let item: (String) -> Item

    var body: some View {
        WrapLayout(spacing: 0, lineSpacing: 2) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                HStack(spacing: 0) {
                    item(name)
                    if i < names.count - 1 { Text(", ") }
                }
            }
        }
    }
}

/// Range ses éléments de gauche à droite et passe à la ligne quand il n'y a plus de place.
private struct WrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Section « Crédits » en bas de la page de l'album.
struct AlbumCreditsSection: View {
    @EnvironmentObject private var library: LibraryStore
    let album: Album
    let credits: AlbumCredits
    @State private var showTracks = false

    private var tracksWithCredits: [Track] {
        album.tracks.enumerated().filter { !credits.own(for: $0.element, position: $0.offset + 1).isEmpty }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Crédits").font(.title3.bold())
            if !credits.album.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(credits.album, id: \.self) { line in
                        GridRow {
                            Text(line.role)
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            CreditNames(names: line.names)
                        }
                    }
                }
                .font(.subheadline)
            }
            if !tracksWithCredits.isEmpty {
                Button { showTracks = true } label: {
                    HStack(spacing: 4) {
                        Text("Voir les crédits par son")
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentPink)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .sheet(isPresented: $showTracks) {
            AlbumTrackCreditsSheet(album: album, credits: credits)
        }
    }
}

/// Liste des crédits de chaque son de l'album.
private struct AlbumTrackCreditsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let album: Album
    let credits: AlbumCredits

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, track in
                    let lines = credits.full(for: track, position: i + 1)
                    if !lines.isEmpty {
                        Section("\(track.trackNumber ?? i + 1). \(track.title)") {
                            ForEach(lines, id: \.self) { line in
                                CreditRow(line: line) { dismiss() }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Crédits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("OK") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct CreditRow: View {
    let line: CreditLine
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(line.role.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                CreditNames(names: line.names, onOpen: onOpen)
                if line.fromAlbum {
                    Text("· repris de l'album").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.body)
        }
        .padding(.vertical, 2)
    }
}

/// Fiche « Crédits » d'un son (depuis le menu « … » d'un son ou le lecteur).
struct TrackCreditsSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let track: Track

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        ArtworkView(url: library.coverURL(track), cornerRadius: 8, placeholderSeed: track.albumKey)
                            .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.headline).lineLimit(2)
                            Text(track.displayArtist).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                let lines = library.credits(for: track)
                if lines.isEmpty {
                    Text("Pas de crédits pour ce son. Ajoute un fichier « credits » dans le dossier de l'album sur le PC.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(lines, id: \.self) { line in
                            CreditRow(line: line) { dismiss() }
                        }
                    }
                }
            }
            .navigationTitle("Crédits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("OK") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
