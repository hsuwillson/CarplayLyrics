import XCTest

/// 第七輪：即時動態的「接下來幾句」視窗、stale 時依視窗推進、背景被擋期間的探測節奏。內容全部自編。

final class ActivityUpcomingLineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 5_000)

    func testInitDefaultsAndProgressInterval() {
        let noEnd = ActivityUpcomingLine(text: "測試第1句", startAt: t0)
        XCTAssertNil(noEnd.endAt)
        XCTAssertNil(noEnd.progressInterval)
        let ok = ActivityUpcomingLine(text: "測試第1句", startAt: t0, endAt: t0.addingTimeInterval(3))
        XCTAssertEqual(ok.progressInterval, t0...t0.addingTimeInterval(3))
        let bad = ActivityUpcomingLine(text: "測試第1句", startAt: t0, endAt: t0)
        XCTAssertNil(bad.progressInterval)
    }

    func testMismatchReportsUpcoming() {
        let window = [ActivityUpcomingLine(text: "測試第2句", startAt: t0, endAt: t0.addingTimeInterval(3)),
                      ActivityUpcomingLine(text: "測試第3句", startAt: t0.addingTimeInterval(3))]
        let base = ActivityContentModel(currentLine: "測試第1句", nextLine: "測試第2句", trackName: "測試歌名",
                                        artistName: "測試歌手", isPlaying: true, upcoming: window)
        XCTAssertNil(base.mismatchField(comparedTo: base))
        // 兩邊都沒有視窗
        var none = base
        none.upcoming = nil
        XCTAssertNil(none.mismatchField(comparedTo: none))
        XCTAssertEqual(base.mismatchField(comparedTo: none), "upcoming")
        // 句數不同
        var fewer = base
        fewer.upcoming = [window[0]]
        XCTAssertEqual(base.mismatchField(comparedTo: fewer), "upcoming")
        // 文字不同
        var text = base
        text.upcoming?[1].text = "測試第9句"
        XCTAssertEqual(base.mismatchField(comparedTo: text), "upcoming")
        // 時刻在容許誤差內 → 相同；超過 → 不同
        var near = base
        near.upcoming?[0].startAt = t0.addingTimeInterval(0.4)
        near.upcoming?[0].endAt = t0.addingTimeInterval(3.4)
        XCTAssertNil(base.mismatchField(comparedTo: near))
        XCTAssertTrue(base.isEquivalent(to: near, tolerance: 0.5))
        var far = base
        far.upcoming?[0].endAt = t0.addingTimeInterval(9)
        XCTAssertEqual(base.mismatchField(comparedTo: far), "upcoming")
        var lostEnd = base
        lostEnd.upcoming?[0].endAt = nil
        XCTAssertEqual(base.mismatchField(comparedTo: lostEnd), "upcoming")
    }

    func testBuilderKeepsWindowOnlyWhilePlayingWithLyrics() {
        let np = Fixture.nowPlaying()
        let lines = Fixture.lines(count: 4)
        let display = LyricsDisplay(lines: lines, position: 4.5)
        let window = [ActivityUpcomingLine(text: "測試第3句", startAt: t0, endAt: t0.addingTimeInterval(3))]
        let playing = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines), display: display,
                                                       songStart: nil, artworkFile: nil, upcoming: window)
        XCTAssertEqual(playing.upcoming, window)
        // 預設不帶
        let plain = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines), display: display,
                                                     songStart: nil, artworkFile: nil)
        XCTAssertNil(plain.upcoming)
        // 空視窗 → nil
        let empty = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines), display: display,
                                                     songStart: nil, artworkFile: nil, upcoming: [])
        XCTAssertNil(empty.upcoming)
        // 暫停：畫面不該自己推進
        let paused = LiveActivityContentBuilder.build(nowPlaying: Fixture.nowPlaying(playing: false), lyrics: .synced(lines),
                                                      display: display, songStart: nil, artworkFile: nil, upcoming: window)
        XCTAssertNil(paused.upcoming)
        // 沒有同步歌詞
        let none = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .notFound, display: .empty,
                                                    songStart: nil, artworkFile: nil, upcoming: window)
        XCTAssertNil(none.upcoming)
        // 播完：不帶視窗
        let over = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines), display: display,
                                                    songStart: nil, artworkFile: nil, position: 200, upcoming: window)
        XCTAssertNil(over.upcoming)
    }

    /// 即時動態內容有 4 KB 上限：視窗塞滿 6 句（每句被政策截到 40 字）、其他欄位各 100 字也要在限制內
    func testEncodedSizeWithWindowStaysSmall() throws {
        let long = String(repeating: "測", count: 100)
        let policy = LiveActivityWindowPolicy()
        let rowText = policy.truncated(long)
        XCTAssertEqual(rowText.count, policy.maxCharacters)
        let window = (0..<policy.maxLines).map {
            ActivityUpcomingLine(text: rowText, startAt: t0.addingTimeInterval(Double($0) * 3),
                                 endAt: t0.addingTimeInterval(Double($0) * 3 + 3))
        }
        let m = ActivityContentModel(currentLine: long, nextLine: long, trackName: long, artistName: long,
                                     isPlaying: true, songStart: t0, songEnd: t0.addingTimeInterval(200),
                                     artworkFile: "x.jpg", nextLine2: long, lineStartAt: t0, lineEndAt: t0.addingTimeInterval(3),
                                     upcoming: window)
        struct Box: Encodable {
            let a, b, c, d, e: String
            let f, g, h, i: Date?
            let w: [ActivityUpcomingLine]?
        }
        let data = try JSONEncoder().encode(Box(a: m.currentLine, b: m.nextLine, c: m.trackName, d: m.artistName,
                                                e: m.nextLine2 ?? "", f: m.songStart, g: m.songEnd, h: m.lineStartAt,
                                                i: m.lineEndAt, w: m.upcoming))
        XCTAssertLessThan(data.count, 4096)
        let decoded = try JSONDecoder().decode([ActivityUpcomingLine].self, from: JSONEncoder().encode(window))
        XCTAssertEqual(decoded.count, 6)
        XCTAssertEqual(decoded[0].text, rowText)
    }
}

