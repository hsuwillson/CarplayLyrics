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

    // MARK: - 再下一句（P2-8）

    func testSecondUpcomingLine() {
        let lines = Fixture.lines(count: 4)
        let mid = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines),
                                                   display: LyricsDisplay(lines: lines, position: 4.5),
                                                   songStart: nil, artworkFile: nil)
        XCTAssertEqual(mid.nextLine, "測試第3句")
        XCTAssertEqual(mid.nextLine2, "測試第4句")
        // 還沒到第一句：下一句是第 1 句，再下一句是第 2 句
        let before = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines),
                                                      display: LyricsDisplay(lines: lines, position: 0),
                                                      songStart: nil, artworkFile: nil)
        XCTAssertEqual(before.nextLine, "測試第1句")
        XCTAssertEqual(before.nextLine2, "測試第2句")
        // 倒數第二句：只剩一句可預告
        let tail = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines),
                                                    display: LyricsDisplay(lines: lines, position: 7.5),
                                                    songStart: nil, artworkFile: nil)
        XCTAssertEqual(tail.nextLine, "測試第4句")
        XCTAssertNil(tail.nextLine2)
    }

    func testSecondUpcomingLineSkipsBlankAndNoLyrics() {
        let lines = [LyricLine(time: 1, text: "測試第1句"), LyricLine(time: 4, text: "測試第2句"), LyricLine(time: 7, text: "")]
        let m = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines),
                                                 display: LyricsDisplay(lines: lines, position: 2),
                                                 songStart: nil, artworkFile: nil)
        XCTAssertEqual(m.nextLine, "測試第2句")
        XCTAssertNil(m.nextLine2)
        let none = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .notFound, display: .empty,
                                                    songStart: nil, artworkFile: nil)
        XCTAssertNil(none.nextLine2)
    }

    // MARK: - 逐句進度條（P2-8）

    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testLineProgressUsesLineStartAndNextLine() {
        let lines = Fixture.lines(count: 3)
        let m = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines),
                                                 display: LyricsDisplay(lines: lines, position: 4.5),
                                                 songStart: nil, artworkFile: nil,
                                                 nextLineAt: t0.addingTimeInterval(3), lineStartAt: t0)
        XCTAssertEqual(m.lineStartAt, t0)
        XCTAssertEqual(m.lineEndAt, t0.addingTimeInterval(3))
        XCTAssertEqual(m.lineProgressInterval, t0...t0.addingTimeInterval(3))
        // 有歌詞文字時不倒數（倒數是間奏專用）
        XCTAssertNil(m.nextLineAt)
    }

    func testLineProgressAbsentWhenPausedOrGapOrUnknown() {
        let lines = Fixture.lines(count: 3)
        let display = LyricsDisplay(lines: lines, position: 4.5)
        let synced = LyricsState.synced(lines)
        func build(_ np: NowPlaying, _ lyrics: LyricsState, _ display: LyricsDisplay,
                   nextLineAt: Date?, lineStartAt: Date?) -> ActivityContentModel {
            LiveActivityContentBuilder.build(nowPlaying: np, lyrics: lyrics, display: display,
                                             songStart: nil, artworkFile: nil,
                                             nextLineAt: nextLineAt, lineStartAt: lineStartAt)
        }
        let paused = build(Fixture.nowPlaying(playing: false), synced, display,
                           nextLineAt: t0.addingTimeInterval(3), lineStartAt: t0)
        XCTAssertNil(paused.lineStartAt)
        XCTAssertNil(paused.lineProgressInterval)
        // 間奏：改用倒數，不放逐句進度
        let gapLines = [LyricLine(time: 1, text: ""), LyricLine(time: 30, text: "測試第2句")]
        let gap = build(np, .synced(gapLines), LyricsDisplay(lines: gapLines, position: 2),
                        nextLineAt: t0.addingTimeInterval(20), lineStartAt: t0)
        XCTAssertEqual(gap.currentLine, "♪")
        XCTAssertNil(gap.lineStartAt)
        XCTAssertEqual(gap.nextLineAt, t0.addingTimeInterval(20))
        // 沒有同步歌詞：即使給了時刻也不顯示
        let none = build(np, .notFound, .empty, nextLineAt: t0.addingTimeInterval(3), lineStartAt: t0)
        XCTAssertNil(none.lineStartAt)
        // 不知道這句何時開始 / 沒有下一句
        XCTAssertNil(build(np, synced, display, nextLineAt: t0.addingTimeInterval(3), lineStartAt: nil).lineStartAt)
        XCTAssertNil(build(np, synced, display, nextLineAt: nil, lineStartAt: t0).lineEndAt)
    }

    func testLineProgressIntervalRejectsInvalidRange() {
        var m = ActivityContentModel(currentLine: "測試第1句", nextLine: "測試第2句", trackName: "測試歌名",
                                     artistName: "測試歌手", isPlaying: true,
                                     lineStartAt: t0, lineEndAt: t0.addingTimeInterval(4))
        XCTAssertEqual(m.lineProgressInterval, t0...t0.addingTimeInterval(4))
        m.lineEndAt = t0
        XCTAssertNil(m.lineProgressInterval)
        m.lineEndAt = t0.addingTimeInterval(4)
        m.isPlaying = false
        XCTAssertNil(m.lineProgressInterval)
        m.isPlaying = true
        m.lineStartAt = nil
        XCTAssertNil(m.lineProgressInterval)
    }

    func testNewFieldsAreReportedByMismatch() {
        let base = ActivityContentModel(currentLine: "測試第1句", nextLine: "測試第2句", trackName: "測試歌名",
                                        artistName: "測試歌手", isPlaying: true, nextLine2: "測試第3句",
                                        lineStartAt: t0, lineEndAt: t0.addingTimeInterval(4))
        XCTAssertNil(base.mismatchField(comparedTo: base))
        var o = base
        o.nextLine2 = nil
        XCTAssertEqual(base.mismatchField(comparedTo: o), "nextLine2")
        o = base
        o.lineStartAt = t0.addingTimeInterval(0.5)   // 容許誤差內
        XCTAssertNil(base.mismatchField(comparedTo: o))
        o.lineStartAt = t0.addingTimeInterval(3)
        XCTAssertEqual(base.mismatchField(comparedTo: o), "lineStartAt")
        o = base
        o.lineEndAt = nil
        XCTAssertEqual(base.mismatchField(comparedTo: o), "lineEndAt")
    }

    // MARK: - 歌曲播完（P2-3）

    func testSongOverShowsWaitingForNextTrack() {
        let lines = Fixture.lines(count: 3)
        let display = LyricsDisplay(lines: lines, position: 250)
        let over = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines), display: display,
                                                    songStart: Date(), artworkFile: "a.jpg",
                                                    nextLineAt: nil, lineStartAt: t0, position: 200)
        XCTAssertEqual(over.currentLine, LiveActivityContentBuilder.songOverLine)
        XCTAssertEqual(over.nextLine, LiveActivityContentBuilder.songOverHint)
        XCTAssertEqual(over.trackName, "測試歌名")
        XCTAssertEqual(over.artworkFile, "a.jpg")
        XCTAssertTrue(over.isPlaying)
        XCTAssertNil(over.songStart)
        XCTAssertNil(over.lineStartAt)
        XCTAssertNil(over.nextLine2)
        // 還沒播完：照常
        let playing = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines), display: display,
                                                       songStart: nil, artworkFile: nil, position: 199.9)
        XCTAssertEqual(playing.currentLine, "測試第3句")
        // 不知道歌曲長度：不判定
        let unknown = LiveActivityContentBuilder.build(nowPlaying: Fixture.nowPlaying(duration: 0), lyrics: .synced(lines),
                                                       display: display, songStart: nil, artworkFile: nil, position: 500)
        XCTAssertEqual(unknown.currentLine, "測試第3句")
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
