import XCTest

/// 第十輪（build 45 實測後）：閒置計時重新起算、暫停後 204 不當成換歌、CarPlay 閃斷寬限、上車提醒、
/// 即時動態重畫節奏統計、視窗升上來的目前句進度條。內容全部自編。

// MARK: - A. 閒置計時

final class IdleClockRestartTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 100_000)
    private var reducer = PlaybackReducer()
    private var state = PlaybackState()

    private func context(_ dt: TimeInterval, foreground: Bool = false, car: Bool = false,
                         activity: Bool = true) -> PlaybackReducer.Context {
        PlaybackReducer.Context(now: t0.addingTimeInterval(dt), isForeground: foreground, carConnected: car,
                                activityIsActive: activity, endActivityWhenIdle: true)
    }

    private func play(at dt: TimeInterval) -> PlayerPollResult {
        .playing(Fixture.nowPlaying(), measuredAt: t0.addingTimeInterval(dt), sentAt: t0.addingTimeInterval(dt))
    }

    func testRestartIdleClock() {
        var s = PlaybackState()
        // 沒有在閒置：什麼都不做
        XCTAssertNil(s.restartIdleClock(at: t0))
        XCTAssertNil(s.idleSince)
        s.markIdle(.nothing, at: t0)
        s.activityEndedForIdle = true
        XCTAssertEqual(s.restartIdleClock(at: t0.addingTimeInterval(2000)), 2000)
        XCTAssertEqual(s.idleKind, .nothing)
        XCTAssertEqual(s.idleSince, t0.addingTimeInterval(2000))
        XCTAssertFalse(s.activityEndedForIdle)
        // 只有 kind 沒有 since（防禦）
        var odd = PlaybackState()
        odd.idleKind = .paused
        XCTAssertNil(odd.restartIdleClock(at: t0))
    }

    /// build 45 實測 A：在家「沒在播放」33 分鐘 → 上車、即時動態開始 → 1 秒後就被「閒置（沒在播放）」收掉。
    /// 上車 / 即時動態開始時重新起算之後，車上的 30 分鐘門檻才是從上車算
    func testFieldLogA_activityNotEndedRightAfterCarConnect() {
        _ = reducer.reduce(&state, result: play(at: 0), context: context(0))
        _ = reducer.reduce(&state, result: .nothing, context: context(1, foreground: true))
        _ = reducer.reduce(&state, result: .nothing, context: context(10, foreground: true))
        XCTAssertEqual(state.idleKind, .nothing)
        XCTAssertEqual(state.idleSince, t0.addingTimeInterval(10))

        // 沒有重新起算（build 45 的行為）：上車 1 秒後就收
        var buggy = state
        let bug = reducer.reduce(&buggy, result: .nothing, context: context(2000, foreground: true, car: true))
        XCTAssertTrue(bug.effects.contains(.endActivity), "重現 build 45：33 分鐘前的閒置算在剛開的即時動態頭上")

        // 上車 / 即時動態開始：重新起算
        XCTAssertEqual(state.restartIdleClock(at: t0.addingTimeInterval(1999)), 1989)
        let fixed = reducer.reduce(&state, result: .nothing, context: context(2000, foreground: true, car: true))
        XCTAssertFalse(fixed.effects.contains(.endActivity))
        XCTAssertFalse(fixed.effects.contains(.stopForIdle(minutes: 30)))
        // 車上真的沒在播放 30 分鐘（從上車算）才收
        let later = reducer.reduce(&state, result: .nothing, context: context(1999 + 1801, foreground: true, car: true))
        XCTAssertTrue(later.effects.contains(.endActivity))
    }

    /// 背景的「閒置停止」也一樣從重新起算的時刻算
    func testRestartAlsoDefersIdleStop() {
        _ = reducer.reduce(&state, result: .nothing, context: context(0))
        _ = reducer.reduce(&state, result: .nothing, context: context(1))
        state.restartIdleClock(at: t0.addingTimeInterval(590))
        XCTAssertEqual(reducer.reduce(&state, result: .nothing, context: context(1000)).effects, [])
        let stop = reducer.reduce(&state, result: .nothing, context: context(1192))
        XCTAssertEqual(stop.effects.last, .stopForIdle(minutes: 10))
    }
}