final class LiveActivityWindowPolicyTests: XCTestCase {
    private let policy = LiveActivityWindowPolicy()
    private let t0 = Date(timeIntervalSince1970: 20_000)

    func testDefaults() {
        // 第十輪：CarPlay 約每分鐘才重畫一次 → 視窗拉長到 75 秒、最多 6 句（CarPlay 卡片最多列 5 句 + 目前句）
        XCTAssertEqual(policy.seconds, 75)
        XCTAssertEqual(policy.minLines, 2)
        XCTAssertEqual(policy.maxLines, 6)
        XCTAssertEqual(policy.maxCharacters, 40)
    }

    /// 每 3 秒一句、共 10 句，目前在第 2 句（位置 4.5）：75 秒內全部會開始，但最多 6 句
    func testWindowCappedAtMaxLines() {
        let lines = Fixture.lines(count: 10)
        let w = policy.upcoming(lines: lines, currentIndex: 1, effectivePosition: 4.5, now: t0)
        XCTAssertEqual(w.map(\.text), ["測試第3句", "測試第4句", "測試第5句", "測試第6句", "測試第7句", "測試第8句"])
        // 第 3 句在 7 秒：距離現在 2.5 秒；結束 = 第 4 句開始（10 秒）
        XCTAssertEqual(w[0].startAt, t0.addingTimeInterval(2.5))
        XCTAssertEqual(w[0].endAt, t0.addingTimeInterval(5.5))
        XCTAssertEqual(w[5].endAt, t0.addingTimeInterval(20.5))
    }

