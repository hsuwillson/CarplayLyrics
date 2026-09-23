import Foundation

/// 小工具的顯示模式
enum LyricsTimelineMode: String, Codable, Sendable {
    /// App 每換一句就請系統重新整理：只顯示目前句 + 下一句
    case perLine
    /// 系統節流時：每一格涵蓋一個時間窗（目前句 + 這段時間內會開始的幾句），
    /// 系統晚十幾秒才顯示這一格也還找得到正在唱的句子
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

    /// 畫面不會隨時間改變（沒在播放、或沒有同步歌詞）→ 起點是多少都不影響顯示
    var isStatic: Bool { !isPlaying || lines.isEmpty }

    /// 內容相同、起點相差不到 0.3 秒 → 不必重新載入
    func isSameTimeline(as other: LyricsTimelineSnapshot) -> Bool {
        guard trackID == other.trackID, lines == other.lines, isPlaying == other.isPlaying,
              message == other.message, title == other.title, mode == other.mode,
              appliedOffset == other.appliedOffset, artworkFile == other.artworkFile else { return false }
        return isStatic || abs(songStart.timeIntervalSince(other.songStart)) < 0.3
    }

    /// 內容相同但起點漂移了（只要重寫檔案，不必請系統重新整理）
    func needsFileRefresh(comparedTo other: LyricsTimelineSnapshot) -> Bool {
        guard !isStatic, trackID == other.trackID, lines == other.lines, isPlaying == other.isPlaying,
              message == other.message, mode == other.mode, appliedOffset == other.appliedOffset else { return false }
        return abs(songStart.timeIntervalSince(other.songStart)) >= 0.3
    }

    /// 段落模式一格涵蓋的時間（秒）：實測系統大約每 10–20 秒才換一格
    static let paragraphWindow: TimeInterval = 12
    /// 段落模式一格至少 / 最多顯示幾句接下來的歌詞
    static let paragraphMinUpcoming = 2
    static let paragraphMaxUpcoming = 4

    /// 從 `now` 開始的畫面：第一個是現在；逐句模式之後每換一句一格，段落模式每個時間窗一格。
    /// - Parameter paragraphWindow: 段落模式一格涵蓋幾秒（系統換格更慢時可以放大）
    func frames(from now: Date, limit: Int = 150,
                paragraphWindow: TimeInterval = LyricsTimelineSnapshot.paragraphWindow) -> [LyricsTimelineFrame] {
        guard isPlaying, !lines.isEmpty else {
            // 小工具標題列已經有歌名：第二行放歌手，不要把歌名再重複一次（暫停、搜尋中、閒置都一樣）
            return [LyricsTimelineFrame(date: now, index: nil,
                                        current: message ?? title,
                                        upcoming: [artist].filter { !$0.isEmpty })]
        }
        let position = now.timeIntervalSince(songStart)
        let currentIndex = lines.index(at: position)
        var result: [LyricsTimelineFrame] = []
        var reachedEnd = false
        if mode == .paragraph {
            result = paragraphFrames(from: now, currentIndex: currentIndex, limit: limit,
                                     window: paragraphWindow, reachedEnd: &reachedEnd)
        } else {
            result.append(frame(at: now, index: currentIndex, upcomingCount: 1))
            let start = (currentIndex ?? -1) + 1
            let upper = min(lines.count, start + limit)
            if start < upper {
                for j in start..<upper {
                    result.append(frame(at: songStart.addingTimeInterval(lines[j].time), index: j, upcomingCount: 1))
                }
            }
            reachedEnd = upper >= lines.count
        }
        // 收尾：App 若被系統終止，時間軸播完不會停在最後一句假裝還在同步
        if reachedEnd, let end = endOfSong, let last = result.last, end > last.date {
            result.append(LyricsTimelineFrame(date: end, index: nil, current: "♪ 等待下一首",
                                              upcoming: ["沒跟上就打開 CarLyrics"]))
        }
        return result
    }

