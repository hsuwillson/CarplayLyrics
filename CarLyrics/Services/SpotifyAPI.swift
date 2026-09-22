import Foundation

struct NowPlaying: Equatable {
    let trackID: String
    let title: String
    let artist: String
    let primaryArtist: String
    let album: String
    let duration: TimeInterval
    let progress: TimeInterval
    let isPlaying: Bool
}

enum PlayerPollResult {
    case playing(NowPlaying, measuredAt: Date)
    case nothing
    case rateLimited(retryAfter: TimeInterval, quotaExceeded: Bool)
}

enum SpotifyAPIError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Spotify API 錯誤（HTTP \(code)）\(body)"
        }
    }
}

/// GET /v1/me/player/currently-playing
@MainActor
final class SpotifyAPI {
    private let auth: SpotifyAuth

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    func currentlyPlaying() async throws -> PlayerPollResult {
        try await currentlyPlaying(retryOn401: true)
    }

    private func currentlyPlaying(retryOn401: Bool) async throws -> PlayerPollResult {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing?additional_types=track")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let sent = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let received = Date()
        guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.http(0, "") }

        switch http.statusCode {
        case 200:
            let r = try JSONDecoder().decode(CurrentlyPlayingResponse.self, from: data)
            guard let item = r.item, let id = item.id else { return .nothing }
            let artists = item.artists?.map(\.name) ?? []
            let np = NowPlaying(
                trackID: id,
                title: item.name,
                artist: artists.joined(separator: ", "),
                primaryArtist: artists.first ?? "",
                album: item.album?.name ?? "",
                duration: TimeInterval(item.duration_ms) / 1000,
                progress: TimeInterval(r.progress_ms ?? 0) / 1000,
                isPlaying: r.is_playing
            )
            // 以請求來回時間的中點當作進度成立的時刻
            let measuredAt = sent.addingTimeInterval(received.timeIntervalSince(sent) / 2)
            return .playing(np, measuredAt: measuredAt)

        case 204:
            return .nothing

        case 401 where retryOn401:
            try await auth.refresh()
            return try await currentlyPlaying(retryOn401: false)

        case 429:
            let retry = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            let body = String(data: data, encoding: .utf8) ?? ""
            return .rateLimited(retryAfter: retry, quotaExceeded: body.contains("QUOTA_EXCEEDED"))

        default:
            let body = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
            throw SpotifyAPIError.http(http.statusCode, body)
        }
    }
}

private struct CurrentlyPlayingResponse: Decodable {
    let is_playing: Bool
    let progress_ms: Int?
    let item: Item?

    struct Item: Decodable {
        let id: String?
        let name: String
        let duration_ms: Int
        let album: Album?
        let artists: [Artist]?
    }

    struct Album: Decodable {
        let name: String
    }

    struct Artist: Decodable {
        let name: String
    }
}
