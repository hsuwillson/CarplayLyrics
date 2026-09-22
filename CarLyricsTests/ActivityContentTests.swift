import XCTest

final class ActivityContentTests: XCTestCase {
    let np = Fixture.nowPlaying()

    func testSyncedLyrics() {
        let lines = Fixture.lines(count: 3)
        let d = LyricsDisplay(lines: lines, position: 4.5)
        let m = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines), display: d,
                                                 songStart: Date(timeIntervalSince1970: 0), artworkFile: "a.jpg")
        XCTAssertEqual(m.currentLine, "測試第2句")
        XCTAssertEqual(m.nextLine, "測試第3句")
        XCTAssertEqual(m.trackName, "測試歌名")
        XCTAssertEqual(m.songEnd, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(m.artworkFile, "a.jpg")
    }

    func testInstrumentalGapShowsNote() {
        let lines = [LyricLine(time: 1, text: "測試第1句"), LyricLine(time: 5, text: "")]
        let d = LyricsDisplay(lines: lines, position: 6)
        let m = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines), display: d, songStart: nil, artworkFile: nil)
        XCTAssertEqual(m.currentLine, "♪")
        XCTAssertNil(m.songStart)
    }

    func testSearchingAndNoLyrics() {
        let s = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .searching, display: .empty, songStart: nil, artworkFile: nil)
        XCTAssertEqual(s.currentLine, "測試歌名")
        XCTAssertEqual(s.nextLine, "搜尋歌詞中…")
        let n = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .notFound, display: .empty, songStart: nil, artworkFile: nil)
        XCTAssertEqual(n.nextLine, "測試歌手")
    }

    func testPausedHasNoProgressInterval() {
        let paused = Fixture.nowPlaying(playing: false)
        let m = LiveActivityContentBuilder.build(nowPlaying: paused, lyrics: .notFound, display: .empty,
                                                 songStart: Date(), artworkFile: nil)
        XCTAssertNil(m.songStart)
        XCTAssertFalse(m.isPlaying)
    }

    /// 即時動態的內容有 4 KB 上限
    func testEncodedSizeIsSmall() throws {
        let long = String(repeating: "測", count: 200)
        let m = ActivityContentModel(currentLine: long, nextLine: long, trackName: long, artistName: long,
                                     isPlaying: true, songStart: Date(), songEnd: Date(), artworkFile: "x.jpg")
        struct Box: Encodable { let a, b, c, d: String; let e: Bool; let f, g: Date?; let h: String? }
        let data = try JSONEncoder().encode(Box(a: m.currentLine, b: m.nextLine, c: m.trackName, d: m.artistName,
                                                e: m.isPlaying, f: m.songStart, g: m.songEnd, h: m.artworkFile))
        XCTAssertLessThan(data.count, 4096)
    }
}