    /// 句子很疏（每 60 秒一句）：時間窗只涵蓋一句，但至少帶 2 句
    func testWindowKeepsMinLinesWhenSparse() {
        let lines = Fixture.lines(count: 5, step: 60)
        let w = policy.upcoming(lines: lines, currentIndex: 0, effectivePosition: 2, now: t0)
        XCTAssertEqual(w.map(\.text), ["測試第2句", "測試第3句"])
        XCTAssertEqual(w[0].startAt, t0.addingTimeInterval(59))
        // 時間窗內有 5 句（每 15 秒）：位置 2 + 75 = 77，第 6 句在 76 秒 < 77 → 5 句；第 7 句 91 秒 → 不帶
        let mid = Fixture.lines(count: 8, step: 15)
        XCTAssertEqual(policy.upcoming(lines: mid, currentIndex: 0, effectivePosition: 2, now: t0).count, 5)
    }

    /// 太長的句子截斷加「…」（一列只顯示一行，也守住 4 KB）
    func testLongLinesAreTruncated() {
        let long = String(repeating: "測", count: 60)
        let lines = [LyricLine(time: 1, text: "測試第1句"), LyricLine(time: 4, text: long), LyricLine(time: 7, text: "測試第3句")]
        let w = policy.upcoming(lines: lines, currentIndex: 0, effectivePosition: 2, now: t0)
        XCTAssertEqual(w[0].text.count, 40)
        XCTAssertTrue(w[0].text.hasSuffix("…"))
        XCTAssertEqual(w[1].text, "測試第3句")
        XCTAssertEqual(policy.truncated(String(repeating: "測", count: 40)).count, 40)
        var tiny = policy
        tiny.maxCharacters = 1
        XCTAssertEqual(tiny.truncated("測試"), "測試", "上限 1 不截（沒有位置放省略號）")
    }

    func testWindowSkipsBlankLinesButUsesThemAsEnd() {
        let lines = [LyricLine(time: 1, text: "測試第1句"), LyricLine(time: 4, text: "測試第2句"),
                     LyricLine(time: 7, text: ""), LyricLine(time: 20, text: "測試第4句")]
        let w = policy.upcoming(lines: lines, currentIndex: 0, effectivePosition: 2, now: t0)
        XCTAssertEqual(w.map(\.text), ["測試第2句", "測試第4句"])
        // 第 2 句結束於空白句（7 秒）
        XCTAssertEqual(w[0].endAt, t0.addingTimeInterval(5))
        XCTAssertEqual(w[1].startAt, t0.addingTimeInterval(18))
        XCTAssertNil(w[1].endAt)
    }

    func testLastLineEndsAtSongEnd() {
        let lines = Fixture.lines(count: 3)
        let end = t0.addingTimeInterval(100)
        let w = policy.upcoming(lines: lines, currentIndex: 0, effectivePosition: 2, now: t0, songEnd: end)
        XCTAssertEqual(w.count, 2)
        XCTAssertEqual(w[1].endAt, end)
        // 歌曲結束時刻比這句開始還早（時間碼超出長度）：不給結束時刻
        let early = policy.upcoming(lines: lines, currentIndex: 0, effectivePosition: 2, now: t0, songEnd: t0)
        XCTAssertNil(early[1].endAt)
    }

    func testEdges() {
        let lines = Fixture.lines(count: 3)
        // 還沒到第一句：從第 1 句開始
        XCTAssertEqual(policy.upcoming(lines: lines, currentIndex: nil, effectivePosition: 0, now: t0).first?.text, "測試第1句")
        // 最後一句：沒有接下來
        XCTAssertTrue(policy.upcoming(lines: lines, currentIndex: 2, effectivePosition: 8, now: t0).isEmpty)
        XCTAssertTrue(policy.upcoming(lines: [], currentIndex: nil, effectivePosition: 0, now: t0).isEmpty)
        var custom = policy
        custom.maxLines = 1
        XCTAssertEqual(custom.upcoming(lines: lines, currentIndex: nil, effectivePosition: 0, now: t0).count, 1)
        XCTAssertNotEqual(custom, policy)
    }
}

final class LiveActivityStaleWindowTests: XCTestCase {
    private let policy = LiveActivityStalePolicy()
    private let t0 = Date(timeIntervalSince1970: 30_000)

