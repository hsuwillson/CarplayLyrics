import XCTest

final class LyricsSyncEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func snap(_ progress: TimeInterval, id: String = "a", playing: Bool = true, at dt: TimeInterval) -> PlaybackSnapshot {
        PlaybackSnapshot(trackID: id, progress: progress, duration: 200, isPlaying: playing, timestamp: t0.addingTimeInterval(dt))
    }

    func testFirstUpdateIsNewTrack() {
        var e = LyricsSyncEngine()
        XCTAssertEqual(e.update(snap(10, at: 0)), .newTrack)
    }

    func testNormalProgressIsNoChange() {
        var e = LyricsSyncEngine()
        e.update(snap(10, at: 0))
        XCTAssertEqual(e.update(snap(12.6, at: 2.5)), .none)
    }

    func testSeekForwardAndBackward() {
        var e = LyricsSyncEngine()
        e.update(snap(10, at: 0))
        XCTAssertEqual(e.update(snap(60, at: 2.5)), .seeked)
        XCTAssertEqual(e.update(snap(5, at: 5)), .seeked)
    }

    func testTrackChange() {
        var e = LyricsSyncEngine()
        e.update(snap(10, at: 0))
        XCTAssertEqual(e.update(snap(0, id: "b", at: 3)), .newTrack)
    }

    func testPlayStateChange() {
        var e = LyricsSyncEngine()
        e.update(snap(10, at: 0))
        XCTAssertEqual(e.update(snap(12, playing: false, at: 2)), .playStateChanged)
    }

    func testPositionExtrapolationAndOffset() {
        var e = LyricsSyncEngine()
        e.update(snap(10, at: 0))
        XCTAssertEqual(e.position(at: t0.addingTimeInterval(1.5))!, 11.5, accuracy: 0.001)
        XCTAssertEqual(e.position(at: t0.addingTimeInterval(1.5), offset: 0.5)!, 12.0, accuracy: 0.001)
    }

    func testPausedPositionDoesNotAdvance() {
        var e = LyricsSyncEngine()
        e.update(snap(10, playing: false, at: 0))
        XCTAssertEqual(e.position(at: t0.addingTimeInterval(30))!, 10, accuracy: 0.001)
    }

    func testPositionClampedToDuration() {
        var e = LyricsSyncEngine()
        e.update(snap(199, at: 0))
        XCTAssertEqual(e.position(at: t0.addingTimeInterval(10))!, 200, accuracy: 0.001)
    }

    func testDisplayAndNextChange() {
        let lines = [LyricLine(time: 1, text: "測試一"), LyricLine(time: 3, text: "測試二")]
        XCTAssertEqual(LyricsDisplay(lines: lines, position: 0.5), LyricsDisplay(index: nil, current: "", next: "測試一"))
        XCTAssertEqual(LyricsDisplay(lines: lines, position: 2), LyricsDisplay(index: 0, current: "測試一", next: "測試二"))
        XCTAssertEqual(LyricsDisplay(lines: lines, position: 10), LyricsDisplay(index: 1, current: "測試二", next: ""))
        XCTAssertEqual(lines.nextChangeTime(after: 0), 1)
        XCTAssertEqual(lines.nextChangeTime(after: 1), 3)
        XCTAssertNil(lines.nextChangeTime(after: 5))
    }
}
