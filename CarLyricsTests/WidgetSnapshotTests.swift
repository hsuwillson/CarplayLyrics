import XCTest

final class WidgetSnapshotTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 10_000)

    private func snapshot(offset: TimeInterval = 0, start: Date? = nil) -> LyricsTimelineSnapshot {
        LyricsTimelineSnapshot(trackID: "a", title: "測試歌", artist: "測試歌手", lines: Fixture.lines(count: 5),
                               songStart: (start ?? t0).addingTimeInterval(-offset), isPlaying: true, message: nil,
                               updatedAt: t0, appliedOffset: offset, duration: 200)
    }

    /// R-1 回歸：延遲只差 0.25 秒也必須判定為不同（要重新整理小工具）
    func testQuarterSecondOffsetIsDifferent() {
        XCTAssertFalse(snapshot(offset: 0).isSameTimeline(as: snapshot(offset: 0.25)))
    }

    func testSmallJitterIsSame() {
        XCTAssertTrue(snapshot().isSameTimeline(as: snapshot(start: t0.addingTimeInterval(0.2))))
        XCTAssertFalse(snapshot().isSameTimeline(as: snapshot(start: t0.addingTimeInterval(0.5))))
    }

    func testModeChangeIsDifferent() {
        var b = snapshot()
        b.mode = .paragraph
        XCTAssertFalse(snapshot().isSameTimeline(as: b))
    }

    func testParagraphModeShowsTwoUpcoming() {
        var s = snapshot()
        s.mode = .paragraph
        let f = s.frames(from: t0.addingTimeInterval(1.5))
        XCTAssertEqual(f[0].current, "測試第1句")
        XCTAssertEqual(f[0].upcoming, ["測試第2句", "測試第3句"])
        XCTAssertEqual(snapshot().frames(from: t0.addingTimeInterval(1.5))[0].upcoming, ["測試第2句"])
    }

    func testPlaybackIntervalExcludesOffset() {
        let s = snapshot(offset: 1)
        XCTAssertEqual(s.playbackInterval?.lowerBound, t0)
        XCTAssertEqual(s.playbackInterval?.upperBound, t0.addingTimeInterval(200))
    }

    func testOffsetShiftsFrames() {
        // 提前 1 秒：第一句（1 秒）在 t0 就出現
        let f = snapshot(offset: 1).frames(from: t0)
        XCTAssertEqual(f[0].current, "測試第1句")
    }
}