    /// 目前第 1 句（t0…t0+3）；視窗：第 2 句 3–6、第 3 句 6–9、第 4 句 9–（結束未知）
    private func model(playing: Bool = true, window: [ActivityUpcomingLine]? = nil,
                       songEnd: TimeInterval? = 100, lineEndAt: TimeInterval? = 3) -> ActivityContentModel {
        let w = window ?? [
            ActivityUpcomingLine(text: "測試第2句", startAt: t0.addingTimeInterval(3), endAt: t0.addingTimeInterval(6)),
            ActivityUpcomingLine(text: "測試第3句", startAt: t0.addingTimeInterval(6), endAt: t0.addingTimeInterval(9)),
            ActivityUpcomingLine(text: "測試第4句", startAt: t0.addingTimeInterval(9)),
        ]
        return ActivityContentModel(currentLine: "測試第1句", nextLine: "測試第2句", trackName: "測試歌名",
                                    artistName: "測試歌手", isPlaying: playing,
                                    songStart: t0.addingTimeInterval(-10), songEnd: songEnd.map { t0.addingTimeInterval($0) },
                                    nextLine2: "測試第3句", lineStartAt: t0, lineEndAt: lineEndAt.map { t0.addingTimeInterval($0) },
                                    upcoming: w)
    }

    func testBeforeWindowStarts() {
        let m = model()
        // 目前句還在唱：維持原內容（視窗原樣帶著）
        let d = policy.display(for: m, now: t0.addingTimeInterval(1))
        XCTAssertEqual(d.kind, .unchanged)
        XCTAssertEqual(d.current, "測試第1句")
        XCTAssertEqual(d.upcoming.count, 3)
        // 目前句唱完但視窗第一句還沒開始（視窗第一句晚一點）：間奏
        let late = model(window: [ActivityUpcomingLine(text: "測試第2句", startAt: t0.addingTimeInterval(8))])
        let gap = policy.display(for: late, now: t0.addingTimeInterval(5))
        XCTAssertEqual(gap, LiveActivityStalePolicy.Display(kind: .advanced, current: "♪", next: "測試第2句",
                                                             upcoming: late.upcoming ?? []))
        // 不知道目前句何時結束：維持
        let unknownEnd = model(window: [ActivityUpcomingLine(text: "測試第2句", startAt: t0.addingTimeInterval(8))], lineEndAt: nil)
        XCTAssertEqual(policy.display(for: unknownEnd, now: t0.addingTimeInterval(5)).kind, .unchanged)
    }

    func testResolvesLineInsideWindow() {
        let m = model()
        let second = policy.display(for: m, now: t0.addingTimeInterval(4))
        XCTAssertEqual(second.kind, .advanced)
        XCTAssertEqual(second.current, "測試第2句")
        XCTAssertEqual(second.next, "測試第3句")
        XCTAssertEqual(second.upcoming.map(\.text), ["測試第3句", "測試第4句"])
        // 晚很多才重畫（例如解鎖時）也找得到正確的句子
        let third = policy.display(for: m, now: t0.addingTimeInterval(8.9))
        XCTAssertEqual(third.current, "測試第3句")
        XCTAssertEqual(third.upcoming.map(\.text), ["測試第4句"])
        // 最後一句不知道結束時刻：推進時間窗（15 秒）內當成還在唱
        let fourth = policy.display(for: m, now: t0.addingTimeInterval(20))
        XCTAssertEqual(fourth, LiveActivityStalePolicy.Display(kind: .advanced, current: "測試第4句", next: ""))
        // 空白文字（防禦）：顯示 ♪
        let blank = model(window: [ActivityUpcomingLine(text: "", startAt: t0.addingTimeInterval(3),
                                                        endAt: t0.addingTimeInterval(6))])
        XCTAssertEqual(policy.display(for: blank, now: t0.addingTimeInterval(4)).current, "♪")
    }

