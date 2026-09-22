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
                      songStart: Date?, artworkFile: String?) -> ActivityContentModel {
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
        return ActivityContentModel(currentLine: current, nextLine: next, trackName: np.title,
                                    artistName: np.artist, isPlaying: np.isPlaying,
                                    songStart: interval?.0, songEnd: interval?.1, artworkFile: artworkFile)
    }
}
