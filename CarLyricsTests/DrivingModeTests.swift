import XCTest

/// 第六輪：開車模式（留在前景讓 CarPlay 歌詞即時更新）與 staleDate 推進。內容全部自編。

final class DrivingModePolicyTests: XCTestCase {
    private let policy = DrivingModePolicy()

    private func input(foreground: Bool = true, car: Bool = true, keepAwake: Bool = true, dim: Bool = false,
                       liveActivity: Bool = true, focus: Bool = false, keepScreenOn: Bool = false,
                       playing: Bool = false) -> DrivingModePolicy.Input {
        DrivingModePolicy.Input(isForeground: foreground, carConnected: car, keepAwakeWhileDriving: keepAwake,
                                dimWhileDriving: dim, liveActivityEnabled: liveActivity, focusModeActive: focus,
                                keepScreenOn: keepScreenOn, isPlaying: playing)
    }

    func testInputDefaults() {
        let i = DrivingModePolicy.Input(isForeground: true, carConnected: true)
        XCTAssertTrue(i.keepAwakeWhileDriving)
        XCTAssertFalse(i.dimWhileDriving)
        XCTAssertTrue(i.liveActivityEnabled)
        XCTAssertFalse(i.focusModeActive)
        XCTAssertFalse(i.keepScreenOn)
        XCTAssertFalse(i.isPlaying)
        XCTAssertEqual(i, input())
    }

    /// 四個條件缺一不可：前景、CarPlay、設定開、即時動態開
    func testIsDrivingNeedsAllConditions() {
        XCTAssertTrue(policy.isDriving(input()))
        XCTAssertFalse(policy.isDriving(input(foreground: false)))
        XCTAssertFalse(policy.isDriving(input(car: false)))
        XCTAssertFalse(policy.isDriving(input(keepAwake: false)))
        XCTAssertFalse(policy.isDriving(input(liveActivity: false)))
    }

    func testIdleTimer() {
        // 開車模式
        XCTAssertTrue(policy.shouldDisableIdleTimer(input()))
        // 背景：永遠不停用（系統本來就不會理會，也不要留著髒狀態）
        XCTAssertFalse(policy.shouldDisableIdleTimer(input(foreground: false, focus: true, keepScreenOn: true, playing: true)))
        // 不在車上：專注模式或「播放時常亮」仍然有效
        XCTAssertTrue(policy.shouldDisableIdleTimer(input(car: false, focus: true)))
        XCTAssertTrue(policy.shouldDisableIdleTimer(input(car: false, keepScreenOn: true, playing: true)))
        XCTAssertFalse(policy.shouldDisableIdleTimer(input(car: false, keepScreenOn: true, playing: false)))
        XCTAssertFalse(policy.shouldDisableIdleTimer(input(car: false)))
    }

    func testBrightnessOnlyWhenDrivingAndDimEnabled() {
        XCTAssertEqual(policy.targetBrightness(input(dim: true)), 0.3)
        XCTAssertEqual(policy.dimmedBrightness, 0.3)
        XCTAssertNil(policy.targetBrightness(input(dim: false)))
        XCTAssertNil(policy.targetBrightness(input(foreground: false, dim: true)))
        XCTAssertNil(policy.targetBrightness(input(car: false, dim: true)))
        var custom = policy
        custom.dimmedBrightness = 0.5
        XCTAssertEqual(custom.targetBrightness(input(dim: true)), 0.5)
        XCTAssertNotEqual(custom, policy)
    }

    func testChange() {
        XCTAssertEqual(policy.change(from: false, to: true), .entered)
        XCTAssertEqual(policy.change(from: true, to: false), .exited)
        XCTAssertEqual(policy.change(from: true, to: true), .none)
        XCTAssertEqual(policy.change(from: false, to: false), .none)
    }

    func testHint() {
        XCTAssertNil(policy.hint(input(car: false)))
        XCTAssertNil(policy.hint(input(liveActivity: false)))
        let on = policy.hint(input())
        let off = policy.hint(input(keepAwake: false))
        XCTAssertEqual(on, "讓 CarLyrics 留在螢幕上，CarPlay 歌詞才會即時更新（鎖定後只剩小工具會動）")
        XCTAssertEqual(off, "鎖定手機後 iOS 會停止更新 CarPlay 歌詞；到設定打開「開車時保持螢幕開著」")
        // 背景時也給同一句（只有前景畫面會顯示）
        XCTAssertEqual(policy.hint(input(foreground: false)), on)
    }