// MARK: - D. 暫停後 204 不當成換歌

final class ParkedTrackTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 200_000)
    private var reducer = PlaybackReducer()
    private var state = PlaybackState()

    private func context(_ dt: TimeInterval, car: Bool = false) -> PlaybackReducer.Context {
        PlaybackReducer.Context(now: t0.addingTimeInterval(dt), isForeground: true, carConnected: car)
    }

    private func play(_ np: NowPlaying, at dt: TimeInterval) -> PlayerPollResult {
        .playing(np, measuredAt: t0.addingTimeInterval(dt), sentAt: t0.addingTimeInterval(dt))
    }

    func testDefaults() {
        XCTAssertEqual(reducer.resumeSameTrackWithin, 1800)
        XCTAssertNil(state.parkedTrack)
        XCTAssertNil(state.parkedAt)
    }

    /// build 45 實測 D：播放 → 暫停 → Spotify 回 204 兩次 → 同一首續播：不是換歌，歌詞沿用
    func testFieldLogD_sameTrackAfterNothingIsResume() {
        let np = Fixture.nowPlaying(progress: 30)
        _ = reducer.reduce(&state, result: play(np, at: 0), context: context(0))
        _ = reducer.reduce(&state, result: play(Fixture.nowPlaying(playing: false, progress: 32), at: 2), context: context(2))
        _ = reducer.reduce(&state, result: .nothing, context: context(10))
        let cleared = reducer.reduce(&state, result: .nothing, context: context(20))
        XCTAssertTrue(cleared.effects.contains(.clearPlayback))
        XCTAssertEqual(state.parkedTrack?.trackID, "track1")
        XCTAssertEqual(state.parkedAt, t0.addingTimeInterval(20))
        XCTAssertNil(state.nowPlaying)

        let resumed = reducer.reduce(&state, result: play(Fixture.nowPlaying(progress: 32), at: 80), context: context(80))
        XCTAssertEqual(resumed.effects, [.log("同一首回來了（播放中；Spotify 回報沒在播放 60 秒），沿用歌詞"),
                                         .resumeTrack(Fixture.nowPlaying(progress: 32)), .pushCurrent(important: true),
                                         .rescheduleTick, .publishTimeline(debounce: false)])
        XCTAssertFalse(resumed.effects.contains(.newTrack(Fixture.nowPlaying(progress: 32))))
        XCTAssertEqual(state.session, .playing)
        XCTAssertNil(state.parkedTrack)
        XCTAssertNil(state.parkedAt)
        XCTAssertNil(state.idleKind)
        XCTAssertEqual(resumed.delay, 2.5, "剛回來維持最快的輪詢")
    }

    /// 同一首回來但還是暫停中：一樣沿用（紀錄寫暫停中）
    func testSameTrackPausedAfterNothing() {
        _ = reducer.reduce(&state, result: play(Fixture.nowPlaying(), at: 0), context: context(0))
        _ = reducer.reduce(&state, result: .nothing, context: context(5))
        _ = reducer.reduce(&state, result: .nothing, context: context(10))
        let out = reducer.reduce(&state, result: play(Fixture.nowPlaying(playing: false), at: 15), context: context(15))
        XCTAssertEqual(out.effects.first, .log("同一首回來了（暫停中；Spotify 回報沒在播放 5 秒），沿用歌詞"))
        XCTAssertEqual(out.effects[1], .resumeTrack(Fixture.nowPlaying(playing: false)))
        XCTAssertEqual(state.session, .paused)
        XCTAssertEqual(state.idleKind, .paused)
    }

    func testDifferentTrackAfterNothingIsNewTrack() {
        _ = reducer.reduce(&state, result: play(Fixture.nowPlaying(), at: 0), context: context(0))
        _ = reducer.reduce(&state, result: .nothing, context: context(5))
        _ = reducer.reduce(&state, result: .nothing, context: context(10))
        let other = Fixture.nowPlaying(id: "track2")
        let out = reducer.reduce(&state, result: play(other, at: 15), context: context(15))
        XCTAssertEqual(out.effects, [.log("換歌：測試歌名 – 測試歌手"), .newTrack(other), .publishTimeline(debounce: true)])
        XCTAssertNil(state.parkedTrack)
    }

    /// 超過 30 分鐘才回來：當成換歌（重新載入，歌詞可能已經不在）
    func testSameTrackAfterTooLongIsNewTrack() {
        _ = reducer.reduce(&state, result: play(Fixture.nowPlaying(), at: 0), context: context(0))
        _ = reducer.reduce(&state, result: .nothing, context: context(5))
        _ = reducer.reduce(&state, result: .nothing, context: context(10))
        let out = reducer.reduce(&state, result: play(Fixture.nowPlaying(), at: 1811), context: context(1811))
        XCTAssertEqual(out.effects.first, .log("換歌：測試歌名 – 測試歌手"))
        XCTAssertNil(state.parkedTrack)
        // 剛好 30 分鐘：還算回來
        var s2 = PlaybackState()
        _ = reducer.reduce(&s2, result: play(Fixture.nowPlaying(), at: 0), context: context(0))
        _ = reducer.reduce(&s2, result: .nothing, context: context(5))
        _ = reducer.reduce(&s2, result: .nothing, context: context(10))
        XCTAssertEqual(reducer.reduce(&s2, result: play(Fixture.nowPlaying(), at: 1810), context: context(1810)).effects[1],
                       .resumeTrack(Fixture.nowPlaying()))
    }

    /// 沒有記住的歌（一開始就沒在播放）：照舊是換歌
    func testNothingWithoutTrackDoesNotPark() {
        _ = reducer.reduce(&state, result: .nothing, context: context(0))
        _ = reducer.reduce(&state, result: .nothing, context: context(5))
        XCTAssertNil(state.parkedTrack)
        let out = reducer.reduce(&state, result: play(Fixture.nowPlaying(), at: 10), context: context(10))
        XCTAssertEqual(out.effects[1], .newTrack(Fixture.nowPlaying()))
    }

    /// 車上「沒在播放」問得勤一點：前 2 分鐘 5 秒、10 分鐘內 10 秒、之後 30 秒；不在車上維持 10 / 30
    func testNothingPollsFasterInCar() {
        _ = reducer.reduce(&state, result: play(Fixture.nowPlaying(), at: 0), context: context(0, car: true))
        _ = reducer.reduce(&state, result: .nothing, context: context(5, car: true))
        XCTAssertEqual(reducer.reduce(&state, result: .nothing, context: context(10, car: true)).delay, 5)
        XCTAssertEqual(reducer.reduce(&state, result: .nothing, context: context(200, car: true)).delay, 10)
        XCTAssertEqual(reducer.reduce(&state, result: .nothing, context: context(700, car: true)).delay, 30)
        let p = PollPolicy()
        XCTAssertEqual(p.delay(for: .nothing(streak: 1), inCar: true), 3)
        XCTAssertEqual(p.delay(for: .nothing(streak: 2), idleFor: 60, inCar: true), 5)
        XCTAssertEqual(p.delay(for: .nothing(streak: 2), idleFor: 60), 10)
        XCTAssertEqual(p.delay(for: .nothing(streak: 2), idleFor: 300, inCar: true), 10)
        XCTAssertEqual(p.delay(for: .nothing(streak: 2), idleFor: 300), 30)
        XCTAssertEqual(p.delay(for: .nothing(streak: 2), idleFor: 700, inCar: true), 30)
    }
}

