import Foundation

/// 播放器客戶端（方便以假物件測試 / 替換）
protocol PlayerClient: Sendable {
    func currentlyPlaying(fullPlayer: Bool) async throws -> PlayerPollResponse
    func send(_ command: PlayerCommand) async throws
    func nextInQueue() async -> NowPlaying?
}

/// 一次輪詢的結果 + 回應大小（診斷用）
struct PlayerPollResponse: Sendable {
    let result: PlayerPollResult
    let bytes: Int
}

/// Spotify Web API（不在主執行緒解碼 JSON）
final class SpotifyAPI: PlayerClient, @unchecked Sendable {
    private let auth: SpotifyAuth
    private let session: URLSession = .shared

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    private func token() async throws -> String {
        try await auth.validAccessToken()
    }

    private func refresh() async throws {
        _ = try await auth.refresh()
    }

    /// 播放控制：上一首 / 下一首 / 播放 / 暫停 / 拖動
    func send(_ command: PlayerCommand) async throws {
        try await send(command, retryOn401: true)
    }

    private func send(_ command: PlayerCommand, retryOn401: Bool) async throws {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/\(command.path)")!)
        request.httpMethod = command.method
        request.httpBody = Data()
        let accessToken = try await token()
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
        switch status {
        case 200...204:
            return
        case 401 where retryOn401:
            try await refresh()
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
        guard let accessToken = try? await token() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/queue?market=from_token")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return SpotifyResponseParser.parseQueueFirst(data)
    }

    /// `fullPlayer = true` 時改用 GET /v1/me/player（currently-playing 回傳過期資料時的備援）
    func currentlyPlaying(fullPlayer: Bool) async throws -> PlayerPollResponse {
        try await currentlyPlaying(fullPlayer: fullPlayer, retryOn401: true)
    }

    private func currentlyPlaying(fullPlayer: Bool, retryOn401: Bool) async throws -> PlayerPollResponse {
        let path = fullPlayer ? "me/player" : "me/player/currently-playing"
        // additional_types=episode：Podcast 也回傳 currently_playing_type，才能顯示「Podcast 播放中」
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/\(path)?additional_types=track,episode&market=from_token")!)
        let accessToken = try await token()
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // 同步引擎用單調時鐘
        let sent = AppClock.now()
        let (data, response) = try await session.data(for: request)
        let received = AppClock.now()
        guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.http(0, "") }

        switch http.statusCode {
        case 200:
            // 以請求來回時間的中點當作進度成立的時刻
            let measuredAt = sent.addingTimeInterval(received.timeIntervalSince(sent) / 2)
            let result = try SpotifyResponseParser.parsePlayer(data, measuredAt: measuredAt, sentAt: sent)
            return PlayerPollResponse(result: result, bytes: data.count)

        case 204:
            return PlayerPollResponse(result: .nothing, bytes: 0)

        case 401 where retryOn401:
            try await refresh()
            return try await currentlyPlaying(fullPlayer: fullPlayer, retryOn401: false)

        case 429:
            let retry = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            let body = String(data: data, encoding: .utf8) ?? ""
            return PlayerPollResponse(result: .rateLimited(retryAfter: retry, quotaExceeded: body.contains("QUOTA_EXCEEDED")),
                                      bytes: data.count)

        default:
            let body = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
            throw SpotifyAPIError.http(http.statusCode, body)
        }
    }
}
