import XCTest

/// reducer 是「收到輪詢結果 → 改什麼狀態、做什麼事」的規格（docs/event-effects.md）
final class PlaybackReducerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 100_000)
    private var reducer = PlaybackReducer()
    private var state = PlaybackState()

    private func context(_ dt: TimeInterval = 0, foreground: Bool = false, car: Bool = false,
                         activity: Bool = true, endWhenIdle: Bool = false,
                         surface: PollPolicy.Surface = .foreground,
                         interrupted: Bool = false) -> PlaybackReducer.Context {
        PlaybackReducer.Context(now: t0.addingTimeInterval(dt), isForeground: foreground,
                                carConnected: car, activityIsActive: activity,
                                endActivityWhenIdle: endWhenIdle, surface: surface,
                                interrupted: interrupted)
    }

    private func play(_ np: NowPlaying, at dt: TimeInterval) -> PlayerPollResult {
        .playing(np, measuredAt: t0.addingTimeInterval(dt), sentAt: t0.addingTimeInterval(dt))
    }

    @discardableResult
    private func send(_ result: PlayerPollResult, _ ctx: PlaybackReducer.Context) -> PlaybackReducer.Output {
        reducer.reduce(&state, result: result, context: ctx)
    }

    // MARK: 播放

    func testFirstTrackLoadsLyricsAndPublishes() {
        let np = Fixture.nowPlaying()
        let out = send(play(np, at: 0), context())
        XCTAssertEqual(state.session, .playing)
        XCTAssertEqual(state.nowPlaying, np)
        XCTAssertEqual(out.effects, [.log("換歌：測試歌名 – 測試歌手"), .newTrack(np), .publishTimeline(debounce: true)])
        XCTAssertEqual(out.delay, 2.5)
    }

    func testOldResponseIsDropped() {
        send(play(Fixture.nowPlaying(), at: 5), context(5))
        let out = send(play(Fixture.nowPlaying(progress: 99), at: 1), context(6))
        XCTAssertEqual(out.effects, [.log("丟棄過期的輪詢回應")])
        XCTAssertEqual(out.delay, 1)
    }

    func testDriftOnlyRewritesFile() {
        send(play(Fixture.nowPlaying(progress: 10), at: 0), context())
        let out = send(play(Fixture.nowPlaying(progress: 12.4), at: 2.5), context(2.5))
        XCTAssertEqual(out.effects, [.refreshTimelineFile])
    }

    func testSeekAndPlayStateChange() {
        send(play(Fixture.nowPlaying(progress: 10), at: 0), context())
        let seek = send(play(Fixture.nowPlaying(progress: 90), at: 2.5), context(2.5))
        XCTAssertEqual(seek.effects, [.log("偵測到拖動進度 → 1:30"), .pushCurrent(important: true),
                                      .rescheduleTick, .publishTimeline(debounce: false)])
        let pause = send(play(Fixture.nowPlaying(playing: false, progress: 92), at: 5), context(5))
        XCTAssertEqual(pause.effects, [.log("暫停"), .pushCurrent(important: true),
                                       .rescheduleTick, .publishTimeline(debounce: true)])
        XCTAssertEqual(state.session, .paused)
        XCTAssertEqual(state.idleKind, .paused)
        XCTAssertEqual(pause.delay, 5)
    }

    func testStaleProgressPrefersFullPlayer() {
        send(play(Fixture.nowPlaying(progress: 10), at: 0), context())
        let out = send(play(Fixture.nowPlaying(progress: 10), at: 3), context(3))
        XCTAssertEqual(out.effects, [.log("Spotify 進度沒有前進（0:10），忽略並改用 /me/player 重試"), .refreshTimelineFile])
        XCTAssertTrue(state.preferFullPlayerEndpoint)
        XCTAssertEqual(out.delay, 1)
    }

    func testOptimisticGuardIgnoresContradiction() {
        send(play(Fixture.nowPlaying(progress: 10), at: 0), context())
        state.optimistic.arm(now: t0.addingTimeInterval(1))
        state.engine.update(PlaybackSnapshot(trackID: "track1", progress: 10, duration: 200,
                                             isPlaying: false, timestamp: t0.addingTimeInterval(1)))
        let out = send(play(Fixture.nowPlaying(progress: 11), at: 1.5), context(1.5))
        XCTAssertEqual(out.effects, [.log("樂觀更新保護：忽略延遲的回應")])
        XCTAssertTrue(state.preferFullPlayerEndpoint)
    }

    /// P2-4：使用者按了暫停（樂觀狀態 = 暫停）→ 保護窗內回傳「播放中」被忽略時，
    /// session 也不能先翻成播放中，否則狀態列會閃一下「播放中」而按鈕還是 ▶
    func testOptimisticGuardKeepsSessionUntilConfirmed() {
        send(play(Fixture.nowPlaying(progress: 10), at: 0), context())
        state.session = .paused
        state.optimistic.arm(now: t0.addingTimeInterval(1))
        state.engine.update(PlaybackSnapshot(trackID: "track1", progress: 10, duration: 200,
                                             isPlaying: false, timestamp: t0.addingTimeInterval(1)))
        send(play(Fixture.nowPlaying(progress: 11), at: 1.5), context(1.5))
        XCTAssertEqual(state.session, .paused)
        // 保護窗過了，Spotify 真的回報播放中 → 才跟著變
        send(play(Fixture.nowPlaying(progress: 13), at: 3.5), context(3.5))
        XCTAssertEqual(state.session, .playing)
    }

    func testNearTrackEndPollsSooner() {
        let np = Fixture.nowPlaying(progress: 199, duration: 200)
        let out = send(play(np, at: 0), context())
        XCTAssertEqual(out.delay, 1.4, accuracy: 0.001)
    }

    func testResumeAfterPause() {
        send(play(Fixture.nowPlaying(progress: 10), at: 0), context())
        send(play(Fixture.nowPlaying(playing: false, progress: 12.4), at: 2.5), context(2.5))
        let resume = send(play(Fixture.nowPlaying(progress: 12.4), at: 5), context(5))
        XCTAssertEqual(resume.effects.first, .log("繼續播放"))
        XCTAssertEqual(state.session, .playing)
        XCTAssertNil(state.idleKind)
    }

    func testPausedTooLongStopsBackground() {
        send(play(Fixture.nowPlaying(progress: 10), at: 0), context())
        send(play(Fixture.nowPlaying(playing: false, progress: 10), at: 1), context(1))
        let out = send(play(Fixture.nowPlaying(playing: false, progress: 10), at: 1802), context(1802))
        XCTAssertEqual(out.effects.suffix(3), [.endActivity, .publishIdle("打開 CarLyrics 繼續同步歌詞"),
                                               .stopForIdle(minutes: 30)])
        XCTAssertEqual(out.delay, 30)
    }

    func testUnknownDurationStillPolls() {
        let out = send(play(Fixture.nowPlaying(duration: 0), at: 0), context())
        XCTAssertEqual(out.delay, 2.5)
    }

    func testAdBackToStaleProgressAlsoPushes() {
        send(play(Fixture.nowPlaying(progress: 10), at: 0), context())
        send(.nonMusic(.ad, isPlaying: true), context(2))
        // 廣告後 Spotify 先回傳過期進度
        let out = send(play(Fixture.nowPlaying(progress: 10), at: 4), context(4))
        XCTAssertEqual(out.effects.last, .pushCurrent(important: true))
        XCTAssertTrue(state.preferFullPlayerEndpoint)
    }

    // MARK: 廣告 / Podcast

    func testAdOnlyPublishesOnce() {
        let first = send(.nonMusic(.ad, isPlaying: true), context())
        XCTAssertEqual(first.effects, [.log("廣告播放中"), .pushNonMusic(.ad), .publishIdle("廣告播放中")])
        XCTAssertEqual(state.idleKind, .nonMusic)
        let second = send(.nonMusic(.ad, isPlaying: true), context(5))
        XCTAssertEqual(second.effects, [])
        XCTAssertEqual(second.delay, 5)
    }

    func testPodcastPausedUsesPausedThreshold() {
        send(.nonMusic(.episode, isPlaying: false), context())
        XCTAssertEqual(state.idleKind, .paused)
        // 30 分鐘後停止
        let out = send(.nonMusic(.episode, isPlaying: false), context(1801))
        XCTAssertEqual(out.effects, [.endActivity, .publishIdle("打開 CarLyrics 繼續同步歌詞"), .stopForIdle(minutes: 30)])
        XCTAssertEqual(out.delay, 30)
    }

    func testAdBackToMusicPushesImmediately() {
        send(play(Fixture.nowPlaying(progress: 10), at: 0), context())
        send(.nonMusic(.ad, isPlaying: true), context(3))
        // 廣告結束，同一首歌繼續（change == .none）
        let out = send(play(Fixture.nowPlaying(progress: 16), at: 6), context(6))
        XCTAssertEqual(state.session, .playing)
        XCTAssertEqual(out.effects, [.refreshTimelineFile, .pushCurrent(important: true)])
    }

    // MARK: 沒有在播放

    func testNothingNeedsTwoResponsesAndPublishesOnce() {
        send(play(Fixture.nowPlaying(), at: 0), context())
        let first = send(.nothing, context(1))
        XCTAssertEqual(first.effects, [])
        XCTAssertEqual(first.delay, 3)
        let second = send(.nothing, context(2))
        XCTAssertEqual(second.effects, [.log("Spotify 沒有在播放"), .clearPlayback, .pushStopped,
                                        .publishIdle("Spotify 沒有在播放")])
        XCTAssertEqual(second.delay, 10)
        // C-1：之後每次輪詢都不能再重新整理小工具
        for i in 3...6 {
            XCTAssertEqual(send(.nothing, context(TimeInterval(i))).effects, [])
        }
    }

    func testNothingWithoutActivitySkipsPush() {
        send(.nothing, context(activity: false))
        let out = send(.nothing, context(1, activity: false))
        XCTAssertEqual(out.effects, [.publishIdle("Spotify 沒有在播放")])
    }

    func testIdleStopsAfterTenMinutes() {
        send(.nothing, context())
        send(.nothing, context(1))
        let out = send(.nothing, context(602))
        XCTAssertEqual(out.effects, [.endActivity, .publishIdle("打開 CarLyrics 繼續同步歌詞"), .stopForIdle(minutes: 10)])
    }

    func testCarConnectedDelaysIdleStop() {
        send(.nothing, context(car: true))
        send(.nothing, context(1, car: true))
        XCTAssertEqual(send(.nothing, context(601, car: true)).effects, [])
        let out = send(.nothing, context(1802, car: true))
        XCTAssertEqual(out.effects, [.endActivity, .publishIdle("打開 CarLyrics 繼續同步歌詞"), .stopForIdle(minutes: 30)])
    }

    func testForegroundNeverStops() {
        send(.nothing, context(foreground: true))
        send(.nothing, context(1, foreground: true))
        XCTAssertEqual(send(.nothing, context(9999, foreground: true)).effects, [])
    }

    // MARK: 其他

    func testRateLimitAndQuota() {
        let limited = send(.rateLimited(retryAfter: 7, quotaExceeded: false), context())
        XCTAssertEqual(limited.effects, [.log("HTTP 429，Retry-After 7 秒")])
        XCTAssertEqual(limited.delay, 7)
        let quota = send(.rateLimited(retryAfter: 5, quotaExceeded: true), context())
        XCTAssertEqual(quota.effects, [.log("HTTP 429，Retry-After 5 秒（配額用完）")])
        XCTAssertTrue(state.quotaActive(now: t0.addingTimeInterval(100)))
        XCTAssertFalse(state.quotaActive(now: t0.addingTimeInterval(4000)))
        // 配額模式下播放中也放慢
        XCTAssertEqual(send(play(Fixture.nowPlaying(), at: 1), context(1)).delay, 6)
    }

    func testErrorBackoffAndIdleStop() {
        XCTAssertEqual(reducer.error(&state, context: context()).delay, 5)
        XCTAssertEqual(reducer.error(&state, context: context()).delay, 10)
        state.markIdle(.nothing, at: t0)
        let out = reducer.error(&state, context: context(601))
        XCTAssertEqual(out.effects, [.endActivity, .publishIdle("打開 CarLyrics 繼續同步歌詞"), .stopForIdle(minutes: 10)])
        // 成功一次就歸零
        send(play(Fixture.nowPlaying(), at: 700), context(700))
        XCTAssertEqual(state.errorStreak, 0)
    }

    func testIdleMarkers() {
        var s = PlaybackState()
        s.markIdle(.paused, at: t0)
        s.markIdle(.paused, at: t0.addingTimeInterval(60))
        XCTAssertEqual(s.idleSince, t0)          // 同一種閒置不重新計時
        s.markIdle(.nothing, at: t0.addingTimeInterval(60))
        XCTAssertEqual(s.idleSince, t0.addingTimeInterval(60))
        s.clearIdle()
        XCTAssertNil(s.idleKind)
        XCTAssertNil(s.idleSince)
    }

    func testContextUsesSeparateMonotonicClock() {
        let ctx = PlaybackReducer.Context(now: t0, monotonicNow: t0.addingTimeInterval(-50), isForeground: true)
        XCTAssertEqual(ctx.monotonicNow, t0.addingTimeInterval(-50))
        XCTAssertTrue(ctx.isForeground)
        send(play(Fixture.nowPlaying(), at: 0), ctx)
        XCTAssertEqual(state.session, .playing)
    }

    func testFormatTime() {
        XCTAssertEqual(formatTime(0), "0:00")
        XCTAssertEqual(formatTime(-5), "0:00")
        XCTAssertEqual(formatTime(75), "1:15")
        XCTAssertEqual(formatTime(3600), "60:00")
    }

    // MARK: 靈動島不要被佔用

    /// 播過歌之後，沒在播放 30 秒結束即時動態；只送一次，而且不停止背景執行
    func testActivityEndsAfterNothingWhenEnabled() {
        send(play(Fixture.nowPlaying(), at: 0), context(0, endWhenIdle: true))
        send(.nothing, context(1, endWhenIdle: true))
        let start = send(.nothing, context(10, endWhenIdle: true))
        XCTAssertTrue(start.effects.contains(.pushStopped))
        XCTAssertFalse(start.effects.contains(.endActivity))

        let end = send(.nothing, context(45, endWhenIdle: true))
        XCTAssertEqual(end.effects, [.endActivity])
        XCTAssertTrue(state.activityEndedForIdle)

        let again = send(.nothing, context(60, endWhenIdle: true))
        XCTAssertTrue(again.effects.isEmpty, "已經結束過就不再送")
    }

    /// 還沒播過任何歌（先開 CarLyrics 再去 Spotify 按播放）：不收起，否則背景開不回來
    func testNothingBeforeAnySongKeepsActivity() {
        send(.nothing, context(0, endWhenIdle: true))
        send(.nothing, context(10, endWhenIdle: true))
        let out = send(.nothing, context(300, endWhenIdle: true))
        XCTAssertFalse(out.effects.contains(.endActivity))
        XCTAssertFalse(state.hasPlayed)
    }

    /// 連著車用音訊時「沒在播放」改用暫停的停止門檻（30 分鐘）。
    /// P0-1 之前是 5 分鐘：切換音源、等人的時候即時動態就沒了，而且背景開不回來。
    func testCarConnectedNothingUsesPauseThreshold() {
        send(play(Fixture.nowPlaying(), at: 0), context(0, car: true, endWhenIdle: true))
        send(.nothing, context(1, car: true, endWhenIdle: true))
        send(.nothing, context(10, car: true, endWhenIdle: true))
        XCTAssertFalse(send(.nothing, context(60, car: true, endWhenIdle: true)).effects.contains(.endActivity))
        XCTAssertFalse(send(.nothing, context(400, car: true, endWhenIdle: true)).effects.contains(.endActivity))
        XCTAssertFalse(send(.nothing, context(1700, car: true, endWhenIdle: true)).effects.contains(.endActivity))
        // 閒置從第二次「沒在播放」（10 秒）起算；前景不會走「閒置停止」，
        // 所以這裡的 endActivity 純粹來自即時動態的閒置門檻
        let out = send(.nothing, context(1815, foreground: true, car: true, endWhenIdle: true))
        XCTAssertEqual(out.effects, [.endActivity])
    }

    /// P0-1：在車上暫停 20 分鐘（得來速、等人、講電話）→ 即時動態留著，整趟車都還有歌詞
    func testPausedInCarKeepsActivity() {
        send(play(Fixture.nowPlaying(), at: 0), context(0, car: true, endWhenIdle: true))
        let paused = Fixture.nowPlaying(playing: false)
        send(play(paused, at: 0.5), context(0.5, car: true, endWhenIdle: true))
        for dt in [120.0, 400, 1200, 1700] {
            let out = send(play(paused, at: dt), context(dt, car: true, endWhenIdle: true))
            XCTAssertFalse(out.effects.contains(.endActivity), "\(Int(dt)) 秒")
            XCTAssertFalse(out.effects.contains(.stopForIdle(minutes: 90)), "\(Int(dt)) 秒")
        }
        XCTAssertFalse(state.activityEndedForIdle)
        // 不在車上的舊行為不變：5 分鐘後收
        XCTAssertTrue(send(play(paused, at: 1800), context(1800, endWhenIdle: true)).effects.contains(.endActivity))
    }

    /// P0-1：音訊中斷中（講電話）不算閒置：不收即時動態、也不停止背景執行
    func testInterruptionNeverEndsOrStops() {
        send(play(Fixture.nowPlaying(), at: 0), context(0, endWhenIdle: true))
        let paused = Fixture.nowPlaying(playing: false)
        send(play(paused, at: 1), context(1, endWhenIdle: true, interrupted: true))
        let later = send(play(paused, at: 400), context(400, endWhenIdle: true, interrupted: true))
        XCTAssertFalse(later.effects.contains(.endActivity))
        XCTAssertFalse(state.activityEndedForIdle)
        // 超過 30 分鐘的停止門檻也一樣
        let long = send(play(paused, at: 1900), context(1900, endWhenIdle: true, interrupted: true))
        XCTAssertFalse(long.effects.contains(.stopForIdle(minutes: 30)))
        XCTAssertFalse(long.effects.contains(.endActivity))
        XCTAssertEqual(long.delay, 20)
        // 輪詢錯誤與「沒在播放」的路徑也受同一個保護
        XCTAssertEqual(reducer.error(&state, context: context(1901, interrupted: true)).effects, [])
        // 中斷結束（且 Spotify 還沒續播）→ 回到正常的閒置規則
        let after = send(play(paused, at: 1902), context(1902, endWhenIdle: true))
        XCTAssertEqual(after.effects.suffix(3), [.endActivity, .publishIdle("打開 CarLyrics 繼續同步歌詞"),
                                                 .stopForIdle(minutes: 30)])
    }

    /// 設定關掉時維持舊行為：即時動態留著
    func testActivityStaysWhenSettingOff() {
        send(.nothing, context(0))
        send(.nothing, context(10))
        let out = send(.nothing, context(120))
        XCTAssertFalse(out.effects.contains(.endActivity))
    }

    /// 暫停只是等紅燈：5 分鐘內不收起
    func testPausedKeepsActivityForFiveMinutes() {
        send(play(Fixture.nowPlaying(), at: 0), context(0, endWhenIdle: true))
        let paused = Fixture.nowPlaying(playing: false)
        send(play(paused, at: 0.5), context(0.5, endWhenIdle: true))
        let soon = send(play(paused, at: 120), context(120, endWhenIdle: true))
        XCTAssertFalse(soon.effects.contains(.endActivity))
        let later = send(play(paused, at: 400), context(400, endWhenIdle: true))
        XCTAssertTrue(later.effects.contains(.endActivity))
    }

    /// 廣告 / Podcast 還在播：不收起（人還在聽，只是沒有歌詞）
    func testNonMusicKeepsActivity() {
        send(.nonMusic(.ad, isPlaying: true), context(0, endWhenIdle: true))
        let out = send(.nonMusic(.ad, isPlaying: true), context(600, endWhenIdle: true))
        XCTAssertFalse(out.effects.contains(.endActivity))
    }

    // MARK: 省電輪詢

    /// 剛換歌維持最快；穩定播放後依看得到的畫面放慢，接近結尾仍然提早問
    func testPollingSlowsDownWhenSteadyAndHidden() {
        let np = Fixture.nowPlaying(progress: 10, duration: 200)
        let first = send(play(np, at: 0), context(0, surface: .hidden))
        XCTAssertEqual(first.delay, 2.5, "換歌後 10 秒內維持最快")
        let steady = send(play(Fixture.nowPlaying(progress: 25, duration: 200), at: 15), context(15, surface: .hidden))
        XCTAssertEqual(steady.delay, 15)
        let visible = send(play(Fixture.nowPlaying(progress: 30, duration: 200), at: 20), context(20, surface: .visible))
        XCTAssertEqual(visible.delay, 5)
        let nearEnd = send(play(Fixture.nowPlaying(progress: 195, duration: 200), at: 185),
                           context(185, surface: .hidden))
        XCTAssertLessThan(nearEnd.delay, 15)
    }

    /// 暫停越久問得越少
    func testPausedBackoff() {
        send(play(Fixture.nowPlaying(), at: 0), context())
        let soon = send(play(Fixture.nowPlaying(playing: false), at: 1), context(1))
        XCTAssertEqual(soon.delay, 5)
        let later = send(play(Fixture.nowPlaying(playing: false), at: 300), context(300))
        XCTAssertEqual(later.delay, 10)
        let long = send(play(Fixture.nowPlaying(playing: false), at: 900), context(900, foreground: true))
        XCTAssertEqual(long.delay, 20)
    }

    /// 本來就沒有即時動態：不用送結束
    func testNoActivityNothingToEnd() {
        send(play(Fixture.nowPlaying(), at: 0), context(0, activity: false, endWhenIdle: true))
        send(.nothing, context(1, activity: false, endWhenIdle: true))
        send(.nothing, context(10, activity: false, endWhenIdle: true))
        let out = send(.nothing, context(45, activity: false, endWhenIdle: true))
        XCTAssertFalse(out.effects.contains(.endActivity))
        XCTAssertFalse(state.activityEndedForIdle)
    }

    /// 恢復播放後再閒置，會再收起一次
    func testResumeResetsEndedFlag() {
        send(play(Fixture.nowPlaying(), at: 0), context(0, endWhenIdle: true))
        send(.nothing, context(1, endWhenIdle: true))
        send(.nothing, context(10, endWhenIdle: true))
        send(.nothing, context(45, endWhenIdle: true))
        XCTAssertTrue(state.activityEndedForIdle)
        send(play(Fixture.nowPlaying(), at: 50), context(50, endWhenIdle: true))
        XCTAssertFalse(state.activityEndedForIdle)
    }
}