// MARK: - C. CarPlay 閃斷寬限

final class CarConnectionGracePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 300_000)

    func testDefaults() {
        let p = CarConnectionGracePolicy()
        XCTAssertEqual(p.grace, 30)
        XCTAssertFalse(p.isConnected)
        XCTAssertNil(p.pendingSince)
        XCTAssertFalse(p.isInGrace)
        XCTAssertNil(p.remainingGrace(now: t0))
        XCTAssertTrue(CarConnectionGracePolicy(connected: true).isConnected)
        XCTAssertNotEqual(p, CarConnectionGracePolicy(connected: true))
    }

    func testConnectAndRepeatedConnect() {
        var p = CarConnectionGracePolicy()
        XCTAssertEqual(p.routeChanged(connected: true, now: t0), .connected)
        XCTAssertTrue(p.isConnected)
        XCTAssertEqual(p.routeChanged(connected: true, now: t0.addingTimeInterval(1)), .none)
        // 沒連著時「離開」：不理
        var q = CarConnectionGracePolicy()
        XCTAssertEqual(q.routeChanged(connected: false, now: t0), .none)
        XCTAssertFalse(q.isInGrace)
    }

    /// build 45 實測 C：離開 10 秒後重新連上 → 什麼都不用收
    func testFlapWithinGraceIsIgnored() {
        var p = CarConnectionGracePolicy(connected: true)
        XCTAssertEqual(p.routeChanged(connected: false, now: t0), .disconnectScheduled(grace: 30))
        XCTAssertTrue(p.isConnected, "寬限期內對外仍算連著")
        XCTAssertTrue(p.isInGrace)
        XCTAssertEqual(p.remainingGrace(now: t0.addingTimeInterval(10)), 20)
        // 寬限期內再收到「離開」：不重排
        XCTAssertEqual(p.routeChanged(connected: false, now: t0.addingTimeInterval(5)), .none)
        XCTAssertEqual(p.pendingSince, t0)
        // 計時器太早到（防禦）：不算離開
        XCTAssertEqual(p.graceElapsed(now: t0.addingTimeInterval(29)), .none)
        XCTAssertTrue(p.isConnected)
        XCTAssertEqual(p.routeChanged(connected: true, now: t0.addingTimeInterval(10)), .reconnected(after: 10))
        XCTAssertTrue(p.isConnected)
        XCTAssertFalse(p.isInGrace)
        // 寬限已取消：舊的計時器到了也不算離開
        XCTAssertEqual(p.graceElapsed(now: t0.addingTimeInterval(31)), .none)
        XCTAssertTrue(p.isConnected)
    }

    /// 真的走了：寬限到就離開，之後重新連上是新的一次上車
    func testRealDisconnect() {
        var p = CarConnectionGracePolicy(connected: true, grace: 20)
        XCTAssertEqual(p.routeChanged(connected: false, now: t0), .disconnectScheduled(grace: 20))
        XCTAssertEqual(p.graceElapsed(now: t0.addingTimeInterval(20)), .disconnected)
        XCTAssertFalse(p.isConnected)
        XCTAssertNil(p.pendingSince)
        XCTAssertNil(p.remainingGrace(now: t0.addingTimeInterval(21)))
        XCTAssertEqual(p.graceElapsed(now: t0.addingTimeInterval(25)), .none)
        XCTAssertEqual(p.routeChanged(connected: true, now: t0.addingTimeInterval(60)), .connected)
        XCTAssertEqual(p.remainingGrace(now: t0.addingTimeInterval(99)), nil)
        // remainingGrace 不會是負的
        _ = p.routeChanged(connected: false, now: t0.addingTimeInterval(100))
        XCTAssertEqual(p.remainingGrace(now: t0.addingTimeInterval(200)), 0)
    }
}