    func testPreferencesDefaults() {
        let suite = "DrivingModeTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let p = Preferences(defaults: d)
        XCTAssertTrue(p.keepAwakeWhileDriving)
        XCTAssertFalse(p.dimScreenWhileDriving)
        p.keepAwakeWhileDriving = false
        p.dimScreenWhileDriving = true
        XCTAssertFalse(p.keepAwakeWhileDriving)
        XCTAssertTrue(p.dimScreenWhileDriving)
        XCTAssertEqual(d.object(forKey: "keepAwakeWhileDriving") as? Bool, false)
    }
}

final class LiveActivityStalePolicyTests: XCTestCase {
    private let policy = LiveActivityStalePolicy()
    private let t0 = Date(timeIntervalSince1970: 10_000)

    private func model(playing: Bool = true, next: String = "測試第2句", next2: String? = "測試第3句",
                       lineEndAt: TimeInterval? = 6, nextLineAt: TimeInterval? = nil,
                       songEnd: TimeInterval? = 100) -> ActivityContentModel {
        ActivityContentModel(currentLine: "測試第1句", nextLine: next, trackName: "測試歌名", artistName: "測試歌手",
                             isPlaying: playing, songStart: songEnd.map { _ in t0.addingTimeInterval(-10) },
                             songEnd: songEnd.map { t0.addingTimeInterval($0) },
                             nextLineAt: nextLineAt.map { t0.addingTimeInterval($0) }, nextLine2: next2,
                             lineStartAt: lineEndAt.map { _ in t0 }, lineEndAt: lineEndAt.map { t0.addingTimeInterval($0) })
    }

    func testDefaults() {
        XCTAssertEqual(policy.grace, 2)
        XCTAssertEqual(policy.endGrace, 6)
        XCTAssertEqual(policy.fallback, 120)
        XCTAssertEqual(policy.minimum, 1)
        XCTAssertEqual(policy.advanceWindow, 15)
        XCTAssertEqual(LiveActivityStalePolicy.openAppLine, "打開 CarLyrics 繼續同步歌詞")
        XCTAssertEqual(LiveActivityStalePolicy.expiredLine, "歌詞沒跟上")
    }

    func testNextLineStartPrefersLineEnd() {
        XCTAssertEqual(LiveActivityStalePolicy.nextLineStart(model(lineEndAt: 6, nextLineAt: 9)), t0.addingTimeInterval(6))
        XCTAssertEqual(LiveActivityStalePolicy.nextLineStart(model(lineEndAt: nil, nextLineAt: 9)), t0.addingTimeInterval(9))
        XCTAssertNil(LiveActivityStalePolicy.nextLineStart(model(lineEndAt: nil)))
    }

    // MARK: staleDate

    func testStaleDateIsNextLinePlusGrace() {
        XCTAssertEqual(policy.staleDate(for: model(), now: t0), t0.addingTimeInterval(8))
        XCTAssertEqual(policy.staleInterval(for: model(), now: t0), 8)
        // 間奏：用倒數用的 nextLineAt
        XCTAssertEqual(policy.staleDate(for: model(lineEndAt: nil, nextLineAt: 20), now: t0), t0.addingTimeInterval(22))
    }

    func testStaleDateBoundedBySongEnd() {
        // 最後一句：沒有下一句，用歌曲結束 + 6 秒（換歌的更新要等輪詢，寬限給多一點）
        XCTAssertEqual(policy.staleDate(for: model(next: "", next2: nil, lineEndAt: nil, songEnd: 30), now: t0),
                       t0.addingTimeInterval(36))
        // 下一句比歌曲結束晚（歌詞時間碼超出長度）：取較早者
        XCTAssertEqual(policy.staleDate(for: model(lineEndAt: 50, songEnd: 30), now: t0), t0.addingTimeInterval(36))
        // 下一句在結尾前一點點：還是以下一句為準
        XCTAssertEqual(policy.staleDate(for: model(lineEndAt: 33, songEnd: 30), now: t0), t0.addingTimeInterval(35))
    }

