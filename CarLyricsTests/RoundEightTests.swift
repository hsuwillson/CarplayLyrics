import XCTest

/// 第八輪：定位保活（開車時使用定位讓系統多一個執行理由）的決策與各理由的統計。內容全部自編。

final class LocationKeepAlivePolicyTests: XCTestCase {
    private let policy = LocationKeepAlivePolicy()
    private typealias Input = LocationKeepAlivePolicy.Input
    private typealias Auth = LocationKeepAlivePolicy.Authorization

    func testInputDefaults() {
        let i = Input(enabled: true)
        XCTAssertTrue(i.loggedIn)
        XCTAssertTrue(i.liveActivityEnabled)
        XCTAssertTrue(i.inCar)
        XCTAssertTrue(i.activityIsActive)
        XCTAssertTrue(i.isForeground)
        XCTAssertEqual(i.authorization, .whenInUse)
        XCTAssertFalse(i.isRunning)
        XCTAssertEqual(i, Input(enabled: true, loggedIn: true, liveActivityEnabled: true, inCar: true,
                                activityIsActive: true, isForeground: true, authorization: .whenInUse, isRunning: false))
    }

    func testAuthorizationGranted() {
        XCTAssertTrue(Auth.whenInUse.isGranted)
        XCTAssertTrue(Auth.always.isGranted)
        XCTAssertFalse(Auth.notDetermined.isGranted)
        XCTAssertFalse(Auth.denied.isGranted)
        XCTAssertFalse(Auth.restricted.isGranted)
    }

    /// 五個條件缺一不可
    func testWants() {
        XCTAssertTrue(policy.wants(Input(enabled: true)))
        XCTAssertFalse(policy.wants(Input(enabled: false)))
        XCTAssertFalse(policy.wants(Input(enabled: true, loggedIn: false)))
        XCTAssertFalse(policy.wants(Input(enabled: true, liveActivityEnabled: false)))
        XCTAssertFalse(policy.wants(Input(enabled: true, inCar: false)))
        XCTAssertFalse(policy.wants(Input(enabled: true, activityIsActive: false)))
        // 權限與前景不影響「想不想要」
        XCTAssertTrue(policy.wants(Input(enabled: true, isForeground: false, authorization: .denied)))
    }

    func testDecideWhenNotWanted() {
        XCTAssertEqual(policy.decide(Input(enabled: false)), .keep)
        XCTAssertEqual(policy.decide(Input(enabled: false, isRunning: true)), .stop)
        XCTAssertEqual(policy.decide(Input(enabled: true, inCar: false, isRunning: true)), .stop)
        XCTAssertEqual(policy.decide(Input(enabled: true, activityIsActive: false, isRunning: true)), .stop)
    }

    func testDecideAuthorization() {
        // 還沒問過：只在前景詢問
        XCTAssertEqual(policy.decide(Input(enabled: true, authorization: .notDetermined)), .requestAuthorization)
        XCTAssertEqual(policy.decide(Input(enabled: true, isForeground: false, authorization: .notDetermined)), .keep)
        // 拒絕 / 受限：不開；已經在跑（權限被收回）就停
        XCTAssertEqual(policy.decide(Input(enabled: true, authorization: .denied)), .keep)
        XCTAssertEqual(policy.decide(Input(enabled: true, authorization: .restricted)), .keep)
        XCTAssertEqual(policy.decide(Input(enabled: true, authorization: .denied, isRunning: true)), .stop)
    }

    func testDecideStartOnlyInForeground() {
        XCTAssertEqual(policy.decide(Input(enabled: true)), .start)
        XCTAssertEqual(policy.decide(Input(enabled: true, authorization: .always)), .start)
        XCTAssertEqual(policy.decide(Input(enabled: true, isForeground: false)), .keep)
        // 已經在跑：背景也維持
        XCTAssertEqual(policy.decide(Input(enabled: true, isForeground: false, isRunning: true)), .keep)
        XCTAssertEqual(policy.decide(Input(enabled: true, isRunning: true)), .keep)
    }

    func testStatus() {
        XCTAssertEqual(policy.status(Input(enabled: false)), "關閉")
        XCTAssertEqual(policy.status(Input(enabled: true, authorization: .denied)), "需要定位權限：到系統設定允許「使用 App 期間」")
        XCTAssertEqual(policy.status(Input(enabled: true, authorization: .restricted)), "這支 iPhone 不允許定位")
        XCTAssertEqual(policy.status(Input(enabled: true, authorization: .notDetermined)), "尚未允許定位（會在前景詢問一次）")
        XCTAssertEqual(policy.status(Input(enabled: true, isRunning: true)), "執行中（鎖定後也會嘗試更新歌詞）")
        XCTAssertEqual(policy.status(Input(enabled: true, loggedIn: false)), "請先登入 Spotify")
        XCTAssertEqual(policy.status(Input(enabled: true, liveActivityEnabled: false)), "鎖定畫面歌詞已關閉，用不到定位")
        XCTAssertEqual(policy.status(Input(enabled: true, inCar: false)), "連上 CarPlay 後啟動")
        XCTAssertEqual(policy.status(Input(enabled: true, activityIsActive: false)), "等即時動態開始")
        XCTAssertEqual(policy.status(Input(enabled: true, isForeground: false)), "等回到前景再開始")
        XCTAssertEqual(policy.status(Input(enabled: true, authorization: .always)), "準備中")
    }

