import Foundation

struct SpotifyRateLimitError: LocalizedError, Equatable, Sendable {
    let retryAfter: TimeInterval
    let quotaExceeded: Bool
    var errorDescription: String? { "Spotify 暫時限制查詢，請於 \(Int(ceil(retryAfter))) 秒後重試。" }
}

/// 同一個 API client 的輪詢、控制與佇列共用限流期限。
/// 冷卻期間直接回報錯誤，避免把播放控制排隊到幾分鐘後才執行。
actor SpotifyHTTPTransport {
    typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let sender: Sender
    private let now: @Sendable () -> Date
    private var cooldown = RequestCooldown()
    private var quotaExceeded = false

    init(now: @escaping @Sendable () -> Date = { AppClock.now() },
         sender: @escaping Sender = { try await URLSession.shared.data(for: $0) }) {
        self.now = now
        self.sender = sender
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let remaining = cooldown.remaining(at: now())
        guard remaining == 0 else {
            throw SpotifyRateLimitError(retryAfter: remaining, quotaExceeded: quotaExceeded)
        }
        let (data, response) = try await sender(request)
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            let value = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            let retry = value.isFinite && value > 0 ? value : 5
            let quota = String(data: data, encoding: .utf8)?.contains("QUOTA_EXCEEDED") == true
            if cooldown.remaining(at: now()) == 0 { quotaExceeded = false }
            quotaExceeded = quotaExceeded || quota
            cooldown.impose(seconds: retry, now: now())
            throw SpotifyRateLimitError(retryAfter: cooldown.remaining(at: now()), quotaExceeded: quotaExceeded)
        }
        return (data, response)
    }
}
