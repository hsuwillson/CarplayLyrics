import ActivityKit
import Foundation

/// Live Activity 的資料模型（App 與 Extension 共用）。
/// 新增欄位一律是 Optional，舊版送出的內容仍可解碼。
struct LyricsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var currentLine: String
        var nextLine: String
        var trackName: String
        var artistName: String
        var isPlaying: Bool
        /// 播放中：歌曲開始 / 結束的真實時刻，讓系統自己推進進度條
        var songStart: Date?
        var songEnd: Date?
        /// App Group 裡的小張封面檔名
        var artworkFile: String?
        /// 間奏時下一句開始的時刻（畫面自己倒數，不需要更新）
        var nextLineAt: Date?

        init(_ m: ActivityContentModel) {
            currentLine = m.currentLine
            nextLine = m.nextLine
            trackName = m.trackName
            artistName = m.artistName
            isPlaying = m.isPlaying
            songStart = m.songStart
            songEnd = m.songEnd
            artworkFile = m.artworkFile
            nextLineAt = m.nextLineAt
        }

        var model: ActivityContentModel {
            ActivityContentModel(currentLine: currentLine, nextLine: nextLine, trackName: trackName,
                                 artistName: artistName, isPlaying: isPlaying, songStart: songStart,
                                 songEnd: songEnd, artworkFile: artworkFile, nextLineAt: nextLineAt)
        }

        /// 間奏倒數的區間（沒有或已經過了就是 nil）
        func countdownInterval(from date: Date) -> ClosedRange<Date>? {
            guard currentLine.hasPrefix("♪"), let nextLineAt,
                  nextLineAt.timeIntervalSince(date) > LyricsTimelineFrame.countdownThreshold else { return nil }
            return date...nextLineAt
        }

        var playbackInterval: ClosedRange<Date>? {
            guard isPlaying, let songStart, let songEnd, songEnd > songStart else { return nil }
            return songStart...songEnd
        }
    }

    /// 每次啟動 Live Activity 的識別碼
    var sessionID: String
}
