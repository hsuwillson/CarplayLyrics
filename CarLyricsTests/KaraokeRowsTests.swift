import XCTest

/// CarPlay 小工具的卡拉 OK 視窗：每句帶起訖時刻，畫面用系統推進的進度條表示唱到哪。測試內容皆為自編字串。
final class KaraokeRowsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 50_000)

    private func snapshot(_ lines: [LyricLine], playing: Bool = true, duration: TimeInterval = 0,
                          offset: TimeInterval = 0) -> LyricsTimelineSnapshot {
        LyricsTimelineSnapshot(trackID: "k", title: "自編歌", artist: "自編歌手", lines: lines,
                               songStart: t0, isPlaying: playing, message: nil, updatedAt: t0,
                               appliedOffset: offset, duration: duration)
    }

    private let every10: [LyricLine] = (0..<20).map { LyricLine(time: Double($0) * 10 + 5, text: "第\($0 + 1)句") }

    /// 從正在唱的那句開始，每句的區間接到下一句開始
    func testRowsStartAtCurrentLineWithIntervals() {
        let rows = snapshot(every10).karaokeRows(at: t0.addingTimeInterval(27))
        XCTAssertEqual(rows.first?.text, "第3句")
        XCTAssertEqual(rows.first?.start, t0.addingTimeInterval(25))
        XCTAssertEqual(rows.first?.end, t0.addingTimeInterval(35))
        XCTAssertEqual(rows.first?.interval, t0.addingTimeInterval(25)...t0.addingTimeInterval(35))
        XCTAssertEqual(rows.count, LyricsTimelineSnapshot.karaokeMaxRows)
    }

    /// 還沒到第一句：從第一句開始列
    func testBeforeFirstLineStartsAtFirst() {
        let rows = snapshot(every10).karaokeRows(at: t0)
        XCTAssertEqual(rows.first?.text, "第1句")
    }

    /// 超出時間窗的句子不列（但至少列一句）
    func testWindowLimitsRowsButKeepsAtLeastOne() {
        let rows = snapshot(every10).karaokeRows(at: t0.addingTimeInterval(6), window: 25)
        XCTAssertEqual(rows.map(\.text), ["第1句", "第2句", "第3句"])
        let sparse = [LyricLine(time: 1, text: "開頭"), LyricLine(time: 200, text: "很久以後")]
        let one = snapshot(sparse).karaokeRows(at: t0.addingTimeInterval(150), window: 10)
        XCTAssertEqual(one.map(\.text), ["開頭"])
        let upcomingOnly = snapshot([LyricLine(time: 300, text: "遠方")]).karaokeRows(at: t0, window: 10)
        XCTAssertEqual(upcomingOnly.map(\.text), ["遠方"])
    }

    /// 空白句（間奏）不列，但會結束前一句；重複時間碼至少給 1 秒
    func testBlankLinesEndPreviousAndDuplicatesGetOneSecond() {
        let lines = [LyricLine(time: 0, text: "甲"), LyricLine(time: 4, text: "  "),
                     LyricLine(time: 10, text: "乙"), LyricLine(time: 10, text: "丙")]
        let rows = snapshot(lines).karaokeRows(at: t0.addingTimeInterval(1))
        XCTAssertEqual(rows.map(\.text), ["甲", "乙", "丙"])
        XCTAssertEqual(rows[0].end, t0.addingTimeInterval(4))
        XCTAssertEqual(rows[1].end, t0.addingTimeInterval(11))
    }

    /// 最後一句：知道歌曲長度就唱到歌曲結束（含延遲），不知道就唱幾秒
    func testLastLineEnd() {
        let lines = [LyricLine(time: 0, text: "唯一一句")]
        let known = snapshot(lines, duration: 100, offset: 2).karaokeRows(at: t0)
        XCTAssertEqual(known.first?.end, t0.addingTimeInterval(102))
        let unknown = snapshot(lines).karaokeRows(at: t0)
        XCTAssertEqual(unknown.first?.end, t0.addingTimeInterval(LyricsTimelineSnapshot.karaokeLastLine))
    }

    /// 沒在播放、沒有歌詞、不要任何列：空的
    func testEmptyCases() {
        XCTAssertTrue(snapshot(every10, playing: false).karaokeRows(at: t0).isEmpty)
        XCTAssertTrue(snapshot([]).karaokeRows(at: t0).isEmpty)
        XCTAssertTrue(snapshot(every10).karaokeRows(at: t0, maxRows: 0).isEmpty)
    }
}