    func testStaleDateFallbacks() {
        // 暫停：不推進，120 秒後才 stale（keepAlive 會續期）
        XCTAssertEqual(policy.staleDate(for: model(playing: false), now: t0), t0.addingTimeInterval(120))
        // 播放中但沒有任何時刻（沒有歌詞、廣告、等待下一首）
        XCTAssertEqual(policy.staleDate(for: model(lineEndAt: nil, songEnd: nil), now: t0), t0.addingTimeInterval(120))
        // 下一句很久以後（長間奏 / 長句）：最多 120 秒，之後靠 keepAlive
        XCTAssertEqual(policy.staleDate(for: model(lineEndAt: 500, songEnd: 600), now: t0), t0.addingTimeInterval(120))
        // 下一句已經過了（晚送出的更新）：至少 1 秒，不要一送出就 stale
        XCTAssertEqual(policy.staleDate(for: model(lineEndAt: -3), now: t0), t0.addingTimeInterval(1))
    }

    func testStaleDateIsTunable() {
        var custom = policy
        custom.grace = 5
        XCTAssertEqual(custom.staleDate(for: model(), now: t0), t0.addingTimeInterval(11))
        XCTAssertNotEqual(custom, policy)
    }

    // MARK: 畫面

    func testAdvancesToNextLineWithinWindow() {
        let d = policy.display(for: model(), now: t0.addingTimeInterval(8))
        XCTAssertEqual(d, LiveActivityStalePolicy.Display(kind: .advanced, current: "測試第2句", next: "測試第3句"))
        // 時間窗最後一刻仍推進；沒有再下一句時下一句留白
        let edge = policy.display(for: model(next2: nil), now: t0.addingTimeInterval(20.9))
        XCTAssertEqual(edge, LiveActivityStalePolicy.Display(kind: .advanced, current: "測試第2句", next: ""))
        // 下一句是間奏（空白句）：顯示 ♪
        XCTAssertEqual(policy.display(for: model(next: ""), now: t0.addingTimeInterval(7)).current, "♪")
        // 間奏中 stale：用 nextLineAt 推進
        let gap = policy.display(for: model(lineEndAt: nil, nextLineAt: 20), now: t0.addingTimeInterval(22))
        XCTAssertEqual(gap.kind, .advanced)
    }

    func testExpiredAfterWindow() {
        let d = policy.display(for: model(), now: t0.addingTimeInterval(21))
        XCTAssertEqual(d, LiveActivityStalePolicy.Display(kind: .expired, current: "歌詞沒跟上", next: "打開 CarLyrics 繼續同步歌詞"))
    }

    func testSongOverHidesOldLyrics() {
        let d = policy.display(for: model(), now: t0.addingTimeInterval(100))
        XCTAssertEqual(d, LiveActivityStalePolicy.Display(kind: .songOver, current: "打開 CarLyrics 繼續同步歌詞", next: ""))
        // 播完優先於其他判定（就算下一句時刻怪怪的）
        XCTAssertEqual(policy.display(for: model(lineEndAt: 200), now: t0.addingTimeInterval(150)).kind, .songOver)
    }

    func testUnchangedCases() {
        let unchanged = LiveActivityStalePolicy.Display(kind: .unchanged, current: "測試第1句", next: "測試第2句")
        // 暫停中
        XCTAssertEqual(policy.display(for: model(playing: false), now: t0.addingTimeInterval(50)), unchanged)
        // 還沒到下一句（App 被終止、或舊版沒有時刻）
        XCTAssertEqual(policy.display(for: model(), now: t0.addingTimeInterval(5)), unchanged)
        XCTAssertEqual(policy.display(for: model(lineEndAt: nil, songEnd: nil), now: t0.addingTimeInterval(500)), unchanged)
    }

    /// 端到端：背景被擋的一句 → staleDate 到了，畫面在那一刻重畫就看到下一句
    func testStaleDateThenDisplayAdvances() {
        let m = model()
        let stale = policy.staleDate(for: m, now: t0)
        XCTAssertEqual(policy.display(for: m, now: stale).kind, .advanced)
        // 最後一句：staleDate = 播完 + 寬限，那一刻顯示「打開 CarLyrics」
        let last = model(next: "", next2: nil, lineEndAt: nil, songEnd: 30)
        XCTAssertEqual(policy.display(for: last, now: policy.staleDate(for: last, now: t0)).kind, .songOver)
    }
}