    func testInterludeAndExpiry() {
        // 第 2 句 3–6，第 3 句 10 才開始：6–10 是間奏
        let w = [ActivityUpcomingLine(text: "測試第2句", startAt: t0.addingTimeInterval(3), endAt: t0.addingTimeInterval(6)),
                 ActivityUpcomingLine(text: "測試第3句", startAt: t0.addingTimeInterval(10), endAt: t0.addingTimeInterval(13))]
        let m = model(window: w)
        let gap = policy.display(for: m, now: t0.addingTimeInterval(7))
        XCTAssertEqual(gap.kind, .advanced)
        XCTAssertEqual(gap.current, "♪")
        XCTAssertEqual(gap.next, "測試第3句")
        XCTAssertEqual(gap.upcoming.map(\.text), ["測試第3句"])
        // 視窗最後一句也唱完：不知道唱到哪
        let over = policy.display(for: m, now: t0.addingTimeInterval(14))
        XCTAssertEqual(over, LiveActivityStalePolicy.Display(kind: .expired, current: "歌詞沒跟上", next: "打開 CarLyrics 繼續同步歌詞"))
        // 結束未知的最後一句，推進時間窗過了 → 也算過期
        let unknown = model(window: [ActivityUpcomingLine(text: "測試第2句", startAt: t0.addingTimeInterval(3))])
        XCTAssertEqual(policy.display(for: unknown, now: t0.addingTimeInterval(19)).kind, .expired)
    }

    func testSongOverAndPausedStillWin() {
        let m = model()
        XCTAssertEqual(policy.display(for: m, now: t0.addingTimeInterval(100)).kind, .songOver)
        let paused = policy.display(for: model(playing: false), now: t0.addingTimeInterval(50))
        XCTAssertEqual(paused.kind, .unchanged)
        XCTAssertEqual(paused.upcoming.count, 3)
        // 沒有視窗的舊內容：走原本的一步推進
        let old = model(window: [])
        XCTAssertEqual(policy.display(for: old, now: t0.addingTimeInterval(4)).current, "測試第2句")
        XCTAssertTrue(policy.display(for: old, now: t0.addingTimeInterval(4)).upcoming.isEmpty)
    }

    /// 端到端：staleDate（下一句 + 2 秒）那一刻依視窗顯示下一句，視窗留著之後的句子
    func testStaleDateThenWindowDisplay() {
        let m = model()
        let stale = policy.staleDate(for: m, now: t0)
        XCTAssertEqual(stale, t0.addingTimeInterval(5))
        let d = policy.display(for: m, now: stale)
        XCTAssertEqual(d.kind, .advanced)
        XCTAssertEqual(d.current, "測試第2句")
        XCTAssertEqual(d.upcoming.map(\.text), ["測試第3句", "測試第4句"])
    }
}

final class LiveActivityCadencePolicyTests: XCTestCase {
    func testDefaults() {
        let p = LiveActivityCadencePolicy()
        XCTAssertEqual(p.levels, [5, 15, 30, 60, 120])
        XCTAssertEqual(p.startLevel, 1)
        XCTAssertEqual(p.level, 1)
        XCTAssertEqual(p.interval, 15)
        XCTAssertEqual(p.escalateAfter, 3)
        XCTAssertEqual(p.relaxAfter, 2)
        XCTAssertEqual(p.buckets.count, 5)
        XCTAssertEqual(p.summary, "尚無背景送出")
        XCTAssertEqual(p.perLine, LiveActivityCadencePolicy.Bucket())
    }

    func testInitClampsAndDefaultsLevels() {
        XCTAssertEqual(LiveActivityCadencePolicy(levels: []).levels, [15])
        XCTAssertEqual(LiveActivityCadencePolicy(levels: [10, 20], startLevel: 9).level, 1)
        XCTAssertEqual(LiveActivityCadencePolicy(levels: [10, 20], startLevel: -1).level, 0)
        var p = LiveActivityCadencePolicy(levels: [10, 20], startLevel: 9)
        p.enterBlocked()
        XCTAssertEqual(p.level, 1)
        XCTAssertNotEqual(p, LiveActivityCadencePolicy())
    }

