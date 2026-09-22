import Foundation

/// App 交給小工具的「整首歌時間軸」。
/// 小工具依時間自動切換每一句，不需要 App 在背景持續更新
/// （iOS 會擋掉只播放背景音訊的 App 更新 Live Activity，小工具時間軸不受影響）。
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

    static func idle(_ message: String, at date: Date = Date()) -> LyricsTimelineSnapshot {
        LyricsTimelineSnapshot(trackID: "", title: "CarLyrics", artist: "", lines: [],
                               songStart: date, isPlaying: false, message: message, updatedAt: date)
    }

    /// 從 `now` 開始的畫面：第一個是現在，之後每換一句一個
    func frames(from now: Date, limit: Int = 150) -> [LyricsTimelineFrame] {
        guard isPlaying, !lines.isEmpty else {
            return [LyricsTimelineFrame(date: now, index: nil,
                                        current: message ?? title,
                                        next: message == nil ? artist : title)]
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

    private func frame(at date: Date, index: Int?) -> LyricsTimelineFrame {
        guard let index else {
            return LyricsTimelineFrame(date: date, index: nil, current: "♪ \(title)",
                                       next: lines.first?.text ?? "")
        }
        let text = lines[index].text
        return LyricsTimelineFrame(date: date, index: index,
                                   current: text.isEmpty ? "♪" : text,
                                   next: index + 1 < lines.count ? lines[index + 1].text : "")
    }
}

struct LyricsTimelineFrame: Equatable, Sendable {
    let date: Date
    let index: Int?
    let current: String
    let next: String
}
