import XCTest

// 第四輪修正的回歸測試（內容全部自編）

final class IdlePolicyCarTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let p = IdlePolicy()

    func testNonMusicLimits() {
        XCTAssertEqual(p.limit(for: .nonMusic), 3600)
        // 廣告 / Podcast 播放中：60 分鐘才停
        XCTAssertFalse(p.shouldStop(kind: .nonMusic, since: t0, now: t0.addingTimeInterval(3599), isForeground: false))
        XCTAssertTrue(p.shouldStop(kind: .nonMusic, since: t0, now: t0.addingTimeInterval(3601), isForeground: false))
        // 暫停後回到 30 分鐘
        XCTAssertTrue(p.shouldStop(kind: .paused, since: t0, now: t0.addingTimeInterval(1801), isForeground: false))
    }

    func testCarConnectedExtendsLimits() {
        XCTAssertEqual(p.limit(for: .nothing, carConnected: true), 1800)
        XCTAssertFalse(p.shouldStop(kind: .nothing, since: t0, now: t0.addingTimeInterval(1000),
                                    isForeground: false, carConnected: true))
        XCTAssertTrue(p.shouldStop(kind: .nothing, since: t0, now: t0.addingTimeInterval(1801),
                                   isForeground: false, carConnected: true))
    }
}

final class TimelineRoundFourTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 30_000)

    private func playing(offset: TimeInterval = 0, duration: TimeInterval = 60,
                         lines: [LyricLine]? = nil, start: Date? = nil) -> LyricsTimelineSnapshot {
        LyricsTimelineSnapshot(trackID: "a", title: "測試歌", artist: "測試歌手",
                               lines: lines ?? Fixture.lines(count: 3), songStart: start ?? t0,
                               isPlaying: true, message: nil, updatedAt: t0,
                               appliedOffset: offset, duration: duration)
    }

    /// C-1：沒在播放 / 沒有歌詞時起點不影響畫面 → 不可以每次輪詢都重新整理
    func testIdleSnapshotsAreSameEvenSecondsApart() {
        let a = LyricsTimelineSnapshot.idle("Spotify 沒有在播放", at: t0)
        let b = LyricsTimelineSnapshot.idle("Spotify 沒有在播放", at: t0.addingTimeInterval(30))
        XCTAssertTrue(a.isSameTimeline(as: b))
        XCTAssertTrue(a.isStatic)
        // 訊息不同仍然要更新
        XCTAssertFalse(a.isSameTimeline(as: .idle("廣告播放中", at: t0)))
    }

    func testPausedSnapshotsAreSame() {
        var a = playing()
        a.isPlaying = false
        a.message = "⏸ 測試第1句"
        var b = a
        b.songStart = t0.addingTimeInterval(60)
        XCTAssertTrue(a.isSameTimeline(as: b))
    }

    /// C-7：只有起點漂移 → 重寫檔案但不重新整理
    func testNeedsFileRefreshOnlyForDrift() {
        let a = playing()
        XCTAssertTrue(playing(start: t0.addingTimeInterval(0.5)).needsFileRefresh(comparedTo: a))
        XCTAssertFalse(playing(start: t0.addingTimeInterval(0.2)).needsFileRefresh(comparedTo: a))
        // 歌詞不同 → 不是漂移，要走正常 publish
        XCTAssertFalse(playing(lines: Fixture.lines(count: 2)).needsFileRefresh(comparedTo: a))
        var paused = playing()
        paused.isPlaying = false
        XCTAssertFalse(paused.needsFileRefresh(comparedTo: a))
    }

    /// F-5：時間軸最後補一格「等待下一首」
    func testTailFrameAfterSongEnd() {
        let f = playing().frames(from: t0)
        XCTAssertEqual(f.last?.current, "♪ 等待下一首")
        XCTAssertEqual(f.last?.date, t0.addingTimeInterval(63))
        XCTAssertNil(f.last?.index)
        // 長度未知時不補
        XCTAssertNotEqual(playing(duration: 0).frames(from: t0).last?.current, "♪ 等待下一首")
        // 只取前面幾句時也不補
        XCTAssertNotEqual(playing().frames(from: t0, limit: 1).last?.current, "♪ 等待下一首")
    }

    func testTailFrameSkippedWhenSongAlreadyOver() {
        // 已經播到結尾之後：最後一格的時間不會倒退
        let f = playing(duration: 1).frames(from: t0.addingTimeInterval(30))
        XCTAssertNotEqual(f.last?.current, "♪ 等待下一首")
    }

    /// F-4：間奏倒數
    func testCountdownInterval() {
        let lines = [LyricLine(time: 1, text: "測試第1句"), LyricLine(time: 30, text: "測試第2句")]
        let f = playing(lines: lines).frames(from: t0.addingTimeInterval(2))
        XCTAssertEqual(f[0].current, "測試第1句")
        XCTAssertEqual(f[0].nextLineAt, t0.addingTimeInterval(30))
        XCTAssertNil(f[0].countdownInterval(from: t0.addingTimeInterval(2)))   // 有歌詞就不倒數
        let gap = [LyricLine(time: 1, text: ""), LyricLine(time: 30, text: "測試第2句")]
        let g = playing(lines: gap).frames(from: t0.addingTimeInterval(2))
        XCTAssertEqual(g[0].current, "♪")
        XCTAssertEqual(g[0].countdownInterval(from: t0.addingTimeInterval(2))?.upperBound, t0.addingTimeInterval(30))
        // 剩不到 5 秒就不顯示倒數
        XCTAssertNil(g[0].countdownInterval(from: t0.addingTimeInterval(27)))
        // 最後一句之後沒有 nextLineAt
        XCTAssertNil(playing(lines: gap).frames(from: t0.addingTimeInterval(31))[0].nextLineAt)
    }
}

