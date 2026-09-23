import Foundation

/// App 目前處於什麼狀態（畫面與 Live Activity 都只看這個）
enum SessionState: Equatable, Sendable {
    case loggedOut
    /// 已登入，還沒拿到第一次輪詢結果
    case connecting
    case notPlaying
    case nonMusic(NonMusicKind)
    case paused
    case playing

    var isNonMusic: Bool {
        if case .nonMusic = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .loggedOut: return "請先登入 Spotify"
        case .connecting: return "連接 Spotify 中…"
        case .notPlaying: return "Spotify 沒有在播放"
        case .nonMusic(let k): return k.label
        case .paused: return "已暫停"
        case .playing: return "播放中"
        }
    }
}
