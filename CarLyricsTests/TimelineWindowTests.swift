import XCTest

/// P1-3：段落模式（系統節流、10–20 秒才換一格）改成「時間窗」框架：
/// 一格 = 目前句 + 時間窗內會開始的句子（至少 2、最多 4），就算系統晚十幾秒才顯示這一格，
/// 正在唱的句子也在格子裡。逐句模式不變。測試內容皆為自編字串。
final class TimelineWindowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 30_000)

    private func snapshot(lines: [LyricLine], mode: LyricsTimelineMode = .paragraph,
                          duration: TimeInterval = 200) -> LyricsTimelineSnapshot {
        LyricsTimelineSnapshot(trackID: "a", title: "測試歌", artist: "測試歌手", lines: lines,
                               songStart: t0, isPlaying: true, message: nil, updatedAt: t0,
                               duration: duration, mode: mode)
    }

    /// 每一句（從第一格之後開始的）開始的時刻都落在某一格的 [date, 下一格 date) 裡，
    /// 而且那一格把它列為目前句或接下來的句子
    private func assertEveryLineCovered(_ frames: [LyricsTimelineFrame], lines: [LyricLine],
                                        file: StaticString = #filePath, line: UInt = #line) {
        for (j, l) in lines.enumerated() {
            let start = t0.addingTimeInterval(l.time)
            guard let i = frames.lastIndex(where: { $0.date <= start }) else { continue }   // 已經唱過的句子
            let f = frames[i]
            XCTAssertTrue(f.index == j || f.upcoming.contains(l.text) || l.text.isEmpty,
                          "第 \(j + 1) 句（\(l.time) 秒）不在涵蓋它的那一格裡：\(f)", file: file, line: line)
        }
    }

    /// 每 3 秒一句：一格涵蓋 12 秒 → 格子間隔 12 秒、每格 3–4 句，格數約為逐句模式的 1/4
    func testParagraphFramesAreWindowed() {
        let lines = Fixture.lines(count: 20)          // 1, 4, 7, … 58 秒
        let f = snapshot(lines: lines).frames(from: t0)
        // 前奏 → 第 5 句（13 秒）→ 第 9 句（25 秒）→ 第 13 句 → 第 17 句 → 等待下一首
        XCTAssertEqual(f.map(\.date), [t0, t0.addingTimeInterval(13), t0.addingTimeInterval(25),
                                       t0.addingTimeInterval(37), t0.addingTimeInterval(49),
                                       t0.addingTimeInterval(203)])
        XCTAssertNil(f[0].index)
        XCTAssertEqual(f[0].current, "♪ 測試歌")
        XCTAssertEqual(f[0].upcoming, ["測試第1句", "測試第2句", "測試第3句", "測試第4句"])
        XCTAssertEqual(f[1].index, 4)
        XCTAssertEqual(f[1].current, "測試第5句")
        XCTAssertEqual(f[1].upcoming, ["測試第6句", "測試第7句", "測試第8句"])
        XCTAssertEqual(f[1].nextLineAt, t0.addingTimeInterval(16))
        for i in 1..<f.count {
            XCTAssertGreaterThanOrEqual(f[i].date.timeIntervalSince(f[i - 1].date), 12)
        }
        assertEveryLineCovered(f, lines: lines)
        // 收尾的「等待下一首」保留
        XCTAssertEqual(f.last?.current, "♪ 等待下一首")
        XCTAssertEqual(f.last?.upcoming, ["沒跟上就打開 CarLyrics"])
        XCTAssertNil(f.last?.index)
        // 逐句模式：1 + 20 句 + 收尾
        XCTAssertEqual(snapshot(lines: lines, mode: .perLine).frames(from: t0).count, 22)
    }

    /// 系統晚顯示：格子在 [date, 下一格) 的任何時刻被顯示，正在唱的句子都在格子裡
    func testLateDisplayStillShowsCurrentLine() {
        let lines = Fixture.lines(count: 20)
        let s = snapshot(lines: lines)
        let f = s.frames(from: t0.addingTimeInterval(5))       // 從第 2 句唱到一半開始
        XCTAssertEqual(f[0].index, 1)
        XCTAssertEqual(f[1].date, t0.addingTimeInterval(19))   // 5 + 12 → 19 秒的第 7 句
        for i in 0..<(f.count - 1) {
            var t = f[i].date.timeIntervalSince(t0)
            let end = f[i + 1].date.timeIntervalSince(t0)
            while t < end {
                let sung = lines.index(at: t)!
                XCTAssertTrue(f[i].index == sung || f[i].upcoming.contains(lines[sung].text),
                              "\(t) 秒正在唱第 \(sung + 1) 句，但格子 \(i) 沒有列出")
                t += 0.5
            }
        }
        assertEveryLineCovered(f, lines: lines)
    }

    /// 歌詞很密（每 2 秒一句）：最多 4 句，放不下的那句就是下一格的起點（不會漏掉任何一句）
    func testDenseLyricsCapAtFour() {
        let lines = Fixture.lines(count: 12, step: 2)   // 1, 3, 5, … 23 秒
        let f = snapshot(lines: lines).frames(from: t0)
        XCTAssertEqual(f[0].upcoming.count, LyricsTimelineSnapshot.paragraphMaxUpcoming)
        XCTAssertEqual(f[0].upcoming, ["測試第1句", "測試第2句", "測試第3句", "測試第4句"])
        XCTAssertEqual(f[1].date, t0.addingTimeInterval(9))   // 第 5 句：這一格放不下的第一句
        XCTAssertEqual(f[1].current, "測試第5句")
        assertEveryLineCovered(f, lines: lines)
    }

    /// 歌詞很疏（間奏長）：時間窗內沒有句子也至少列 2 句，而且下一句開始時仍然換格
    func testSparseLyricsPadToTwo() {
        let lines = [LyricLine(time: 1, text: "測試第1句"), LyricLine(time: 30, text: "測試第2句"),
                     LyricLine(time: 60, text: "測試第3句")]
        let f = snapshot(lines: lines).frames(from: t0.addingTimeInterval(2))
        XCTAssertEqual(f.map(\.date), [t0.addingTimeInterval(2), t0.addingTimeInterval(30),
                                       t0.addingTimeInterval(60), t0.addingTimeInterval(203)])
        XCTAssertEqual(f[0].current, "測試第1句")
        XCTAssertEqual(f[0].upcoming, ["測試第2句", "測試第3句"])
        XCTAssertEqual(f[1].current, "測試第2句")
        XCTAssertEqual(f[1].upcoming, ["測試第3句"])
        XCTAssertEqual(f[2].current, "測試第3句")
        XCTAssertEqual(f[2].upcoming, [])
        XCTAssertNil(f[2].nextLineAt)
        assertEveryLineCovered(f, lines: lines)
    }

    /// 間奏（空白句）：目前句顯示 ♪、不列進接下來的句子，但仍算在時間窗裡
    func testInstrumentalLineInsideWindow() {
        let lines = [LyricLine(time: 1, text: "測試第1句"), LyricLine(time: 4, text: ""),
                     LyricLine(time: 7, text: "測試第3句"), LyricLine(time: 40, text: "測試第4句")]
        let f = snapshot(lines: lines).frames(from: t0.addingTimeInterval(5))
        XCTAssertEqual(f[0].current, "♪")
        XCTAssertEqual(f[0].upcoming, ["測試第3句", "測試第4句"])
        XCTAssertEqual(f[0].nextLineAt, t0.addingTimeInterval(7))
        XCTAssertEqual(f[1].date, t0.addingTimeInterval(40))
        assertEveryLineCovered(f, lines: lines)
    }

    /// 時間窗可以調整（系統換格更慢時放大）；窗越小格越多
    func testCustomWindow() {
        let lines = Fixture.lines(count: 20)
        let s = snapshot(lines: lines)
        let narrow = s.frames(from: t0, paragraphWindow: 6)
        XCTAssertEqual(narrow[0].upcoming, ["測試第1句", "測試第2句"])   // 1、4 秒在 [0, 6) 內
        XCTAssertEqual(narrow[1].date, t0.addingTimeInterval(7))
        XCTAssertGreaterThan(narrow.count, s.frames(from: t0).count)
        assertEveryLineCovered(narrow, lines: lines)
        XCTAssertEqual(LyricsTimelineSnapshot.paragraphWindow, 12)
        XCTAssertEqual(LyricsTimelineSnapshot.paragraphMinUpcoming, 2)
    }

    /// limit 與逐句模式一樣：最多 limit + 1 格，而且沒播到最後就不補「等待下一首」
    func testParagraphLimit() {
        let f = snapshot(lines: Fixture.lines(count: 20)).frames(from: t0, limit: 1)
        XCTAssertEqual(f.count, 2)
        XCTAssertNotEqual(f.last?.current, "♪ 等待下一首")
    }

    /// 長度未知：不補收尾；已經唱完最後一句：只剩一格（沒有接下來的句子）
    func testEndOfSongEdges() {
        let lines = Fixture.lines(count: 3)
        XCTAssertNotEqual(snapshot(lines: lines, duration: 0).frames(from: t0).last?.current, "♪ 等待下一首")
        let f = snapshot(lines: lines).frames(from: t0.addingTimeInterval(100))
        XCTAssertEqual(f.map(\.index), [2, nil])
        XCTAssertEqual(f[0].upcoming, [])
        XCTAssertEqual(f[1].current, "♪ 等待下一首")
    }

    /// 逐句模式不受影響：每句一格、只列下一句
    func testPerLineModeUnchanged() {
        let lines = Fixture.lines(count: 6)
        let f = snapshot(lines: lines, mode: .perLine).frames(from: t0.addingTimeInterval(2))
        XCTAssertEqual(f.map(\.index), [0, 1, 2, 3, 4, 5, nil])
        XCTAssertEqual(Array(f.map(\.date).dropFirst().dropLast()),
                       lines.dropFirst().map { t0.addingTimeInterval($0.time) })
        for frame in f.dropLast() {
            XCTAssertLessThanOrEqual(frame.upcoming.count, 1)
        }
        XCTAssertEqual(f[0].upcoming, ["測試第2句"])
        XCTAssertEqual(f.last?.current, "♪ 等待下一首")
    }
}
