import Foundation

enum APIError: LocalizedError {
    case badURL
    case unauthorized
    case server(Int)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .badURL: return "Adresse du serveur invalide."
        case .unauthorized: return "Mot de passe incorrect."
        case .server(let code): return "Le serveur a répondu avec une erreur (\(code))."
        case .unreachable: return "Serveur injoignable. Vérifie que le PC est allumé et que Tailscale est activé."
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
