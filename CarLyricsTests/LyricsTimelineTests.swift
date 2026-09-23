import XCTest

// 測試用內容皆為自編字串
final class LyricsTimelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    private func snapshot(playing: Bool = true) -> LyricsTimelineSnapshot {
        LyricsTimelineSnapshot(trackID: "a", title: "測試歌", artist: "測試歌手",
                               lines: [LyricLine(time: 2, text: "測試一"),
                                       LyricLine(time: 5, text: ""),
                                       LyricLine(time: 8, text: "測試三")],
                               songStart: t0, isPlaying: playing, message: nil, updatedAt: t0)
    }

    func testFramesBeforeFirstLine() {
        let f = snapshot().frames(from: t0.addingTimeInterval(1))
        XCTAssertEqual(f.count, 4)
        XCTAssertNil(f[0].index)
        XCTAssertEqual(f[0].next, "測試一")
        XCTAssertEqual(f[1].date, t0.addingTimeInterval(2))
        XCTAssertEqual(f[1].current, "測試一")
        XCTAssertEqual(f[2].current, "♪")          // 空白行（間奏）
        XCTAssertEqual(f[3].next, "")
    }

    func testFramesMidSong() {
        let f = snapshot().frames(from: t0.addingTimeInterval(6))
        XCTAssertEqual(f.map(\.index), [1, 2])
        XCTAssertEqual(f[0].date, t0.addingTimeInterval(6))
        XCTAssertEqual(f[1].date, t0.addingTimeInterval(8))
    }

    func testPausedShowsSingleFrame() {
        let f = snapshot(playing: false).frames(from: t0)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].current, "測試歌")
        XCTAssertEqual(f[0].next, "測試歌手")
    }

    func testIdleMessage() {
        let f = LyricsTimelineSnapshot.idle("沒有播放", at: t0).frames(from: t0)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].current, "沒有播放")
        XCTAssertEqual(f[0].upcoming, [], "閒置時不要再顯示一次「CarLyrics」")
    }

    /// 暫停 / 搜尋中：第二行是歌手，不重複歌名
    func testMessageFrameShowsArtistNotTitle() {
        var s = snapshot(playing: false)
        s.message = "⏸ 測試歌"
        let f = s.frames(from: t0)
        XCTAssertEqual(f[0].current, "⏸ 測試歌")
        XCTAssertEqual(f[0].upcoming, ["測試歌手"])
    }

    func testLimit() {
        let f = snapshot().frames(from: t0, limit: 1)
        XCTAssertEqual(f.count, 2)
    }

    func testCodableRoundTrip() throws {
        let s = snapshot()
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(LyricsTimelineSnapshot.self, from: data), s)
    }
}