    /// 段落模式：一格 = 目前句 + 時間窗內會開始的句子（至少 2 句、最多 4 句）。
    /// 下一格從「時間窗之後的第一句」或「這一格放不下的第一句」開始（取較早者），
    /// 所以每一句開始的時刻都落在某一格裡，而且那一格一定列出了它。
    /// `reachedEnd` = 這些格子已經涵蓋到最後一句（可以補「等待下一首」）。
    private func paragraphFrames(from now: Date, currentIndex: Int?, limit: Int, window: TimeInterval,
                                 reachedEnd: inout Bool) -> [LyricsTimelineFrame] {
        var result: [LyricsTimelineFrame] = []
        var date = now
        var index = currentIndex
        while true {
            let from = (index ?? -1) + 1
            let windowEnd = date.timeIntervalSince(songStart) + window
            // 歌詞依時間排序：時間窗內的句子就是接下來連續的一段
            let inWindow = lines[from...].prefix(while: { $0.time < windowEnd }).count
            let count = min(lines.count - from,
                            max(Self.paragraphMinUpcoming, min(Self.paragraphMaxUpcoming, inWindow)))
            result.append(frame(at: date, index: index, upcomingCount: count))
            // 時間窗之後的第一句 = from + inWindow；放不下的第一句 = from + count
            let next = from + min(inWindow, count)
            if next >= lines.count {
                reachedEnd = true
                break
            }
            // 與逐句模式一樣最多 limit + 1 格
            if result.count > limit { break }
            index = next
            date = songStart.addingTimeInterval(lines[next].time)
        }
        return result
    }

    /// 歌曲結束後 3 秒（長度未知時 nil）
    private var endOfSong: Date? {
        guard duration > 0 else { return nil }
        return songStart.addingTimeInterval(appliedOffset + duration + 3)
    }

    private func frame(at date: Date, index: Int?, upcomingCount: Int) -> LyricsTimelineFrame {
        let from = (index ?? -1) + 1
        let upcoming = lines[min(from, lines.count)..<min(lines.count, from + upcomingCount)]
            .map(\.text).filter { !$0.isEmpty }
        // 間奏 / 前奏：下一句的真實時刻，讓畫面自己倒數（不需要任何更新）
        let nextAt = from < lines.count ? songStart.addingTimeInterval(lines[from].time) : nil
        guard let index else {
            return LyricsTimelineFrame(date: date, index: nil, current: "♪ \(title)",
                                       upcoming: upcoming, nextLineAt: nextAt)
        }
        let text = lines[index].text
        return LyricsTimelineFrame(date: date, index: index, current: text.isEmpty ? "♪" : text,
                                   upcoming: upcoming, nextLineAt: nextAt)
    }
}

struct LyricsTimelineFrame: Equatable, Sendable {
    let date: Date
    let index: Int?
    let current: String
    /// 之後要唱的句子（逐句模式 1 句、段落模式 2–4 句：時間窗內會開始的那些）
    let upcoming: [String]
    /// 下一句開始的真實時刻（間奏倒數用）
    var nextLineAt: Date?

    init(date: Date, index: Int?, current: String, upcoming: [String], nextLineAt: Date? = nil) {
        self.date = date
        self.index = index
        self.current = current
        self.upcoming = upcoming
        self.nextLineAt = nextLineAt
    }

    var next: String { upcoming.first ?? "" }

    /// 間奏超過這麼久才值得顯示倒數
    static let countdownThreshold: TimeInterval = 5

    /// 目前是間奏（沒有歌詞文字），且下一句還要等一下 → 顯示倒數的區間
    func countdownInterval(from date: Date) -> ClosedRange<Date>? {
        guard current.hasPrefix("♪"), let nextLineAt, nextLineAt.timeIntervalSince(date) > Self.countdownThreshold
        else { return nil }
        return date...nextLineAt
    }
}
