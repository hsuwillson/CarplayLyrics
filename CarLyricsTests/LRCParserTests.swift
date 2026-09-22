import XCTest

// 測試用的 LRC 全部是自己編的內容，不含任何真實歌詞。
final class LRCParserTests: XCTestCase {

    func testBasicLines() {
        let lines = LRCParser.parse("""
        [00:01.00]測試第一句
        [00:05.50]測試第二句
        """)
        XCTAssertEqual(lines, [
            LyricLine(time: 1.0, text: "測試第一句"),
            LyricLine(time: 5.5, text: "測試第二句"),
        ])
    }

    func testTimestampFormats() {
        XCTAssertEqual(LRCParser.parseTimestamp("01:02"), 62)
        XCTAssertEqual(LRCParser.parseTimestamp("01:02.5")!, 62.5, accuracy: 0.0001)
        XCTAssertEqual(LRCParser.parseTimestamp("01:02.50")!, 62.5, accuracy: 0.0001)
        XCTAssertEqual(LRCParser.parseTimestamp("01:02.500")!, 62.5, accuracy: 0.0001)
        XCTAssertEqual(LRCParser.parseTimestamp("01:02:50")!, 62.5, accuracy: 0.0001)
        XCTAssertNil(LRCParser.parseTimestamp("ar:測試歌手"))
        XCTAssertNil(LRCParser.parseTimestamp("00:75.00"))
    }

    func testMultipleTimestampsOnOneLine() {
        let lines = LRCParser.parse("""
        [00:10.00][00:30.00]測試副歌
        [00:20.00]測試主歌
        """)
        XCTAssertEqual(lines.map(\.time), [10, 20, 30])
        XCTAssertEqual(lines.map(\.text), ["測試副歌", "測試主歌", "測試副歌"])
    }

    func testMetadataIgnoredAndOffsetApplied() {
        let lines = LRCParser.parse("""
        [ti:測試歌名]
        [ar:測試歌手]
        [offset:+500]
        [00:02.00]測試第一句
        """)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 1.5, accuracy: 0.0001)
    }

    func testNegativeOffsetAndClampToZero() {
        let later = LRCParser.parse("[offset:-1000]\n[00:01.00]測試")
        XCTAssertEqual(later[0].time, 2.0, accuracy: 0.0001)
        let earlier = LRCParser.parse("[offset:3000]\n[00:01.00]測試")
        XCTAssertEqual(earlier[0].time, 0)
    }

    func testEmptyTextLineKept() {
        // 空白行常用來表示間奏，要保留讓畫面清空
        let lines = LRCParser.parse("[00:01.00]測試\n[00:04.00]")
        XCTAssertEqual(lines.last?.text, "")
    }

    func testIndexAtTime() {
        let lines = LRCParser.parse("""
        [00:01.00]一
        [00:03.00]二
        [00:06.00]三
        """)
        XCTAssertNil(lines.index(at: 0.5))
        XCTAssertEqual(lines.index(at: 1.0), 0)
        XCTAssertEqual(lines.index(at: 2.9), 0)
        XCTAssertEqual(lines.index(at: 3.0), 1)
        XCTAssertEqual(lines.index(at: 100), 2)
        XCTAssertNil([LyricLine]().index(at: 1))
    }

    // MARK: 實務缺口（R-7）

    func testEnhancedWordTimestampsRemoved() {
        let lines = LRCParser.parse("[00:01.00]<00:01.00>測試 <00:01.50>第一句 <00:02.00>")
        XCTAssertEqual(lines, [LyricLine(time: 1, text: "測試 第一句")])
    }

    func testBOMDoesNotDropFirstLine() {
        let lines = LRCParser.parse("\u{FEFF}[00:01.00]測試第一句\r\n[00:02.00]測試第二句")
        XCTAssertEqual(lines.map(\.text), ["測試第一句", "測試第二句"])
    }

    func testLeadingCreditsDropped() {
        let lrc = "[00:00.00]作詞：測試甲\n[00:00.50]作曲：測試乙\n[00:10.00]測試第一句\n[00:20.00]作詞：不是開頭不移除"
        XCTAssertEqual(LRCParser.parse(lrc).map(\.text), ["測試第一句", "作詞：不是開頭不移除"])
        XCTAssertEqual(LRCParser.parse(lrc, dropCredits: false).count, 4)
    }

    func testOffsetWithSpacesAndUnsortedTimes() {
        let lines = LRCParser.parse("[offset: +500]\n[00:05.00]測試第二句\n[00:02.00]測試第一句")
        XCTAssertEqual(lines, [LyricLine(time: 1.5, text: "測試第一句"), LyricLine(time: 4.5, text: "測試第二句")])
    }

    func testFixtureParses() {
        XCTAssertEqual(LRCParser.parse(Fixture.lrc(count: 5)).count, 5)
    }
}
