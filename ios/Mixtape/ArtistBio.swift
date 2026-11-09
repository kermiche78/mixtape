import Foundation
import SwiftUI
import Translation

/// Petit résumé de chaque artiste. On identifie d'abord l'artiste avec précision
/// (MusicBrainz, la base de données de référence de la musique, reliée à Wikidata),
/// puis on prend le résumé de SA page Wikipédia en français. Sinon : la biographie de
/// TheAudioDB, puis Wikipédia en anglais, puis une recherche par nom en dernier recours.
/// Gardé sur l'iPhone : il s'affiche aussi hors ligne, et n'est cherché qu'une fois.
@MainActor
final class ArtistBios: ObservableObject {
    static let shared = ArtistBios()

    struct Bio: Codable {
        var text: String        // vide = rien trouvé
        var url: String?
        var lang: String
        var fetched: Double
        var source: String?     // « Wikipédia », « TheAudioDB »…
        var translated: String? // version française, traduite sur l'iPhone quand le texte est en anglais

        var shownText: String { translated ?? text }
    }

    @Published private(set) var bios: [String: Bio] = [:]
    private var loading: Set<String> = []
    private let key = "artistBios3"

    private init() {
        // Anciennes versions : certains artistes étaient notés « rien trouvé » à tort.
        UserDefaults.standard.removeObject(forKey: "artistBios")
        UserDefaults.standard.removeObject(forKey: "artistBios2")
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
        if let b = bios[id], !b.text.isEmpty || Date().timeIntervalSince1970 - b.fetched < 86400 { return }
        guard !loading.contains(id) else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        guard let found = await Self.find(name) else { return }   // pas de réseau : on réessaiera
        bios[id] = found
        save()
    }

