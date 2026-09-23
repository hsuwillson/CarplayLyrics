import XCTest

final class PollPolicyTests: XCTestCase {
    let p = PollPolicy()

    func testPlaying() {
        XCTAssertEqual(p.delay(for: .playing(isPlaying: true, remaining: 100)), 2.5)
        XCTAssertEqual(p.delay(for: .playing(isPlaying: true, remaining: nil)), 2.5)
    }

    func testNearTrackEnd() {
        XCTAssertEqual(p.delay(for: .playing(isPlaying: true, remaining: 1.0)), 1.4, accuracy: 0.001)
        XCTAssertEqual(p.delay(for: .playing(isPlaying: true, remaining: 0.01)), 0.5, accuracy: 0.001)
    }

    func testPausedQuotaAndFullPlayer() {
        XCTAssertEqual(p.delay(for: .playing(isPlaying: false, remaining: 100)), 5)
        XCTAssertEqual(p.delay(for: .playing(isPlaying: true, remaining: 100), quotaActive: true), 6)
        XCTAssertEqual(p.delay(for: .playing(isPlaying: true, remaining: 100), preferFullPlayer: true), 1)
    }

    func testNothingAndErrors() {
        XCTAssertEqual(p.delay(for: .nothing(streak: 1)), 3)
        XCTAssertEqual(p.delay(for: .nothing(streak: 2)), 10)
        XCTAssertEqual(p.delay(for: .error(streak: 1)), 5)
        XCTAssertEqual(p.delay(for: .error(streak: 3)), 20)
        XCTAssertEqual(p.delay(for: .idleStopped), 30)
    }

    func testRateLimit() {
        XCTAssertEqual(p.delay(for: .rateLimited(retryAfter: 0, quotaExceeded: false)), 1)
        XCTAssertEqual(p.delay(for: .rateLimited(retryAfter: 7, quotaExceeded: false)), 7)
        XCTAssertEqual(p.delay(for: .rateLimited(retryAfter: 5, quotaExceeded: true)), 30)
    }

    func testConstrainedSlowsDown() {
        let c = PollPolicy(constrained: true)
        XCTAssertEqual(c.delay(for: .playing(isPlaying: true, remaining: 100)), 5)
        XCTAssertEqual(c.delay(for: .playing(isPlaying: false, remaining: 100)), 10)
    }
}

final class IdlePolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let p = IdlePolicy()

    func testNothingStopsAfterTenMinutes() {
        XCTAssertFalse(p.shouldStop(kind: .nothing, since: t0, now: t0.addingTimeInterval(599), isForeground: false))
        XCTAssertTrue(p.shouldStop(kind: .nothing, since: t0, now: t0.addingTimeInterval(601), isForeground: false))
    }

    func testPausedStopsAfterThirtyMinutes() {
        XCTAssertFalse(p.shouldStop(kind: .paused, since: t0, now: t0.addingTimeInterval(1000), isForeground: false))
        XCTAssertTrue(p.shouldStop(kind: .paused, since: t0, now: t0.addingTimeInterval(1801), isForeground: false))
    }

    func testNeverStopsInForeground() {
        XCTAssertFalse(p.shouldStop(kind: .nothing, since: t0, now: t0.addingTimeInterval(9999), isForeground: true))
    }
}

final class OptimisticGuardTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    private func snap(_ progress: TimeInterval, playing: Bool = true, at dt: TimeInterval, id: String = "a") -> PlaybackSnapshot {
        PlaybackSnapshot(trackID: id, progress: progress, duration: 200, isPlaying: playing, timestamp: t0.addingTimeInterval(dt))
    }

    func testIgnoresContradictionInsideWindow() {
        var g = OptimisticGuard()
        g.arm(now: t0)
        // 使用者按暫停（樂觀狀態 = 暫停），Spotify 還回傳播放中
        XCTAssertTrue(g.shouldIgnore(current: snap(10, playing: false, at: 0), incoming: snap(11, at: 1), now: t0.addingTimeInterval(1)))
        // 位置差太多（拖動還沒套用）
        XCTAssertTrue(g.shouldIgnore(current: snap(100, at: 0), incoming: snap(10, at: 1), now: t0.addingTimeInterval(1)))
    }

    func testAcceptsConsistentOrLateResponses() {
        var g = OptimisticGuard()
        g.arm(now: t0)
        XCTAssertFalse(g.shouldIgnore(current: snap(10, at: 0), incoming: snap(11, at: 1), now: t0.addingTimeInterval(1)))
        XCTAssertFalse(g.shouldIgnore(current: snap(10, playing: false, at: 0), incoming: snap(11, at: 3), now: t0.addingTimeInterval(3)))
        XCTAssertFalse(g.shouldIgnore(current: snap(10, at: 0), incoming: snap(0, at: 1, id: "b"), now: t0.addingTimeInterval(1)))
    }
}

