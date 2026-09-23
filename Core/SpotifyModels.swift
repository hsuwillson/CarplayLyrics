import Foundation

/// 正在播放的內容（只處理音樂；廣告 / Podcast 另外用 `PlayerPollResult.nonMusic` 表示）
struct NowPlaying: Equatable, Sendable {
    let trackID: String
    let title: String
    let artist: String
    let primaryArtist: String
    let album: String
    let duration: TimeInterval
    let progress: TimeInterval
    let isPlaying: Bool
    /// 專輯封面（約 300 px）
    var artworkURL: URL? = nil
    /// 小張封面（約 64 px），給鎖定畫面 / 小工具
    var smallArtworkURL: URL? = nil

    /// 樂觀更新用：複製一份並改變進度 / 播放狀態
    func with(progress: TimeInterval? = nil, isPlaying: Bool? = nil) -> NowPlaying {
        NowPlaying(trackID: trackID, title: title, artist: artist, primaryArtist: primaryArtist,
                   album: album, duration: duration, progress: progress ?? self.progress,
                   isPlaying: isPlaying ?? self.isPlaying,
                   artworkURL: artworkURL, smallArtworkURL: smallArtworkURL)
    }
}

/// Spotify 正在播、但不是音樂的內容
enum NonMusicKind: String, Equatable, Sendable {
    case ad, episode, unknown

    var label: String {
        switch self {
        case .ad: return "廣告播放中"
        case .episode: return "Podcast 播放中"
        case .unknown: return "正在播放非音樂內容"
        }
    }
}

enum PlayerPollResult: Equatable, Sendable {
    /// `sentAt`：請求送出的時間，用來丟掉比較舊的回應
    case playing(NowPlaying, measuredAt: Date, sentAt: Date)
    /// 廣告 / Podcast：不要清空上一首的歌詞
    case nonMusic(NonMusicKind, isPlaying: Bool)
    case nothing
    case rateLimited(retryAfter: TimeInterval, quotaExceeded: Bool)
}

enum SpotifyAPIError: LocalizedError, Equatable {
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

enum SpotifyAuthError: LocalizedError, Equatable {
    case notLoggedIn
    case cancelled
    case invalidCallback(String)
    case stateMismatch
    case missingRefreshToken
    case tokenRequestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "尚未登入 Spotify"
        case .cancelled: return "已取消登入"
        case .invalidCallback(let m): return "登入回傳異常：\(m)"
        case .stateMismatch: return "登入驗證失敗（state 不符）"
        case .missingRefreshToken: return "Spotify 沒有回傳 refresh token"
        case .tokenRequestFailed(let code, let body): return "取得 token 失敗（HTTP \(code)）\(body)"
        }
    }
}

enum PlayerCommand: Equatable, Sendable {
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

// MARK: - 回應解析（純函式，可單元測試）

enum SpotifyResponseParser {
    /// 解析 GET /me/player 或 /me/player/currently-playing 的 200 回應
    static func parsePlayer(_ data: Data, measuredAt: Date, sentAt: Date) throws -> PlayerPollResult {
        let r = try JSONDecoder().decode(CurrentlyPlayingResponse.self, from: data)
        let type = r.currently_playing_type ?? "track"
        guard type == "track", let item = r.item, let id = item.id else {
            // 本機檔案（沒有 id）或空白回應：當成沒在播放
            if type == "track" { return .nothing }
            let kind: NonMusicKind = type == "ad" ? .ad : type == "episode" ? .episode : .unknown
            return .nonMusic(kind, isPlaying: r.is_playing)
        }
        return .playing(nowPlaying(item, id: id, progressMs: r.progress_ms ?? 0, isPlaying: r.is_playing),
                        measuredAt: measuredAt, sentAt: sentAt)
    }

    /// 解析 GET /me/player/queue：整個佇列（跳過沒有 id 的項目，例如本機檔案 / Podcast）
    static func parseQueue(_ data: Data) -> [NowPlaying] {
        guard let r = try? JSONDecoder().decode(QueueResponse.self, from: data) else { return [] }
        return r.queue.compactMap { item in
            guard let id = item.id else { return nil }
            return nowPlaying(item, id: id, progressMs: 0, isPlaying: false)
        }
    }

    private static func nowPlaying(_ item: CurrentlyPlayingResponse.Item, id: String, progressMs: Int, isPlaying: Bool) -> NowPlaying {
        let artists = item.artists?.map(\.name) ?? []
        let images = item.album?.images ?? []
        return NowPlaying(
            trackID: id,
            title: item.name,
            artist: artists.joined(separator: ", "),
            primaryArtist: artists.first ?? "",
            album: item.album?.name ?? "",
            duration: TimeInterval(item.duration_ms) / 1000,
            progress: TimeInterval(progressMs) / 1000,
            isPlaying: isPlaying,
            artworkURL: pick(images, target: 300),
            smallArtworkURL: pick(images, target: 64)
        )
    }

    /// 挑最接近 `target` px 的圖（Spotify 通常給 640 / 300 / 64）
    static func pick(_ images: [CurrentlyPlayingResponse.Image], target: Int) -> URL? {
        images.min { abs(($0.width ?? 0) - target) < abs(($1.width ?? 0) - target) }
            .flatMap { URL(string: $0.url) }
    }
}

struct QueueResponse: Decodable {
    let queue: [CurrentlyPlayingResponse.Item]
}

struct CurrentlyPlayingResponse: Decodable {
    let is_playing: Bool
    let progress_ms: Int?
    let currently_playing_type: String?
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
        let images: [Image]?
    }

    struct Image: Decodable {
        let url: String
        let width: Int?
        let height: Int?
    }

    struct Artist: Decodable {
        let name: String
    }
}
