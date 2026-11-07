import SwiftUI

// MARK: - Historique

/// Tout ce que tu as écouté, jour par jour.
struct HistoryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var stats = Stats.shared
    @State private var confirmClear = false

    private struct HistoryItem: Identifiable {
        let event: PlayEvent
        let track: Track
        var id: PlayEvent { event }
    }

    private struct DayGroup: Identifiable {
        let id: String
        let title: String
        let items: [HistoryItem]
    }

    var body: some View {
        let groups = grouped()
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        HStack(spacing: 8) {
                            TrackRow(track: item.track)
                            Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: item.event.date)))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { player.play([item.track]) }
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("Aucune écoute", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Les sons que tu écoutes apparaîtront ici.")
                }
            }
        }
        .navigationTitle("Historique")
        .toolbar {
            if !stats.history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Effacer") { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Effacer tout l'historique ?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Effacer l'historique", role: .destructive) { stats.clearHistory() }
        } message: {
            Text("Tes favoris et ton Mixtape Replay « Depuis le début » sont gardés.")
        }
    }

    /// Regroupe les 500 dernières écoutes par jour.
    private func grouped() -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        var currentKey = ""
        var currentTitle = ""
        var currentItems: [HistoryItem] = []

        for event in stats.history.prefix(500) {
            guard let track = library.track(event.trackId) else { continue }
            let date = Date(timeIntervalSince1970: event.date)
            let day = calendar.startOfDay(for: date)
            let key = String(Int(day.timeIntervalSince1970))
            if key != currentKey {
                if !currentItems.isEmpty { groups.append(DayGroup(id: currentKey, title: currentTitle, items: currentItems)) }
                currentKey = key
                currentTitle = Self.dayTitle(for: date)
                currentItems = []
            }
            currentItems.append(HistoryItem(event: event, track: track))
        }
        if !currentItems.isEmpty { groups.append(DayGroup(id: currentKey, title: currentTitle, items: currentItems)) }
        return groups
    }

    private static func dayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Aujourd'hui" }
        if calendar.isDateInYesterday(date) { return "Hier" }
        let text = dayFormatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Mixtape Replay

enum ReplayPeriod: String, CaseIterable, Identifiable {
    case month = "Ce mois-ci"
    case year = "Cette année"
    case all = "Depuis le début"
    var id: String { rawValue }
}

