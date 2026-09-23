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

    /// - Parameters:
    ///   - songStart: 歌曲 0 秒對應的真實時刻（不含延遲）；未知時 nil
    static func build(nowPlaying np: NowPlaying, lyrics: LyricsState, display: LyricsDisplay,
                      songStart: Date?, artworkFile: String?, nextLineAt: Date? = nil) -> ActivityContentModel {
        let current: String
        let next: String
        if !lyrics.lines.isEmpty {
            current = display.current.isEmpty ? "♪" : display.current
            next = display.next
        } else {
            // 沒有同步歌詞時顯示歌名 / 歌手，比狀態文字有用
            current = np.title
            next = lyrics.isSearching ? "搜尋歌詞中…" : np.artist
        }
        let interval: (Date, Date)? = {
            guard np.isPlaying, np.duration > 0, let songStart else { return nil }
            return (songStart, songStart.addingTimeInterval(np.duration))
        }()
        // 間奏（目前沒有歌詞文字）才需要倒數
        let countdown = current == "♪" ? nextLineAt : nil
        return ActivityContentModel(currentLine: current, nextLine: next, trackName: np.title,
                                    artistName: np.artist, isPlaying: np.isPlaying,
                                    songStart: interval?.0, songEnd: interval?.1, artworkFile: artworkFile,
                                    nextLineAt: countdown)
    }
}
