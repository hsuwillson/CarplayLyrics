import Foundation

/// 測試資料：一律是自編字串，不得包含任何真實歌詞
enum Fixture {
    /// 產生 n 行 LRC：每 `step` 秒一句「測試第 N 句」
    static func lrc(count: Int, step: TimeInterval = 3, start: TimeInterval = 1) -> String {
        (0..<count).map { i in
            let t = start + Double(i) * step
            return String(format: "[%02ld:%05.2f]測試第%ld句", Int(t) / 60, t.truncatingRemainder(dividingBy: 60), i + 1)
        }.joined(separator: "\n")
    }

    static func lines(count: Int, step: TimeInterval = 3, start: TimeInterval = 1) -> [LyricLine] {
        (0..<count).map { LyricLine(time: start + Double($0) * step, text: "測試第\($0 + 1)句") }
    }

    static func nowPlaying(id: String = "track1", playing: Bool = true, progress: TimeInterval = 10,
                           duration: TimeInterval = 200) -> NowPlaying {
        NowPlaying(trackID: id, title: "測試歌名", artist: "測試歌手", primaryArtist: "測試歌手",
                   album: "測試專輯", duration: duration, progress: progress, isPlaying: playing)
    }
}