    func testPreferenceDefaultOff() {
        let suite = "RoundEightTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let p = Preferences(defaults: d)
        XCTAssertFalse(p.locationKeepAlive)
        p.locationKeepAlive = true
        XCTAssertTrue(p.locationKeepAlive)
        XCTAssertEqual(d.object(forKey: "locationKeepAlive") as? Bool, true)
    }

    /// 開車模式的提示：定位保活執行中時改成說明實驗
    func testDrivingHintMentionsLocation() {
        let driving = DrivingModePolicy()
        let base = DrivingModePolicy.Input(isForeground: true, carConnected: true)
        XCTAssertFalse(base.locationKeepAlive)
        let on = DrivingModePolicy.Input(isForeground: true, carConnected: true, locationKeepAlive: true)
        XCTAssertEqual(driving.hint(on), "定位保活執行中：鎖定後也會嘗試更新 CarPlay 歌詞（實驗）。沒跟上就回到 CarLyrics")
        // 保持螢幕的設定關掉也一樣（定位保活比它優先）
        let off = DrivingModePolicy.Input(isForeground: true, carConnected: true, keepAwakeWhileDriving: false,
                                          locationKeepAlive: true)
        XCTAssertEqual(driving.hint(off), driving.hint(on))
        XCTAssertNotEqual(driving.hint(base), driving.hint(on))
        // 不在車上：沒有提示
        XCTAssertNil(driving.hint(DrivingModePolicy.Input(isForeground: true, carConnected: false, locationKeepAlive: true)))
    }
}

final class LiveActivityReasonStatsTests: XCTestCase {
    private typealias Reason = LiveActivityBackgroundReason

    func testCurrentReason() {
        XCTAssertEqual(Reason.current(background: false, locationActive: true, backgroundTask: true), .foreground)
        XCTAssertEqual(Reason.current(background: true, locationActive: true, backgroundTask: true), .location)
        XCTAssertEqual(Reason.current(background: true, locationActive: false, backgroundTask: true), .backgroundTask)
        XCTAssertEqual(Reason.current(background: true, locationActive: false, backgroundTask: false), .audioOnly)
    }

    func testLabels() {
        XCTAssertEqual(Reason.allCases.map(\.label), ["前景", "音訊", "背景任務", "定位"])
        XCTAssertEqual(Reason.location.rawValue, "location")
    }

    func testRecordAndSummary() {
        var s = LiveActivityReasonStats()
        XCTAssertEqual(s.summary, "尚未送出")
        XCTAssertEqual(s[.audioOnly], LiveActivityReasonStats.Bucket())
        XCTAssertNil(s.locationVerdict)
        s.recordSent(.foreground)
        s.record(.foreground, accepted: true)
        s.recordSent(.audioOnly)
        s.recordSent(.audioOnly)
        s.record(.audioOnly, accepted: false)
        // 送出 2、驗證到 1：差額是來不及驗證的
        XCTAssertEqual(s[.audioOnly], LiveActivityReasonStats.Bucket(sent: 2, accepted: 0, rejected: 1))
        XCTAssertEqual(s[.foreground], LiveActivityReasonStats.Bucket(sent: 1, accepted: 1, rejected: 0))
        XCTAssertEqual(s.summary, "前景 套用1 擋0 送1 · 音訊 套用0 擋1 送2")
        XCTAssertEqual(s.buckets.count, 2)
        // 沒送過只有驗證（理論上不會）也要能記
        s.record(.backgroundTask, accepted: true)
        XCTAssertEqual(s[.backgroundTask].accepted, 1)
        XCTAssertFalse(s.summary.contains("背景任務"))
    }

    func testLocationVerdict() {
        var all = LiveActivityReasonStats()
        all.recordSent(.location)
        all.record(.location, accepted: true)
        all.record(.location, accepted: true)
        XCTAssertEqual(all.locationVerdict, "定位保活期間全部被套用（2 次）")
        var none = LiveActivityReasonStats()
        none.record(.location, accepted: false)
        XCTAssertEqual(none.locationVerdict, "定位保活期間全部被擋（1 次）")
        var mixed = LiveActivityReasonStats()
        mixed.record(.location, accepted: true)
        mixed.record(.location, accepted: false)
        XCTAssertEqual(mixed.locationVerdict, "定位保活期間部分被套用（套用 1、被擋 1）")
        XCTAssertNotEqual(all, none)
    }
}

final class RoundEightErrorMappingTests: XCTestCase {
    func testControlRateLimitMapsToRateLimited() {
        XCTAssertEqual(UserFacingError(SpotifyAPIError.http(429, "")), .rateLimited(seconds: 5))
        XCTAssertEqual(UserFacingError(SpotifyAPIError.http(401, "")), .spotifyUnauthorized)
        XCTAssertEqual(UserFacingError(SpotifyAPIError.http(503, "")), .spotifyServer(503))
    }
}
