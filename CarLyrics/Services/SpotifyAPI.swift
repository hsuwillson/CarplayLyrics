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

    /// 樂觀更新用：複製一份並改變進度 / 播放狀態
    func with(progress: TimeInterval? = nil, isPlaying: Bool? = nil) -> NowPlaying {
        NowPlaying(trackID: trackID, title: title, artist: artist, primaryArtist: primaryArtist,
                   album: album, duration: duration, progress: progress ?? self.progress,
                   isPlaying: isPlaying ?? self.isPlaying)
    }
}

enum PlayerPollResult {
    /// `sentAt`：請求送出的時間，用來丟掉比較舊的回應
    case playing(NowPlaying, measuredAt: Date, sentAt: Date)
    case nothing
    case rateLimited(retryAfter: TimeInterval, quotaExceeded: Bool)
}

enum SpotifyAPIError: LocalizedError {
    case http(Int, String)
    case forbidden(String)
    case noActiveDevice

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Spotify API 錯誤（HTTP \(code)）\(body)"
        case .forbidden(let body): return "Spotify 拒絕這個操作（需要 Premium 或重新登入）\(body)"
        case .noActiveDevice: return "找不到正在播放的 Spotify 裝置"
        }
    }
}

enum PlayerCommand {
    case previous, next, play, pause
    /// 從頭播放目前這首歌
    case restart
    /// 跳到指定位置（毫秒）
    case seek(ms: Int)

    var name: String {
        switch self {
        case .previous: return "previous"
        case .next: return "next"
        case .play: return "play"
        case .pause: return "pause"
        case .restart: return "restart"
        case .seek(let ms): return "seek \(ms)ms"
        }
    }

    var method: String {
        switch self {
        case .previous, .next: return "POST"
        case .play, .pause, .restart, .seek: return "PUT"
        }
    }

    var path: String {
        switch self {
        case .restart: return "seek?position_ms=0"
        case .seek(let ms): return "seek?position_ms=\(max(0, ms))"
        default: return name
        }
    }
}

/// GET /v1/me/player/currently-playing
@MainActor
final class SpotifyAPI {
    private let auth: SpotifyAuth
    /// 最近一次輪詢回應大小（bytes），顯示在除錯頁
    private(set) var lastResponseBytes = 0

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    /// 播放控制：上一首 / 下一首 / 播放 / 暫停
    func send(_ command: PlayerCommand) async throws {
        try await send(command, retryOn401: true)
    }

    private func send(_ command: PlayerCommand, retryOn401: Bool) async throws {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/\(command.path)")!)
        request.httpMethod = command.method
        request.httpBody = Data()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
        switch status {
        case 200...204:
            return
        case 401 where retryOn401:
            try await auth.refresh()
            try await send(command, retryOn401: false)
        case 403:
            throw SpotifyAPIError.forbidden(body)
        case 404:
            throw SpotifyAPIError.noActiveDevice
        default:
            throw SpotifyAPIError.http(status, body)
        }
    }

    /// 播放佇列的下一首（用來預先載入歌詞）；失敗時回傳 nil
    func nextInQueue() async -> NowPlaying? {
        guard let token = try? await auth.validAccessToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/queue?market=from_token")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(QueueResponse.self, from: result.0),
              let item = r.queue.first, let id = item.id else { return nil }
        let artists = item.artists?.map(\.name) ?? []
        return NowPlaying(trackID: id, title: item.name, artist: artists.joined(separator: ", "),
                          primaryArtist: artists.first ?? "", album: item.album?.name ?? "",
                          duration: TimeInterval(item.duration_ms) / 1000, progress: 0, isPlaying: false)
    }

    /// `fullPlayer = true` 時改用 GET /v1/me/player（currently-playing 回傳過期資料時的備援）
    func currentlyPlaying(fullPlayer: Bool = false) async throws -> PlayerPollResult {
        try await currentlyPlaying(fullPlayer: fullPlayer, retryOn401: true)
    }

    private func currentlyPlaying(fullPlayer: Bool, retryOn401: Bool) async throws -> PlayerPollResult {
        let token = try await auth.validAccessToken()
        let path = fullPlayer ? "me/player" : "me/player/currently-playing"
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/\(path)?additional_types=track&market=from_token")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let sent = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let received = Date()
        lastResponseBytes = data.count
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
            return .playing(np, measuredAt: measuredAt, sentAt: sent)

        case 204:
            return .nothing

        case 401 where retryOn401:
            try await auth.refresh()
            return try await currentlyPlaying(fullPlayer: fullPlayer, retryOn401: false)

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

private struct QueueResponse: Decodable {
    let queue: [CurrentlyPlayingResponse.Item]
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