// MARK: - 上車提醒

final class CarConnectNoticePolicyTests: XCTestCase {
    private let policy = CarConnectNoticePolicy()
    private typealias Input = CarConnectNoticePolicy.Input

    func testDefaultsAndCopy() {
        XCTAssertEqual(policy.delay, 8)
        XCTAssertEqual(CarConnectNoticePolicy.title, "CarPlay 已連接")
        XCTAssertEqual(CarConnectNoticePolicy.body, "點一下開始顯示 CarPlay 歌詞")
        let i = Input(enabled: true)
        XCTAssertEqual(i, Input(enabled: true, loggedIn: true, liveActivityEnabled: true, isForeground: false,
                                activityIsActive: false, authorization: .authorized, notifiedThisConnection: false))
        XCTAssertTrue(CarConnectNoticePolicy.Authorization.authorized.isGranted)
        XCTAssertFalse(CarConnectNoticePolicy.Authorization.denied.isGranted)
        XCTAssertFalse(CarConnectNoticePolicy.Authorization.notDetermined.isGranted)
    }

    /// 七個條件缺一不可
    func testShouldNotify() {
        XCTAssertTrue(policy.shouldNotify(Input(enabled: true)))
        XCTAssertFalse(policy.shouldNotify(Input(enabled: false)))
        XCTAssertFalse(policy.shouldNotify(Input(enabled: true, loggedIn: false)))
        XCTAssertFalse(policy.shouldNotify(Input(enabled: true, liveActivityEnabled: false)))
        XCTAssertFalse(policy.shouldNotify(Input(enabled: true, isForeground: true)), "前景自己會開始")
        XCTAssertFalse(policy.shouldNotify(Input(enabled: true, activityIsActive: true)), "已經有即時動態")
        XCTAssertFalse(policy.shouldNotify(Input(enabled: true, authorization: .denied)))
        XCTAssertFalse(policy.shouldNotify(Input(enabled: true, authorization: .notDetermined)))
        XCTAssertFalse(policy.shouldNotify(Input(enabled: true, notifiedThisConnection: true)), "每次上車一次")
    }