final class WidgetReloadPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 10_000)

    func testForegroundAlwaysAllowedButThrottledToOnePerSecond() {
        var p = WidgetReloadPolicy()
        XCTAssertTrue(p.allowLineReload(now: t0, isForeground: true, renderCount: 0))
        XCTAssertFalse(p.allowLineReload(now: t0.addingTimeInterval(0.5), isForeground: true, renderCount: 0))
        XCTAssertTrue(p.allowLineReload(now: t0.addingTimeInterval(1.1), isForeground: true, renderCount: 0))
    }

    func testQuietAfterImportantReload() {
        var p = WidgetReloadPolicy()
        p.recordImportant(now: t0)
        XCTAssertFalse(p.allowLineReload(now: t0.addingTimeInterval(1.5), isForeground: false, renderCount: 0))
        XCTAssertTrue(p.allowLineReload(now: t0.addingTimeInterval(2.5), isForeground: false, renderCount: 0))
    }

    func testDisablesWhenSystemIgnoresReloads() {
        var p = WidgetReloadPolicy()
        var t = t0
        // 前 10 次允許；系統一次都沒執行（renderCount 不變）
        for _ in 0..<10 {
            XCTAssertTrue(p.allowLineReload(now: t, isForeground: false, renderCount: 5))
            t = t.addingTimeInterval(3)
        }
        XCTAssertFalse(p.allowLineReload(now: t, isForeground: false, renderCount: 5))
        XCTAssertEqual(p.mode(now: t), .paragraph)
        XCTAssertFalse(p.allowLineReload(now: t.addingTimeInterval(60), isForeground: false, renderCount: 5))
        // 30 分鐘後恢復
        XCTAssertTrue(p.allowLineReload(now: t.addingTimeInterval(1801), isForeground: false, renderCount: 5))
        XCTAssertEqual(p.mode(now: t.addingTimeInterval(1802)), .perLine)
    }

    func testKeepsGoingWhenSystemRenders() {
        var p = WidgetReloadPolicy()
        var t = t0
        var renders = 0
        for _ in 0..<25 {
            XCTAssertTrue(p.allowLineReload(now: t, isForeground: false, renderCount: renders))
            renders += 1
            t = t.addingTimeInterval(3)
        }
        XCTAssertEqual(p.mode(now: t), .perLine)
    }

    func testHourlyCap() {
        var p = WidgetReloadPolicy(hourlyCap: 3, windowSize: 100)
        var t = t0
        for _ in 0..<3 {
            XCTAssertTrue(p.allowLineReload(now: t, isForeground: false, renderCount: 0))
            t = t.addingTimeInterval(2)
        }
        XCTAssertFalse(p.allowLineReload(now: t, isForeground: false, renderCount: 0))
    }
}

final class PollSurfaceTests: XCTestCase {
    func testSteadyIntervalBySurface() {
        let p = PollPolicy()
        let playing = PollOutcome.playing(isPlaying: true, remaining: 100)
        XCTAssertEqual(p.delay(for: playing, surface: .foreground), 2.5)
        XCTAssertEqual(p.delay(for: playing, surface: .visible), 5)
        XCTAssertEqual(p.delay(for: playing, surface: .hidden), 15)
        XCTAssertEqual(p.delay(for: playing, surface: .hidden, hot: true), 2.5)
        // 接近結尾：任何模式都提早問
        XCTAssertEqual(p.delay(for: .playing(isPlaying: true, remaining: 4), surface: .hidden), 4.4, accuracy: 0.001)
        let c = PollPolicy(constrained: true)
        XCTAssertEqual(c.delay(for: playing, surface: .visible), 8)
        XCTAssertEqual(c.delay(for: playing, surface: .hidden), 20)
    }

    func testIdleBackoff() {
        let p = PollPolicy()
        XCTAssertEqual(p.pausedDelay(idleFor: 0), 5)
        XCTAssertEqual(p.pausedDelay(idleFor: 300), 10)
        XCTAssertEqual(p.pausedDelay(idleFor: 900), 20)
        XCTAssertEqual(p.delay(for: .nothing(streak: 3), idleFor: 60), 10)
        XCTAssertEqual(p.delay(for: .nothing(streak: 3), idleFor: 200), 30)
        XCTAssertEqual(p.delay(for: .nonMusic, idleFor: 60), 5)
        XCTAssertEqual(p.delay(for: .nonMusic, idleFor: 400), 10)
    }

    func testActivityEndThresholds() {
        let idle = IdlePolicy()
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(idle.activityEndDelay(for: .nothing), 30)
        XCTAssertEqual(idle.activityEndDelay(for: .nothing, carConnected: true), 300)
        XCTAssertNil(idle.activityEndDelay(for: .nonMusic))
        XCTAssertFalse(idle.shouldEndActivity(kind: .nothing, since: t0, now: t0.addingTimeInterval(100), hasPlayed: false))
        XCTAssertTrue(idle.shouldEndActivity(kind: .nothing, since: t0, now: t0.addingTimeInterval(100)))
    }

    func testHotWindow() {
        var s = PlaybackState()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(s.isHot(now: t0))
        s.markHot(at: t0)
        XCTAssertTrue(s.isHot(now: t0.addingTimeInterval(5)))
        XCTAssertFalse(s.isHot(now: t0.addingTimeInterval(11)))
        XCTAssertEqual(s.idleDuration(now: t0), 0)
        s.markIdle(.paused, at: t0)
        XCTAssertEqual(s.idleDuration(now: t0.addingTimeInterval(7)), 7)
    }
}