    /// Garde la traduction française (faite une seule fois).
    func setTranslation(_ name: String, _ text: String) {
        let id = name.lowercased()
        guard var b = bios[id], !text.isEmpty else { return }
        b.translated = text
        bios[id] = b
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bios) { UserDefaults.standard.set(data, forKey: key) }
    }

    // MARK: Recherche

    /// nil = rien n'a répondu (pas de réseau) ; Bio avec texte vide = rien trouvé.
    private static func find(_ name: String) async -> Bio? {
        var reachable = false
        let now = Date().timeIntervalSince1970

        // 1. TheAudioDB : biographie écrite pour la musique (et souvent l'identifiant MusicBrainz).
        let audio = await audioDB(name)
        if audio != nil { reachable = true }

        // 2. L'identifiant exact de l'artiste (MusicBrainz), puis sa fiche Wikidata.
        var mbid = audio?.mbid
        if mbid == nil, let found = await musicBrainzSearch(name) { reachable = true; mbid = found }
        var links: [String: String] = [:]
        if let mbid, let qid = await wikidataID(mbid: mbid) {
            reachable = true
            links = await wikipediaTitles(qid: qid)
        }

        // 3. Dans l'ordre : Wikipédia FR de cet artiste précis, TheAudioDB FR,
        //    Wikipédia EN de cet artiste, TheAudioDB EN.
        if let title = links["fr"], case .found(let s) = await summary(lang: "fr", title: title), let bio = clean(s, lang: "fr") {
            return bio
        }
        if let fr = audio?.fr { return Bio(text: fr, url: audio?.page, lang: "fr", fetched: now, source: "TheAudioDB") }
        if let title = links["en"], case .found(let s) = await summary(lang: "en", title: title), let bio = clean(s, lang: "en") {
            return bio
        }
        if let en = audio?.en { return Bio(text: en, url: audio?.page, lang: "en", fetched: now, source: "TheAudioDB") }

        // 4. Dernier recours : deviner la page Wikipédia par le nom.
        switch await guessWikipedia(name) {
        case .some(let bio?): return bio
        case .some(nil): reachable = true
        case nil: break
        }
        return reachable ? Bio(text: "", url: nil, lang: "", fetched: now, source: nil) : nil
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 10
        // MusicBrainz et Wikipédia demandent qu'on se présente.
        // (Wikipédia refuse les applis qui ne donnent pas d'adresse de contact.)
        let agent = "Mixtape/1.0 (+https://github.com/kermiche78/mixtape)"
        r.setValue(agent, forHTTPHeaderField: "User-Agent")
        r.setValue(agent, forHTTPHeaderField: "Api-User-Agent")
        return r
    }

    private static func json(_ url: URL?) async -> [String: Any]? {
        guard let url,
              let (data, response) = try? await URLSession.shared.data(for: request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? s
    }

    // TheAudioDB (clé publique gratuite « 123 »)
    private struct AudioDBResult { var fr: String?; var en: String?; var mbid: String?; var page: String? }

    private static func audioDB(_ name: String) async -> AudioDBResult? {
        guard let obj = await json(URL(string: "https://www.theaudiodb.com/api/v1/json/123/search.php?s=\(q(name))")) else { return nil }
        let artists = obj["artists"] as? [[String: Any]] ?? []
        guard let a = artists.first(where: { fold($0["strArtist"] as? String ?? "") == fold(name) }) else {
            return AudioDBResult()
        }
        func text(_ k: String) -> String? {
            let t = (a[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > 40 ? t : nil
        }
        let mbid = (a["strMusicBrainzID"] as? String).flatMap { $0.count == 36 ? $0 : nil }
        let page = (a["idArtist"] as? String).map { "https://www.theaudiodb.com/artist/\($0)" }
        return AudioDBResult(fr: text("strBiographyFR"), en: text("strBiographyEN"), mbid: mbid, page: page)
    }

    // MusicBrainz : l'artiste dont le nom est exactement celui-là, avec le meilleur score.
    private static func musicBrainzSearch(_ name: String) async -> String? {
        let query = "artist:\"\(name.replacingOccurrences(of: "\"", with: ""))\""
        guard let obj = await json(URL(string: "https://musicbrainz.org/ws/2/artist/?fmt=json&limit=5&query=\(q(query))")),
              let artists = obj["artists"] as? [[String: Any]] else { return nil }
        let exact = artists.filter { a in
            let names = [a["name"] as? String, a["sort-name"] as? String].compactMap { $0 }
                + ((a["aliases"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [])
            return names.contains { fold($0) == fold(name) } && (a["score"] as? Int ?? 0) >= 90
        }
        return exact.first?["id"] as? String
    }

    private static func wikidataID(mbid: String) async -> String? {
        guard let obj = await json(URL(string: "https://musicbrainz.org/ws/2/artist/\(mbid)?inc=url-rels&fmt=json")),
              let rels = obj["relations"] as? [[String: Any]] else { return nil }
        for r in rels where (r["type"] as? String) == "wikidata" {
            if let res = (r["url"] as? [String: Any])?["resource"] as? String, let qid = res.split(separator: "/").last {
                return String(qid)
            }
        }
        return nil
    }

    private static func wikipediaTitles(qid: String) async -> [String: String] {
        guard let obj = await json(URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(qid).json")),
              let entities = obj["entities"] as? [String: Any],
              let entity = entities.values.first as? [String: Any],
              let sitelinks = entity["sitelinks"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for lang in ["fr", "en"] {
            if let title = (sitelinks["\(lang)wiki"] as? [String: Any])?["title"] as? String { out[lang] = title }
        }
        return out
    }

    // Wikipédia
    private struct Summary: Decodable {
        struct Links: Decodable { struct Page: Decodable { let page: String? }; let mobile: Page?; let desktop: Page? }
        let type: String?
        let title: String?
        let description: String?
        let extract: String?
        let content_urls: Links?
    }

    private enum Result { case found(Summary), missing, unreachable }

    private static func summary(lang: String, title: String) async -> Result {
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? title
        guard let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(path)") else { return .missing }
        guard let (data, response) = try? await URLSession.shared.data(for: request(url)),
              let http = response as? HTTPURLResponse else { return .unreachable }
        // 404 = la page n'existe pas. Toute autre erreur (refus, surcharge…) : on réessaiera plus tard,
        // sans noter l'artiste comme « introuvable ».
        if http.statusCode == 404 { return .missing }
        guard http.statusCode == 200, let s = try? JSONDecoder().decode(Summary.self, from: data) else { return .unreachable }
        return .found(s)
    }

    private static func clean(_ s: Summary, lang: String) -> Bio? {
        guard s.type != "disambiguation", let extract = s.extract, extract.count > 40 else { return nil }
        return Bio(text: extract, url: s.content_urls?.mobile?.page ?? s.content_urls?.desktop?.page,
                   lang: lang, fetched: Date().timeIntervalSince1970, source: "Wikipédia")
    }

    /// Mots qui montrent que la page parle bien d'un artiste de musique (et pas d'un mot courant).
    private static let musicWords = [
        "rappeur", "rappeuse", "chanteur", "chanteuse", "musicien", "musicienne", "groupe", "producteur", "productrice",
        "compositeur", "beatmaker", "disc jockey", " dj ", " rap ", "hip-hop", "hip hop", "drill",
        "rapper", "singer", "musician", " band", "record producer", "songwriter", "album", "mixtape", "label",
    ]

    /// nil = Wikipédia injoignable ; .some(nil) = rien trouvé.
    private static func guessWikipedia(_ name: String) async -> Bio?? {
        var reachable = false
        let tries: [(lang: String, titles: [String])] = [
            ("fr", ["\(name) (rappeur)", "\(name) (rappeuse)", "\(name) (chanteur)", "\(name) (chanteuse)",
                    "\(name) (musicien)", "\(name) (groupe)", name]),
            ("en", ["\(name) (rapper)", "\(name) (musician)", "\(name) (singer)", "\(name) (band)", name]),
        ]
        for t in tries {
            for title in t.titles {
                switch await summary(lang: t.lang, title: title) {
                case .unreachable: continue
                case .missing: reachable = true
                case .found(let s):
                    reachable = true
                    guard let bio = clean(s, lang: t.lang), let found = s.title, fold(found).hasPrefix(fold(name)) else { continue }
                    let about = " " + fold((s.description ?? "") + " " + bio.text.prefix(300)) + " "
                    if musicWords.contains(where: { about.contains($0) }) { return .some(bio) }
                }
            }
        }
        return reachable ? .some(nil) : nil
    }
}

/// Section « À propos » en bas de la page d'un artiste.
struct ArtistAboutSection: View {
    @ObservedObject private var bios = ArtistBios.shared
    let name: String

    var body: some View {
        // Toujours au moins une vue (même vide) : sinon SwiftUI ne lance jamais la recherche.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if let bio = bios.bio(for: name) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("À propos").font(.title3.bold())
                    AlbumDescription(title: name, text: bio.shownText)
                    if let link = bio.url, let url = URL(string: link) {
                        Link(destination: url) {
                            Text("Source : \(bio.source ?? "Wikipédia")\(bio.lang == "en" ? (bio.translated != nil ? " · traduit de l'anglais" : " (en anglais)") : "")")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .modifier(TranslateBio(name: name, bio: bio))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: name) { await bios.load(name) }
    }
}

/// Résumé en anglais : traduit en français sur l'iPhone (traduction d'Apple, sans serveur).
private struct TranslateBio: ViewModifier {
    let name: String
    let bio: ArtistBios.Bio

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), bio.lang == "en", bio.translated == nil {
            content.modifier(TranslateBioTask(name: name, text: bio.text))
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct TranslateBioTask: ViewModifier {
    let name: String
    let text: String
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onAppear {
                config = TranslationSession.Configuration(source: Locale.Language(identifier: "en"),
                                                          target: Locale.Language(identifier: "fr"))
            }
            .translationTask(config) { session in
                guard let result = try? await session.translate(text) else { return }
                let french = result.targetText
                await MainActor.run { ArtistBios.shared.setTranslation(name, french) }
            }
    }
}