    /// 連續被擋 3 次放慢一級，最慢一級再被擋就不動
    func testEscalatesOnRejections() {
        var p = LiveActivityCadencePolicy()
        p.enterBlocked()
        p.recordProbeSent()
        XCTAssertEqual(p.record(accepted: false, latency: 2), .none)
        XCTAssertEqual(p.record(accepted: false, latency: 2), .none)
        XCTAssertEqual(p.record(accepted: false, latency: 2), .slower(30))
        XCTAssertEqual(p.interval, 30)
        XCTAssertEqual(p.rejectStreak, 0)
        for _ in 0..<3 { _ = p.record(accepted: false, latency: 2) }
        XCTAssertEqual(p.interval, 60)
        for _ in 0..<3 { _ = p.record(accepted: false, latency: 2) }
        XCTAssertEqual(p.interval, 120)
        for _ in 0..<5 { XCTAssertEqual(p.record(accepted: false, latency: 2), .none) }
        XCTAssertEqual(p.interval, 120)
        XCTAssertEqual(p.buckets[1].rejected, 3)
        XCTAssertEqual(p.buckets[1].sent, 1)
        XCTAssertEqual(p.buckets[4].rejected, 5)
        XCTAssertEqual(p.buckets[3].rejected, 3)
        XCTAssertEqual(p.summary, "15秒 0/1")
    }

    /// 被套用 2 次加快一級；最快一級再被套用 2 次就恢復逐句
    func testRelaxesOnAcceptance() {
        var p = LiveActivityCadencePolicy()
        p.enterBlocked()
        _ = p.record(accepted: false, latency: 2)
        XCTAssertEqual(p.record(accepted: true, latency: 0.8), .none)
        XCTAssertEqual(p.rejectStreak, 0)
        XCTAssertEqual(p.acceptStreak, 1)
        XCTAssertEqual(p.record(accepted: true, latency: 2), .faster(5))
        XCTAssertEqual(p.level, 0)
        XCTAssertEqual(p.acceptStreak, 0)
        XCTAssertEqual(p.record(accepted: true, latency: 0.8), .none)
        XCTAssertEqual(p.record(accepted: true, latency: 0.8), .resumePerLine)
        XCTAssertEqual(p.level, 0)
        XCTAssertEqual(p.buckets[1].accepted, 2)
        XCTAssertEqual(p.buckets[1].maxLatency, 2)
        XCTAssertEqual(p.buckets[0].accepted, 2)
        // 被擋打斷連續套用
        var q = LiveActivityCadencePolicy()
        _ = q.record(accepted: true, latency: 0.8)
        _ = q.record(accepted: false, latency: 2)
        XCTAssertEqual(q.acceptStreak, 0)
        XCTAssertEqual(q.rejectStreak, 1)
        // 再進入被擋：從起始級重來，統計保留
        p.enterBlocked()
        XCTAssertEqual(p.level, 1)
        XCTAssertEqual(p.buckets[0].accepted, 2)
    }

    func testPerLineBucketAndSummary() {
        var p = LiveActivityCadencePolicy()
        p.recordPerLineSent()
        p.recordPerLineSent()
        p.recordPerLine(accepted: false, latency: 2)
        p.recordPerLine(accepted: true, latency: 0.8)
        XCTAssertEqual(p.perLine.sent, 2)
        XCTAssertEqual(p.perLine.accepted, 1)
        XCTAssertEqual(p.perLine.rejected, 1)
        XCTAssertEqual(p.summary, "逐句 1/2（延遲 0.8s）")
        p.enterBlocked()
        p.recordProbeSent()
        _ = p.record(accepted: true, latency: 2)
        XCTAssertEqual(p.summary, "逐句 1/2（延遲 0.8s） · 15秒 1/1（延遲 2.0s）")
        var b = LiveActivityCadencePolicy.Bucket()
        b.record(accepted: false, latency: 2)
        XCTAssertEqual(b, LiveActivityCadencePolicy.Bucket(sent: 0, accepted: 0, rejected: 1, maxLatency: 0))
    }
}