    func testStatus() {
        XCTAssertEqual(policy.status(Input(enabled: false)), "關閉")
        XCTAssertEqual(policy.status(Input(enabled: true, authorization: .denied)), "需要通知權限：到系統設定允許通知")
        XCTAssertEqual(policy.status(Input(enabled: true, authorization: .notDetermined)), "尚未允許通知（會在前景詢問一次）")
        XCTAssertEqual(policy.status(Input(enabled: true, loggedIn: false)), "請先登入 Spotify")
        XCTAssertEqual(policy.status(Input(enabled: true, liveActivityEnabled: false)), "鎖定畫面歌詞已關閉，用不到提醒")
        XCTAssertEqual(policy.status(Input(enabled: true)), "上車時 App 在背景才會提醒（只出現在 iPhone 上）")
        XCTAssertEqual(policy.status(Input(enabled: true, isForeground: true, activityIsActive: true)),
                       "上車時 App 在背景才會提醒（只出現在 iPhone 上）")
    }

    func testPreferenceDefaultOnAndPersists() {
        let suite = "CarLyricsTests.roundTen.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let p = Preferences(defaults: d)
        XCTAssertTrue(p.carConnectNotice)
        p.carConnectNotice = false
        XCTAssertFalse(p.carConnectNotice)
        XCTAssertEqual(d.object(forKey: "carConnectNotice") as? Bool, false)
    }
}

// MARK: - 即時動態重畫節奏

