import ActivityKit
import Foundation

/// Live Activity 的資料模型（App 與 Extension 共用）。
struct LyricsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var currentLine: String
        var nextLine: String
        var trackName: String
        var artistName: String
        var isPlaying: Bool
    }

    /// 每次啟動 Live Activity 的識別碼
    var sessionID: String
}
