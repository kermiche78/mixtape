import Foundation
import SwiftUI

/// Petit résumé de chaque artiste, pris sur Wikipédia (en français, sinon en anglais).
/// Gardé sur l'iPhone : il s'affiche aussi hors ligne, et Wikipédia n'est interrogé qu'une fois.
@MainActor
final class ArtistBios: ObservableObject {
    static let shared = ArtistBios()

    struct Bio: Codable {
        var text: String        // vide = rien trouvé
        var url: String?
        var lang: String
        var fetched: Double
    }

    @Published private(set) var bios: [String: Bio] = [:]
    private var loading: Set<String> = []
    private let key = "artistBios"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: Bio].self, from: data) {
            bios = saved
        }
    }

    func bio(for name: String) -> Bio? {
        guard let b = bios[name.lowercased()], !b.text.isEmpty else { return nil }
        return b
    }

    /// Va chercher le résumé si on ne l'a pas encore (ou réessaie une fois par semaine si rien trouvé).
    func load(_ name: String) async {
        let id = name.lowercased()
        if let b = bios[id], !b.text.isEmpty || Date().timeIntervalSince1970 - b.fetched < 7 * 86400 { return }
        guard !loading.contains(id) else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        guard let found = await Self.find(name) else {
            // Réseau coupé : on ne note rien, on réessaiera.
            return
        }
        bios[id] = found
        if let data = try? JSONEncoder().encode(bios) { UserDefaults.standard.set(data, forKey: key) }
    }

    // MARK: Recherche sur Wikipédia

    private struct Summary: Decodable {
        struct Links: Decodable { struct Page: Decodable { let page: String? }; let mobile: Page?; let desktop: Page? }
        let type: String?
        let title: String?
        let description: String?
        let extract: String?
        let content_urls: Links?
    }

    /// Mots qui montrent que la page parle bien d'un artiste de musique (et pas d'un mot courant).
    private static let musicWords = [
        "rappeur", "rappeuse", "chanteur", "chanteuse", "musicien", "musicienne", "groupe", "producteur", "productrice",
        "compositeur", "beatmaker", "disc jockey", " dj ", " rap ", "hip-hop", "hip hop", "drill",
        "rapper", "singer", "musician", " band", "record producer", "songwriter", "album", "mixtape", "label",
    ]

    /// nil = Wikipédia injoignable ; Bio avec texte vide = rien trouvé.
    private static func find(_ name: String) async -> Bio? {
        var reachable = false
        let tries: [(lang: String, titles: [String], hint: String)] = [
            ("fr", ["\(name) (rappeur)", "\(name) (rappeuse)", "\(name) (chanteur)", "\(name) (chanteuse)",
                    "\(name) (musicien)", "\(name) (groupe)", "\(name) (artiste)", name], "rappeur"),
            ("en", ["\(name) (rapper)", "\(name) (musician)", "\(name) (singer)", "\(name) (band)", name], "rapper"),
        ]
        for t in tries {
            for title in t.titles {
                switch await summary(lang: t.lang, title: title) {
                case .unreachable: continue
                case .missing: reachable = true
                case .found(let s):
                    reachable = true
                    if let bio = accept(s, name: name, lang: t.lang) { return bio }
                }
            }
            // Dernière chance : la recherche de Wikipédia (« Nom rappeur »).
            if let titles = await search(lang: t.lang, query: "\(name) \(t.hint)") {
                reachable = true
                for title in titles.prefix(3) {
                    if case .found(let s) = await summary(lang: t.lang, title: title),
                       let bio = accept(s, name: name, lang: t.lang) { return bio }
                }
            }
        }
        return reachable ? Bio(text: "", url: nil, lang: "", fetched: Date().timeIntervalSince1970) : nil
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func accept(_ s: Summary, name: String, lang: String) -> Bio? {
        guard s.type != "disambiguation", let extract = s.extract, extract.count > 40 else { return nil }
        // Le titre doit commencer par le nom de l'artiste (« Future (rappeur) » oui, « Futur » non).
        guard let title = s.title, fold(title).hasPrefix(fold(name)) else { return nil }
        let about = " " + fold((s.description ?? "") + " " + extract.prefix(300)) + " "
        guard musicWords.contains(where: { about.contains($0) }) else { return nil }
        return Bio(text: extract, url: s.content_urls?.mobile?.page ?? s.content_urls?.desktop?.page,
                   lang: lang, fetched: Date().timeIntervalSince1970)
    }

    private enum Result { case found(Summary), missing, unreachable }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 10
        r.setValue("Mixtape/1.0 (lecteur de musique perso)", forHTTPHeaderField: "Api-User-Agent")
        return r
    }

    private static func summary(lang: String, title: String) async -> Result {
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? title
        guard let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(path)") else { return .missing }
        guard let (data, response) = try? await URLSession.shared.data(for: request(url)),
              let http = response as? HTTPURLResponse else { return .unreachable }
        guard http.statusCode == 200, let s = try? JSONDecoder().decode(Summary.self, from: data) else { return .missing }
        return .found(s)
    }

    private static func search(lang: String, query: String) async -> [String]? {
        var c = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
        c.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "srlimit", value: "3"),
            URLQueryItem(name: "srsearch", value: query),
        ]
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(for: request(url)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let q = obj["query"] as? [String: Any],
              let results = q["search"] as? [[String: Any]] else { return nil }
        return results.compactMap { $0["title"] as? String }
    }
}

/// Section « À propos » en bas de la page d'un artiste.
struct ArtistAboutSection: View {
    @ObservedObject private var bios = ArtistBios.shared
    let name: String

    var body: some View {
        Group {
            if let bio = bios.bio(for: name) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("À propos").font(.title3.bold())
                    AlbumDescription(title: name, text: bio.text)
                    if let link = bio.url, let url = URL(string: link) {
                        Link(destination: url) {
                            Text(bio.lang == "fr" ? "Source : Wikipédia" : "Source : Wikipédia (en anglais)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .task(id: name) { await bios.load(name) }
    }
}
