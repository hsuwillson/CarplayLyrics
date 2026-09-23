import XCTest

/// reducer 是「收到輪詢結果 → 改什麼狀態、做什麼事」的規格（docs/event-effects.md）
final class PlaybackReducerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 100_000)
    private var reducer = PlaybackReducer()
    private var state = PlaybackState()

    private func context(_ dt: TimeInterval = 0, foreground: Bool = false, car: Bool = false,
                         activity: Bool = true, endWhenIdle: Bool = false) -> PlaybackReducer.Context {
        PlaybackReducer.Context(now: t0.addingTimeInterval(dt), isForeground: foreground,
                                carConnected: car, activityIsActive: activity,
                                endActivityWhenIdle: endWhenIdle)
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

    /// 沒在播放 30 秒後結束即時動態；只送一次，而且不停止背景執行
    func testActivityEndsAfterNothingWhenEnabled() {
        send(.nothing, context(0, endWhenIdle: true))
        let start = send(.nothing, context(10, endWhenIdle: true))
        XCTAssertEqual(start.effects, [.pushStopped, .publishIdle("Spotify 沒有在播放")])

        let end = send(.nothing, context(45, endWhenIdle: true))
        XCTAssertEqual(end.effects, [.endActivity])
        XCTAssertTrue(state.activityEndedForIdle)

        let again = send(.nothing, context(60, endWhenIdle: true))
        XCTAssertTrue(again.effects.isEmpty, "已經結束過就不再送")
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
        let paused = Fixture.nowPlaying(playing: false)
        send(play(paused, at: 0), context(0, endWhenIdle: true))
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

    /// 本來就沒有即時動態：不用送結束
    func testNoActivityNothingToEnd() {
        send(.nothing, context(0, activity: false, endWhenIdle: true))
        send(.nothing, context(10, activity: false, endWhenIdle: true))
        let out = send(.nothing, context(45, activity: false, endWhenIdle: true))
        XCTAssertFalse(out.effects.contains(.endActivity))
        XCTAssertFalse(state.activityEndedForIdle)
    }

    /// 恢復播放後再閒置，會再收起一次
    func testResumeResetsEndedFlag() {
        send(.nothing, context(0, endWhenIdle: true))
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