final class ActivityEquivalenceTests: XCTestCase {
    private let base = ActivityContentModel(currentLine: "測試第1句", nextLine: "測試第2句", trackName: "測試歌",
                                            artistName: "測試歌手", isPlaying: true,
                                            songStart: Date(timeIntervalSince1970: 100),
                                            songEnd: Date(timeIntervalSince1970: 300),
                                            artworkFile: "a.jpg", nextLineAt: Date(timeIntervalSince1970: 120))

    /// C-5：Date 精度差不能被當成「系統沒有套用」
    func testDateToleranceIsIgnored() {
        var other = base
        other.songStart = base.songStart?.addingTimeInterval(0.4)
        other.songEnd = base.songEnd?.addingTimeInterval(-0.4)
        other.nextLineAt = base.nextLineAt?.addingTimeInterval(0.9)
        XCTAssertTrue(base.isEquivalent(to: other))
        XCTAssertNil(base.mismatchField(comparedTo: other))
    }

    func testEachFieldIsReported() {
        func field(_ change: (inout ActivityContentModel) -> Void) -> String? {
            var o = base
            change(&o)
            return base.mismatchField(comparedTo: o)
        }
        XCTAssertEqual(field { $0.currentLine = "x" }, "currentLine")
        XCTAssertEqual(field { $0.nextLine = "x" }, "nextLine")
        XCTAssertEqual(field { $0.trackName = "x" }, "trackName")
        XCTAssertEqual(field { $0.artistName = "x" }, "artistName")
        XCTAssertEqual(field { $0.isPlaying = false }, "isPlaying")
        XCTAssertEqual(field { $0.artworkFile = nil }, "artworkFile")
        XCTAssertEqual(field { $0.songStart = $0.songStart?.addingTimeInterval(5) }, "songStart")
        XCTAssertEqual(field { $0.songEnd = nil }, "songEnd")
        XCTAssertEqual(field { $0.nextLineAt = $0.nextLineAt?.addingTimeInterval(9) }, "nextLineAt")
        var empty = base
        empty.songStart = nil
        empty.songEnd = nil
        empty.nextLineAt = nil
        XCTAssertEqual(empty.mismatchField(comparedTo: empty), nil)
        XCTAssertFalse(empty.isEquivalent(to: base))
    }

    /// 間奏時才帶倒數時刻
    func testBuilderOnlySetsCountdownForInstrumentalGap() {
        let np = Fixture.nowPlaying()
        let lines = [LyricLine(time: 1, text: ""), LyricLine(time: 30, text: "測試第2句")]
        let gap = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines),
                                                   display: LyricsDisplay(lines: lines, position: 2),
                                                   songStart: nil, artworkFile: nil,
                                                   nextLineAt: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(gap.currentLine, "♪")
        XCTAssertEqual(gap.nextLineAt, Date(timeIntervalSince1970: 500))
        let normal = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .synced(lines),
                                                      display: LyricsDisplay(lines: lines, position: 31),
                                                      songStart: nil, artworkFile: nil,
                                                      nextLineAt: Date(timeIntervalSince1970: 500))
        XCTAssertNil(normal.nextLineAt)
    }
}

final class RoundFourMiscTests: XCTestCase {
    func testSessionIsNonMusic() {
        XCTAssertTrue(SessionState.nonMusic(.ad).isNonMusic)
        XCTAssertFalse(SessionState.playing.isNonMusic)
    }

    func testMonotonicClockAdvances() {
        let a = AppClock.monotonicSeconds()
        let b = AppClock.monotonicSeconds()
        XCTAssertGreaterThanOrEqual(b, a)
        XCTAssertGreaterThan(a, 0)
    }

    func testNewPreferences() {
        let suite = "RoundFour.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let p = Preferences(defaults: d)
        XCTAssertFalse(p.focusLandscapeLock)
        XCTAssertTrue(p.autoFocusInCar)
        XCTAssertNil(p.pendingScreen)
        p.focusLandscapeLock = true
        p.autoFocusInCar = false
        p.pendingScreen = "focus"
        XCTAssertTrue(p.focusLandscapeLock)
        XCTAssertFalse(p.autoFocusInCar)
        XCTAssertEqual(p.pendingScreen, "focus")
        p.pendingScreen = nil
        XCTAssertNil(p.pendingScreen)
    }

    func testLiveActivityModeAndIdleDefaults() {
        let suite = "LAMode.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let p = Preferences(defaults: d)
        // 預設：開車時才顯示、沒在播放時收起
        XCTAssertEqual(p.liveActivityMode, .whileDriving)
        XCTAssertTrue(p.endActivityWhenIdle)
        p.liveActivityMode = .always
        XCTAssertTrue(p.liveActivityEnabled)
        XCTAssertFalse(p.liveActivityOnlyInCar)
        XCTAssertEqual(p.liveActivityMode, .always)
        p.liveActivityMode = .off
        XCTAssertFalse(p.liveActivityEnabled)
        XCTAssertEqual(p.liveActivityMode, .off)
        p.liveActivityMode = .whileDriving
        XCTAssertEqual(p.liveActivityMode, .whileDriving)
        p.endActivityWhenIdle = false
        XCTAssertFalse(p.endActivityWhenIdle)
        XCTAssertEqual(LiveActivityMode.allCases.map(\.label), ["開車時", "一律顯示", "關閉"])
    }
}
