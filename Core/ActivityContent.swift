import Foundation

/// Live Activity 要顯示的內容（不依賴 ActivityKit，方便測試；App 再轉成 ContentState）
struct ActivityContentModel: Equatable, Sendable {
    var currentLine: String
    var nextLine: String
    var trackName: String
    var artistName: String
    var isPlaying: Bool
    /// 播放中時，系統可以自己推進進度條（不需要 App 更新）
    var songStart: Date?
    var songEnd: Date?
    var artworkFile: String?
    /// 間奏時下一句開始的時刻（畫面自己倒數）
    var nextLineAt: Date?
    /// 再下一句（鎖定畫面多給一句預告；沒有時 nil）
    var nextLine2: String?
    /// 目前句的起訖真實時刻（播放中、有歌詞文字時才有），讓系統自己推進逐句進度條：
    /// 進度條在動＝即時動態還活著；停在滿格＝已經沒跟上
    var lineStartAt: Date?
    var lineEndAt: Date?

    /// 逐句進度條的區間；暫停、沒有時刻或時刻不合理時 nil
    var lineProgressInterval: ClosedRange<Date>? {
        guard isPlaying, let lineStartAt, let lineEndAt, lineEndAt > lineStartAt else { return nil }
        return lineStartAt...lineEndAt
    }

    /// 與系統回讀的內容是否「實質相同」。
    /// ActivityKit 回讀的 Date 精度不一定與送出時完全相同，用 `==` 比對會把每次更新都誤判成被擋。
    func isEquivalent(to other: ActivityContentModel, tolerance: TimeInterval = 1) -> Bool {
        mismatchField(comparedTo: other, tolerance: tolerance) == nil
    }

    /// 回傳第一個不同的欄位名稱（診斷用）；完全相同時 nil
    func mismatchField(comparedTo o: ActivityContentModel, tolerance: TimeInterval = 1) -> String? {
        func near(_ a: Date?, _ b: Date?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return abs(x.timeIntervalSince(y)) <= tolerance
            default: return false
            }
        }
        if currentLine != o.currentLine { return "currentLine" }
        if nextLine != o.nextLine { return "nextLine" }
        if trackName != o.trackName { return "trackName" }
        if artistName != o.artistName { return "artistName" }
        if isPlaying != o.isPlaying { return "isPlaying" }
        if artworkFile != o.artworkFile { return "artworkFile" }
        if !near(songStart, o.songStart) { return "songStart" }
        if !near(songEnd, o.songEnd) { return "songEnd" }
        if !near(nextLineAt, o.nextLineAt) { return "nextLineAt" }
        if nextLine2 != o.nextLine2 { return "nextLine2" }
        if !near(lineStartAt, o.lineStartAt) { return "lineStartAt" }
        if !near(lineEndAt, o.lineEndAt) { return "lineEndAt" }
        return nil
    }
}

enum LiveActivityContentBuilder {
    static let connecting = ActivityContentModel(currentLine: "連接 Spotify 中…", nextLine: "", trackName: "CarLyrics",
                                                 artistName: "", isPlaying: false)
    static let stopped = ActivityContentModel(currentLine: "Spotify 沒有在播放", nextLine: "", trackName: "CarLyrics",
                                              artistName: "", isPlaying: false)
    static let backgroundOff = ActivityContentModel(currentLine: "背景執行已關閉", nextLine: "打開 CarLyrics 繼續同步",
                                                    trackName: "CarLyrics", artistName: "", isPlaying: false)

    static func nonMusic(_ kind: NonMusicKind) -> ActivityContentModel {
        ActivityContentModel(currentLine: kind.label, nextLine: "", trackName: "CarLyrics", artistName: "", isPlaying: true)
    }

    /// 歌曲已經播完、但還沒收到下一首（離線時輪詢拿不到）：不要一直掛著最後一句
    static let songOverLine = "♪ 等待下一首"
    static let songOverHint = "沒跟上就打開 CarLyrics"

    /// - Parameters:
    ///   - songStart: 歌曲 0 秒對應的真實時刻（不含延遲）；未知時 nil
    ///   - nextLineAt: 下一句開始的真實時刻（間奏倒數、逐句進度條用）
    ///   - lineStartAt: 目前句開始的真實時刻（逐句進度條用）；未知時 nil
    ///   - position: 目前的歌曲位置（秒）；超過歌曲長度就顯示「等待下一首」，未知時 nil
    static func build(nowPlaying np: NowPlaying, lyrics: LyricsState, display: LyricsDisplay,
                      songStart: Date?, artworkFile: String?, nextLineAt: Date? = nil,
                      lineStartAt: Date? = nil, position: TimeInterval? = nil) -> ActivityContentModel {
        if let position, np.duration > 0, position >= np.duration {
            return ActivityContentModel(currentLine: songOverLine, nextLine: songOverHint, trackName: np.title,
                                        artistName: np.artist, isPlaying: np.isPlaying, artworkFile: artworkFile)
        }
        let current: String
        let next: String
        let next2: String?
        let lines = lyrics.lines
        if !lines.isEmpty {
            current = display.current.isEmpty ? "♪" : display.current
            next = display.next
            // 再下一句：目前句之後第二句（還沒到第一句時就是第二句）；空白句不預告
            let i2 = (display.index ?? -1) + 2
            next2 = i2 < lines.count && !lines[i2].text.isEmpty ? lines[i2].text : nil
        } else {
            // 沒有同步歌詞時顯示歌名 / 歌手，比狀態文字有用
            current = np.title
            next = lyrics.isSearching ? "搜尋歌詞中…" : np.artist
            next2 = nil
        }
        let interval: (Date, Date)? = {
            guard np.isPlaying, np.duration > 0, let songStart else { return nil }
            return (songStart, songStart.addingTimeInterval(np.duration))
        }()
        // 間奏（目前沒有歌詞文字）才需要倒數
        let countdown = current == "♪" ? nextLineAt : nil
        // 逐句進度條：播放中、有歌詞文字、知道起訖時刻才有（間奏改用倒數）
        let lineRange: (Date, Date)? = {
            guard np.isPlaying, !lines.isEmpty, current != "♪", let lineStartAt, let nextLineAt else { return nil }
            return (lineStartAt, nextLineAt)
        }()
        return ActivityContentModel(currentLine: current, nextLine: next, trackName: np.title,
                                    artistName: np.artist, isPlaying: np.isPlaying,
                                    songStart: interval?.0, songEnd: interval?.1, artworkFile: artworkFile,
                                    nextLineAt: countdown, nextLine2: next2,
                                    lineStartAt: lineRange?.0, lineEndAt: lineRange?.1)
    }
}
