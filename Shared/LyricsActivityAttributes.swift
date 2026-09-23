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
        /// 再下一句（鎖定畫面的第二句預告；舊版內容沒有這個欄位 → nil）
        var nextLine2: String?
        /// 目前句的起訖真實時刻（逐句進度條由系統自己推進；舊版內容沒有 → nil）
        var lineStartAt: Date?
        var lineEndAt: Date?

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
            nextLine2 = m.nextLine2
            lineStartAt = m.lineStartAt
            lineEndAt = m.lineEndAt
        }

        var model: ActivityContentModel {
            ActivityContentModel(currentLine: currentLine, nextLine: nextLine, trackName: trackName,
                                 artistName: artistName, isPlaying: isPlaying, songStart: songStart,
                                 songEnd: songEnd, artworkFile: artworkFile, nextLineAt: nextLineAt,
                                 nextLine2: nextLine2, lineStartAt: lineStartAt, lineEndAt: lineEndAt)
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

        /// 目前句的進度區間（系統自己推進；暫停或沒有時刻時 nil）
        var lineProgressInterval: ClosedRange<Date>? { model.lineProgressInterval }
    }

    /// 每次啟動 Live Activity 的識別碼
    var sessionID: String
}