final class LiveActivityUpdatePolicyTests: XCTestCase {
    private let policy = LiveActivityUpdatePolicy()

    func testStartWhenNoActivity() {
        XCTAssertEqual(policy.decide(.init(isActive: false)), .start)
        XCTAssertEqual(policy.decide(.init(isActive: false, startBlockedUntilForeground: true)), .skip)
    }

    func testSkipSameContent() {
        XCTAssertEqual(policy.decide(.init(isActive: true, sameAsLast: true)), .skip)
    }

    func testStoreOnlyForRoutineUpdatesInBlockedBackground() {
        XCTAssertEqual(policy.decide(.init(isActive: true, backgroundBlocked: true, isInBackground: true)), .store)
        XCTAssertEqual(policy.decide(.init(isActive: true, backgroundBlocked: true, isInBackground: true,
                                           priority: .important)), .send)
        XCTAssertEqual(policy.decide(.init(isActive: true, backgroundBlocked: true, isInBackground: false)), .send)
        XCTAssertEqual(policy.decide(.init(isActive: true)), .send)
    }

    func testBlockedThreshold() {
        XCTAssertFalse(policy.shouldEnterBlocked(backgroundRejectStreak: 7))
        XCTAssertTrue(policy.shouldEnterBlocked(backgroundRejectStreak: 8))
    }
}

