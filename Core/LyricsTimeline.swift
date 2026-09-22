import Foundation

/// 小工具的顯示模式
enum LyricsTimelineMode: String, Codable, Sendable {
    /// App 每換一句就請系統重新整理：只顯示目前句 + 下一句
    case perLine
    /// 系統節流時：顯示目前句 + 之後兩句，讓使用者看到有上下文的一段
    case paragraph
}

/// App 交給小工具的「整首歌時間軸」。
/// 小工具依時間建立每一句的 entry；系統不一定逐句採用（Apple 建議 entry 間隔約 5 分鐘以上），
/// 所以 App 也會在換句時請系統重新整理（見 `WidgetReloadPolicy`）。
struct LyricsTimelineSnapshot: Codable, Equatable, Sendable {
    var trackID: String
    var title: String
    var artist: String
    /// 已套用延遲設定之前的原始時間碼
    var lines: [LyricLine]
    /// 歌曲 0 秒對應的時刻（已把「歌詞提前」算進去）
    var songStart: Date
    var isPlaying: Bool
    /// 沒有同步歌詞或沒在播放時要顯示的文字
    var message: String?
    var updatedAt: Date
    /// 產生這份時間軸時套用的延遲總和（去重用：±0.25 秒也必須算不同）
    var appliedOffset: TimeInterval = 0
    /// 歌曲長度（秒）；0 = 未知
    var duration: TimeInterval = 0
    var mode: LyricsTimelineMode = .perLine
    /// App Group 裡的小張封面檔名
    var artworkFile: String?

    static func idle(_ message: String, at date: Date = Date()) -> LyricsTimelineSnapshot {
        LyricsTimelineSnapshot(trackID: "", title: "CarLyrics", artist: "", lines: [],
                               songStart: date, isPlaying: false, message: message, updatedAt: date)
    }

    /// 歌曲進度條的範圍（播放中且知道長度時才有）。
    /// 注意：`songStart` 含延遲，進度條用去掉延遲的真實起點。
    var playbackInterval: ClosedRange<Date>? {
        guard isPlaying, duration > 0 else { return nil }
        let start = songStart.addingTimeInterval(appliedOffset)
        return start...start.addingTimeInterval(duration)
    }

    /// 內容相同、起點相差不到 0.3 秒 → 不必重新載入
    func isSameTimeline(as other: LyricsTimelineSnapshot) -> Bool {
        trackID == other.trackID && lines == other.lines && isPlaying == other.isPlaying
            && message == other.message && title == other.title && mode == other.mode
            && appliedOffset == other.appliedOffset && artworkFile == other.artworkFile
            && abs(songStart.timeIntervalSince(other.songStart)) < 0.3
    }

    /// 從 `now` 開始的畫面：第一個是現在，之後每換一句一個
    func frames(from now: Date, limit: Int = 150) -> [LyricsTimelineFrame] {
        guard isPlaying, !lines.isEmpty else {
            return [LyricsTimelineFrame(date: now, index: nil,
                                        current: message ?? title,
                                        upcoming: [message == nil ? artist : title].filter { !$0.isEmpty })]
        }
        let position = now.timeIntervalSince(songStart)
        let currentIndex = lines.index(at: position)
        var result = [frame(at: now, index: currentIndex)]
        let start = (currentIndex ?? -1) + 1
        guard start < lines.count else { return result }
        for j in start..<min(lines.count, start + limit) {
            result.append(frame(at: songStart.addingTimeInterval(lines[j].time), index: j))
        }
        return result
    }

    private var upcomingCount: Int { mode == .paragraph ? 2 : 1 }

    private func frame(at date: Date, index: Int?) -> LyricsTimelineFrame {
        let from = (index ?? -1) + 1
        let upcoming = lines[min(from, lines.count)..<min(lines.count, from + upcomingCount)]
            .map(\.text).filter { !$0.isEmpty }
        guard let index else {
            return LyricsTimelineFrame(date: date, index: nil, current: "♪ \(title)", upcoming: upcoming)
        }
        let text = lines[index].text
        return LyricsTimelineFrame(date: date, index: index, current: text.isEmpty ? "♪" : text, upcoming: upcoming)
    }
}

struct LyricsTimelineFrame: Equatable, Sendable {
    let date: Date
    let index: Int?
    let current: String
    /// 之後要唱的句子（逐句模式 1 句、段落模式 2 句）
    let upcoming: [String]

    var next: String { upcoming.first ?? "" }
}