/// Ton récap : sons, artistes et albums les plus écoutés.
struct ReplayView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @ObservedObject private var stats = Stats.shared
    @State private var period: ReplayPeriod = .month

    private struct RankedArtist: Identifiable {
        var id: String { artist.id }
        let artist: Artist
        let plays: Int
    }

    private struct RankedTrack: Identifiable {
        var id: String { track.id }
        let track: Track
        let plays: Int
    }

    private struct RankedAlbum: Identifiable {
        var id: String { album.id }
        let album: Album
        let plays: Int
    }

    var body: some View {
        let counts = playCounts()
        let topTracks = counts
            .compactMap { id, n in library.track(id).map { RankedTrack(track: $0, plays: n) } }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.track.title < $1.track.title }
        let totalPlays = topTracks.reduce(0) { $0 + $1.plays }
        let minutes = Int((topTracks.reduce(0.0) { $0 + $1.track.duration * Double($1.plays) } / 60).rounded())
        let artists = rankedArtists(topTracks)
        let albums = rankedAlbums(topTracks)
        let top = topTracks.prefix(25).map { $0.track }

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Picker("Période", selection: $period) {
                    ForEach(ReplayPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                if topTracks.isEmpty {
                    ContentUnavailableView {
                        Label("Pas encore d'écoutes", systemImage: "chart.bar")
                    } description: {
                        Text("Écoute quelques sons et reviens voir ton récap.")
                    }
                    .padding(.top, 40)
                } else {
                    header(minutes: minutes, plays: totalPlays, artists: artists.count)
                        .padding(.horizontal, 20)

                    Button { player.play(top) } label: {
                        Label("Lire ton top", systemImage: "play.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .glassButton(prominent: true)
                    .controlSize(.large)
                    .padding(.horizontal, 20)

                    if !artists.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Top artistes").font(.title2.bold()).padding(.horizontal, 20)
                            VStack(spacing: 0) {
                                ForEach(Array(artists.prefix(5).enumerated()), id: \.element.id) { i, item in
                                    NavigationLink(value: item.artist) {
                                        HStack(spacing: 14) {
                                            Text("\(i + 1)")
                                                .font(.title3.bold())
                                                .foregroundStyle(i == 0 ? Color.accentPink : .secondary)
                                                .frame(width: 26)
                                            ArtworkView(url: library.coverURL(item.artist.coverTrack), cornerRadius: 28, placeholderSeed: item.artist.id)
                                                .frame(width: 56, height: 56)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.artist.name).font(.headline).lineLimit(1)
                                                Text(playsText(item.plays)).font(.subheadline).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                        }
                                        .padding(.vertical, 8)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }

                    if !albums.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Top albums").font(.title2.bold()).padding(.horizontal, 20)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(albums.prefix(10)) { item in
                                        NavigationLink(value: item.album) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                AlbumCell(album: item.album)
                                                Text(playsText(item.plays)).font(.caption).foregroundStyle(.secondary)
                                            }
                                            .frame(width: 150)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top titres").font(.title2.bold()).padding(.horizontal, 20)
                        LazyVStack(spacing: 0) {
                            ForEach(Array(topTracks.prefix(25).enumerated()), id: \.element.id) { i, item in
                                HStack(spacing: 10) {
                                    Text("\(i + 1)")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 26)
                                    TrackRow(track: item.track)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .onTapGesture { player.play(top, startAt: i) }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("Mixtape Replay")
    }

    private func header(minutes: Int, plays: Int, artists: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mixtape Replay").font(.headline).foregroundStyle(.white.opacity(0.85))
                Text(periodTitle).font(.title.bold()).foregroundStyle(.white)
            }
            HStack(alignment: .top, spacing: 0) {
                statBlock(value: "\(minutes)", label: minutes > 1 ? "minutes" : "minute")
                statBlock(value: "\(plays)", label: plays > 1 ? "écoutes" : "écoute")
                statBlock(value: "\(artists)", label: artists > 1 ? "artistes" : "artiste")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color.accentPink, .purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func statBlock(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.subheadline).foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var periodTitle: String {
        let now = Date()
        switch period {
        case .month:
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = "LLLL yyyy"
            let text = f.string(from: now)
            return text.prefix(1).uppercased() + text.dropFirst()
        case .year:
            return String(Calendar.current.component(.year, from: now))
        case .all:
            return "Depuis le début"
        }
    }

    private func playsText(_ n: Int) -> String { "\(n) écoute\(n > 1 ? "s" : "")" }

    /// Nombre d'écoutes par son sur la période choisie.
    private func playCounts() -> [String: Int] {
        if period == .all { return stats.playCounts.filter { $0.value > 0 } }
        let calendar = Calendar.current
        let component: Calendar.Component = period == .month ? .month : .year
        guard let start = calendar.dateInterval(of: component, for: Date())?.start.timeIntervalSince1970 else { return [:] }
        var counts: [String: Int] = [:]
        for event in stats.history {
            if event.date < start { break }
            counts[event.trackId, default: 0] += 1
        }
        return counts
    }

    private func rankedArtists(_ tracks: [RankedTrack]) -> [RankedArtist] {
        var byName: [String: Int] = [:]
        for item in tracks { byName[item.track.displayArtist, default: 0] += item.plays }
        return byName
            .compactMap { name, n in library.artist(named: name).map { RankedArtist(artist: $0, plays: n) } }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.artist.name < $1.artist.name }
    }

    private func rankedAlbums(_ tracks: [RankedTrack]) -> [RankedAlbum] {
        var byKey: [String: Int] = [:]
        for item in tracks { byKey[item.track.albumKey, default: 0] += item.plays }
        return byKey
            .compactMap { key, n in library.album(id: key).map { RankedAlbum(album: $0, plays: n) } }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.album.name < $1.album.name }
    }
}

/// Carte « Mixtape Replay » de l'accueil.
struct ReplayCard: View {
    var body: some View {
        NavigationLink(value: LibrarySection.replay) {
            HStack(spacing: 14) {
                Image(systemName: "chart.bar.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mixtape Replay").font(.headline)
                    Text("Ton top du mois, de l'année et de tout le temps").font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }
}
