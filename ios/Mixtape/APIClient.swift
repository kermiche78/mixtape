import Foundation

enum APIError: LocalizedError {
    case badURL
    case unauthorized
    case server(Int)
    case unreachable
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Adresse du serveur invalide."
        case .unauthorized: return "Mot de passe incorrect."
        case .server(let code): return "Le serveur a répondu avec une erreur (\(code))."
        case .unreachable: return "Serveur injoignable. Vérifie que le PC est allumé et que Tailscale est activé."
        case .message(let text): return text
        }
    }
}

struct APIClient {
    let baseURL: URL
    let token: String

    init?(address: String, token: String) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        // Port par défaut du serveur Mixtape si aucun n'est donné.
        if let comps = URLComponents(string: text), comps.port == nil, comps.scheme == "http" {
            text += ":4533"
        }
        guard let url = URL(string: text), url.host != nil else { return nil }
        self.baseURL = url
        self.token = token
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "token", value: token)] + query
        return comps.url!
    }

    private func send(_ path: String, method: String = "GET", json: Encodable? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(json))
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.unreachable }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw APIError.server(http.statusCode) }
        return data
    }

    func ping() async throws {
        _ = try await send("api/ping")
    }

    func tracks() async throws -> [Track] {
        try JSONDecoder().decode([Track].self, from: try await send("api/tracks"))
    }

    func extras() async throws -> LibraryExtras {
        try JSONDecoder().decode(LibraryExtras.self, from: try await send("api/extras"))
    }

    func artistPhotoURL(name: String, version: Int) -> URL {
        url("api/artist-photo", query: [URLQueryItem(name: "name", value: name), URLQueryItem(name: "v", value: String(version))])
    }

    func getBackup() async throws -> Data {
        try await send("api/backup")
    }

    /// Envoie la sauvegarde de l'iPhone au PC.
    func putBackup(_ body: Data) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/backup"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.unreachable }
        guard (200..<300).contains(http.statusCode) else { throw APIError.server(http.statusCode) }
    }

    // MARK: Requêtes avec paramètres, formulaires et codes d'erreur

    private func raw(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                     body: Data? = nil, contentType: String? = nil, timeout: TimeInterval = 15) async throws -> (Data, Int) {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.unreachable }
        if http.statusCode == 401 { throw APIError.unauthorized }
        return (data, http.statusCode)
    }

    private func checked(_ result: (Data, Int)) throws -> Data {
        guard (200..<300).contains(result.1) else {
            // Le serveur explique souvent pourquoi (« Ce son n'est pas rangé dans un dossier d'album… »).
            if let obj = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
               let detail = obj["detail"] as? String {
                throw APIError.message(detail)
            }
            throw APIError.server(result.1)
        }
        return result.0
    }

    private func jsonBody(_ value: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: value)
    }

    private func multipart(_ fields: [String: String], file: Data, fileField: String) -> (Data, String) {
        let boundary = "mixtape-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        for (key, value) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"image.jpg\"\r\n")
        add("Content-Type: image/jpeg\r\n\r\n")
        body.append(file)
        add("\r\n--\(boundary)--\r\n")
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    // MARK: Mode Gestion (tout est enregistré sur le PC)

    func managedAlbum(trackId: String) async throws -> ManagedAlbum {
        let data = try checked(try await raw("api/manage/album", query: [URLQueryItem(name: "trackId", value: trackId)]))
        return try JSONDecoder().decode(ManagedAlbum.self, from: data)
    }

    func setAlbumText(trackId: String, kind: String, text: String) async throws {
        _ = try checked(try await raw("api/manage/album-text", method: "PUT",
                                      body: jsonBody(["trackId": trackId, "kind": kind, "text": text]),
                                      contentType: "application/json"))
    }

    func uploadAlbumCover(trackId: String, jpeg: Data) async throws {
        let (body, type) = multipart(["trackId": trackId], file: jpeg, fileField: "image")
        _ = try checked(try await raw("api/manage/album-cover", method: "POST", body: body, contentType: type, timeout: 60))
    }

    func uploadArtistPhoto(artist: String, jpeg: Data) async throws {
        let (body, type) = multipart(["artist": artist], file: jpeg, fileField: "image")
        _ = try checked(try await raw("api/manage/artist-photo", method: "POST", body: body, contentType: type, timeout: 60))
    }

    func editTrack(trackId: String, title: String, trackNumber: Int?) async throws {
        var fields: [String: Any] = ["trackId": trackId, "title": title]
        if let trackNumber { fields["trackNumber"] = trackNumber } else { fields["clearNumber"] = true }
        _ = try checked(try await raw("api/manage/track", method: "POST", body: jsonBody(fields), contentType: "application/json"))
    }

    func renameAlbum(trackId: String, name: String) async throws {
        _ = try checked(try await raw("api/manage/album-name", method: "POST",
                                      body: jsonBody(["trackId": trackId, "name": name]), contentType: "application/json"))
    }

    // MARK: Annotations « pour tout le monde »

    func annotations() async throws -> [Annotation] {
        try JSONDecoder().decode([Annotation].self, from: try checked(try await raw("api/annotations")))
    }

    func saveAnnotation(_ note: Annotation) async throws -> Annotation {
        var fields: [String: Any] = ["id": note.id, "trackId": note.trackId, "start": note.start, "text": note.text]
        if let end = note.end { fields["end"] = end }
        let data = try checked(try await raw("api/annotations", method: "POST", body: jsonBody(fields), contentType: "application/json"))
        return try JSONDecoder().decode(Annotation.self, from: data)
    }

    func deleteAnnotation(id: String) async throws {
        _ = try checked(try await raw("api/annotations/\(id)", method: "DELETE"))
    }

    // MARK: Écoute à deux

    func partyLink(code: String) -> URL { baseURL.appendingPathComponent("ecoute/\(code)") }

    func partyCreate(_ fields: [String: Any]) async throws -> PartyState {
        let data = try checked(try await raw("api/party", method: "POST", body: jsonBody(fields), contentType: "application/json"))
        return try JSONDecoder().decode(PartyState.self, from: data)
    }

    /// nil = l'écoute n'existe plus sur le PC.
    func partyState(code: String) async throws -> PartyState? {
        let result = try await raw("api/party/\(code)", timeout: 8)
        if result.1 == 404 { return nil }
        return try JSONDecoder().decode(PartyState.self, from: try checked(result))
    }

    /// Envoie l'état de l'iPhone. `conflict` = un invité a changé quelque chose juste avant.
    func partyUpdate(code: String, fields: [String: Any]) async throws -> (state: PartyState?, conflict: Bool) {
        let result = try await raw("api/party/\(code)", method: "PUT", body: jsonBody(fields),
                                   contentType: "application/json", timeout: 8)
        if result.1 == 404 { return (nil, false) }
        if result.1 == 409 { return (try? JSONDecoder().decode(PartyState.self, from: result.0), true) }
        return (try JSONDecoder().decode(PartyState.self, from: try checked(result)), false)
    }

    func partyEnd(code: String) async {
        _ = try? await raw("api/party/\(code)", method: "DELETE", timeout: 8)
    }

    func playlists() async throws -> [Playlist] {
        try JSONDecoder().decode([Playlist].self, from: try await send("api/playlists"))
    }

    func createPlaylist(name: String, trackIds: [String]) async throws -> Playlist {
        let body = PlaylistBody(name: name, trackIds: trackIds)
        return try JSONDecoder().decode(Playlist.self, from: try await send("api/playlists", method: "POST", json: body))
    }

    func updatePlaylist(_ playlist: Playlist) async throws -> Playlist {
        let body = PlaylistBody(name: playlist.name, trackIds: playlist.trackIds)
        return try JSONDecoder().decode(Playlist.self, from: try await send("api/playlists/\(playlist.id)", method: "PUT", json: body))
    }

    func deletePlaylist(id: String) async throws {
        _ = try await send("api/playlists/\(id)", method: "DELETE")
    }

    func streamURL(for track: Track) -> URL {
        url("api/stream/\(track.id).\(track.ext)")
    }

    func coverURL(for track: Track) -> URL? {
        guard track.hasCover else { return nil }
        return url("api/tracks/\(track.id)/cover", query: [URLQueryItem(name: "v", value: String(Int(track.updatedAt)))])
    }
}

private struct PlaylistBody: Encodable {
    let name: String
    let trackIds: [String]
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

struct ManagedAlbum: Decodable {
    let folder: String
    let credits: String
    let description: String
}

struct PartyGuest: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
}

struct PartyState: Decodable, Equatable {
    let code: String
    let queue: [String]
    let index: Int
    let position: Double
    let playing: Bool
    let updatedAt: Double
    let serverTime: Double
    let version: Int
    let by: String
    let mode: String
    let guests: [PartyGuest]
    let addedBy: [String: String]
    let host: String

    /// Position actuelle, en tenant compte du temps écoulé depuis la dernière mise à jour.
    var currentPosition: Double { playing ? position + max(0, serverTime - updatedAt) : position }
}
