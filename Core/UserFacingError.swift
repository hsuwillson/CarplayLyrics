import Foundation

/// 顯示給使用者看的錯誤：中文標題、說明與建議動作。
/// 原始的英文錯誤只寫進診斷紀錄，不直接放上畫面。
enum UserFacingError: Error, Equatable, Sendable {
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
        case relogin, retry, none
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
        case .spotifyForbidden: return "Spotify 現在不允許這個操作"
        case .spotifyNoDevice: return "找不到播放中的裝置"
        case .spotifyServer: return "Spotify 暫時無法回應"
        case .rateLimited, .quotaExceeded: return "Spotify 暫時限制查詢"
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
        case .spotifyForbidden: return "例如廣告時不能跳過，或這個操作需要 Spotify Premium。稍後再試。"
        case .spotifyNoDevice: return "請先在 Spotify 開始播放。"
        case .spotifyServer: return "Spotify 暫時沒有回應，稍後會自動重試。"
        case .rateLimited(let s): return "\(s) 秒後自動恢復。"
        case .quotaExceeded: return "已自動放慢更新，約一小時後恢復；歌詞仍照時間顯示。"
        case .missingControlScope: return "要使用播放按鈕，需要重新登入並允許「控制播放」。"
        case .lyricsUnavailable: return "歌詞網站暫時連不上，網路恢復後會自動重試。"
        // 原始訊息（英文 / 代碼）只寫進診斷紀錄，畫面上給看得懂的說明
        case .loginFailed: return "登入沒有完成，請再試一次；一直失敗的話，到「設定 › 關於 › 診斷」分享紀錄。"
        case .unknown: return "請稍後再試；一直發生的話，到「設定 › 關於 › 診斷」分享紀錄。"
        }
    }

    var action: Action {
        switch self {
        // 403（例如廣告時不能跳過）重新登入也沒用，不要引導使用者去登出登入
        case .spotifyUnauthorized, .missingControlScope: return .relogin
        case .lyricsUnavailable, .timeout, .spotifyServer: return .retry
        default: return .none
        }
    }

    var actionTitle: String? {
        switch action {
        case .relogin: return "重新登入"
        case .retry: return "重試"
        case .none: return nil
        }
    }

    /// 暫時性問題（會自動恢復）用灰色；需要使用者處理的用橘色
    var needsAttention: Bool {
        switch self {
        case .spotifyUnauthorized, .missingControlScope, .loginFailed: return true
        default: return false
        }
    }
}