final class LiveActivityRenderLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 400_000)

    func testDefaults() {
        let log = LiveActivityRenderLog()
        XCTAssertEqual(log.maxSamples, 40)
        XCTAssertEqual(log.minGap, 5)
        XCTAssertEqual(log.maxGap, 600)
        XCTAssertTrue(log.times.isEmpty)
        XCTAssertNil(log.lastRenderAt)
        XCTAssertNil(log.stats)
        XCTAssertNil(log.summary)
        XCTAssertTrue(log.gaps.isEmpty)
        // maxSamples 至少 2（不然算不出間隔）
        XCTAssertEqual(LiveActivityRenderLog(maxSamples: 1).maxSamples, 2)
        XCTAssertNotEqual(log, LiveActivityRenderLog(times: [t0]))
    }

    /// 同一次重畫 body 被評估好幾次：5 秒內只記一次
    func testMinGapCoalesces() {
        var log = LiveActivityRenderLog()
        XCTAssertTrue(log.record(now: t0))
        XCTAssertFalse(log.record(now: t0.addingTimeInterval(0.2)))
        XCTAssertFalse(log.record(now: t0.addingTimeInterval(4.9)))
        XCTAssertTrue(log.record(now: t0.addingTimeInterval(5)))
        XCTAssertEqual(log.times, [t0, t0.addingTimeInterval(5)])
        XCTAssertEqual(log.lastRenderAt, t0.addingTimeInterval(5))
        // 時鐘倒退：當成新的一筆（不會永遠記不到）
        XCTAssertTrue(log.record(now: t0.addingTimeInterval(-100)))
        XCTAssertEqual(log.times.count, 3)
    }

    func testTrimsToMaxSamples() {
        var log = LiveActivityRenderLog(maxSamples: 3)
        for i in 0..<5 { log.record(now: t0.addingTimeInterval(Double(i) * 10)) }
        XCTAssertEqual(log.times, [t0.addingTimeInterval(20), t0.addingTimeInterval(30), t0.addingTimeInterval(40)])
    }

    /// 只有一筆 → 沒有間隔；超過 10 分鐘的間隔（中間沒有即時動態）與倒退的不算
    func testGapsAndStats() {
        let times = [t0, t0.addingTimeInterval(60), t0.addingTimeInterval(120), t0.addingTimeInterval(2000),
                     t0.addingTimeInterval(2003), t0.addingTimeInterval(1000)]
        let log = LiveActivityRenderLog(times: times)
        XCTAssertEqual(log.gaps, [60, 60, 3])
        let s = try? XCTUnwrap(log.stats)
        XCTAssertEqual(s, LiveActivityRenderLog.Stats(count: 3, average: 41, longest: 60, shortest: 3))
        XCTAssertEqual(log.summary, "最近 3 次，平均 41 秒／最長 60 秒")
        XCTAssertNil(LiveActivityRenderLog(times: [t0]).stats)
        XCTAssertNil(LiveActivityRenderLog(times: [t0, t0.addingTimeInterval(601)]).summary)
    }

    /// 10 秒以下顯示一位小數（鎖定畫面逐句時看得出是 3 秒還是 4 秒）
    func testSummaryFormatsShortGaps() {
        let log = LiveActivityRenderLog(times: [t0, t0.addingTimeInterval(3.2), t0.addingTimeInterval(6.4)])
        XCTAssertEqual(log.summary, "最近 2 次，平均 3.2 秒／最長 3.2 秒")
        let mixed = LiveActivityRenderLog(times: [t0, t0.addingTimeInterval(5), t0.addingTimeInterval(30)])
        XCTAssertEqual(mixed.summary, "最近 2 次，平均 15 秒／最長 25 秒")
    }
}

// MARK: - 視窗升上來的目前句帶進度條

final class StaleDisplayCurrentIntervalTests: XCTestCase {
    private let policy = LiveActivityStalePolicy()
    private let t0 = Date(timeIntervalSince1970: 500_000)

    private var model: ActivityContentModel {
        ActivityContentModel(currentLine: "測試第1句", nextLine: "測試第2句", trackName: "測試歌名", artistName: "測試歌手",
                             isPlaying: true, songEnd: t0.addingTimeInterval(100), lineStartAt: t0,
                             lineEndAt: t0.addingTimeInterval(3),
                             upcoming: [ActivityUpcomingLine(text: "測試第2句", startAt: t0.addingTimeInterval(3),
                                                             endAt: t0.addingTimeInterval(6)),
                                        ActivityUpcomingLine(text: "測試第3句", startAt: t0.addingTimeInterval(6))])
    }

    func testDisplayInitDefaults() {
        let d = LiveActivityStalePolicy.Display(kind: .unchanged, current: "測試第1句", next: "")
        XCTAssertTrue(d.upcoming.isEmpty)
        XCTAssertNil(d.currentInterval)
    }

    func testAdvancedLineCarriesItsInterval() {
        let inside = policy.display(for: model, now: t0.addingTimeInterval(4))
        XCTAssertEqual(inside.kind, .advanced)
        XCTAssertEqual(inside.currentInterval, t0.addingTimeInterval(3)...t0.addingTimeInterval(6))
        // 最後一句不知道結束：沒有區間
        let last = policy.display(for: model, now: t0.addingTimeInterval(7))
        XCTAssertEqual(last.current, "測試第3句")
        XCTAssertNil(last.currentInterval)
        // 還沒推進 / 間奏 / 過期：沒有區間
        XCTAssertNil(policy.display(for: model, now: t0.addingTimeInterval(1)).currentInterval)
        XCTAssertNil(policy.display(for: model, now: t0.addingTimeInterval(30)).currentInterval)
    }
}
