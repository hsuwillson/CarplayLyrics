import Foundation

/// 顯示給使用者看的錯誤：中文標題、說明與建議動作。
/// 原始的英文錯誤只寫進診斷紀錄，不直接放上畫面。
enum UserFacingError: Equatable, Sendable {
    case offline
    case timeout
    case spotifyUnauthorized
    case spotifyForbidden
    case spotifyNoDevice
    case spotifyServer(Int)
    case rateLimited(seconds: Int)
    case quotaExceeded
    case missingControlScope
    case lyricsUnavailable(String)
    case loginFailed(String)
    case unknown(String)

    enum Action: Equatable, Sendable {
        case relogin, retry, openSettings, none
    }

    init(_ error: Error) {
        if let e = error as? UserFacingError { self = e; return }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                self = .offline
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                self = .timeout
            default:
                self = .unknown("網路錯誤（\(e.code.rawValue)）")
            }
            return
        }
        if let e = error as? SpotifyAPIError {
            switch e {
            case .forbidden: self = .spotifyForbidden
            case .noActiveDevice: self = .spotifyNoDevice
            case .http(let code, _):
                self = code == 401 ? .spotifyUnauthorized : .spotifyServer(code)
            }
            return
        }
        if let e = error as? SpotifyAuthError {
            switch e {
            case .notLoggedIn: self = .spotifyUnauthorized
            case .tokenRequestFailed(let code, _) where code == 400 || code == 401: self = .spotifyUnauthorized
            case .tokenRequestFailed(let code, _): self = .spotifyServer(code)
            default: self = .loginFailed(e.localizedDescription)
            }
            return
        }
        self = .unknown(error.localizedDescription)
    }

    var title: String {
        switch self {
        case .offline: return "沒有網路連線"
        case .timeout: return "連線逾時"
        case .spotifyUnauthorized: return "Spotify 登入已失效"
        case .spotifyForbidden: return "Spotify 拒絕這個操作"
        case .spotifyNoDevice: return "找不到播放中的裝置"
        case .spotifyServer: return "Spotify 暫時無法回應"
        case .rateLimited: return "請求太頻繁"
        case .quotaExceeded: return "Spotify API 配額用完"
        case .missingControlScope: return "需要重新授權"
        case .lyricsUnavailable: return "歌詞服務暫時無法使用"
        case .loginFailed: return "登入失敗"
        case .unknown: return "發生錯誤"
        }
    }

    var message: String {
        switch self {
        case .offline: return "恢復連線後會自動繼續同步。"
        case .timeout: return "網路不穩，稍後會自動重試。"
        case .spotifyUnauthorized: return "請重新登入 Spotify。"
        case .spotifyForbidden: return "播放控制需要 Spotify Premium，或請重新登入。"
        case .spotifyNoDevice: return "請先在 Spotify 開始播放。"
        case .spotifyServer(let code): return "伺服器回應 \(code)，稍後會自動重試。"
        case .rateLimited(let s): return "\(s) 秒後自動重試。"
        case .quotaExceeded: return "已降低查詢頻率，一小時後恢復。"
        case .missingControlScope: return "要使用播放按鈕，需要重新登入並允許「控制播放」。"
        case .lyricsUnavailable: return "無法連線到 LRCLIB，可以稍後重試。"
        case .loginFailed(let m): return m
        case .unknown(let m): return m
        }
    }

    var action: Action {
        switch self {
        case .spotifyUnauthorized, .missingControlScope, .spotifyForbidden: return .relogin
        case .lyricsUnavailable, .timeout, .spotifyServer: return .retry
        default: return .none
        }
    }

    var actionTitle: String? {
        switch action {
        case .relogin: return "重新登入"
        case .retry: return "重試"
        case .openSettings: return "開啟設定"
        case .none: return nil
        }
    }

    /// 暫時性問題（會自動恢復）用灰色；需要使用者處理的用橘色
    var needsAttention: Bool {
        switch self {
        case .spotifyUnauthorized, .missingControlScope, .spotifyForbidden, .loginFailed, .quotaExceeded: return true
        default: return false
        }
    }
}
