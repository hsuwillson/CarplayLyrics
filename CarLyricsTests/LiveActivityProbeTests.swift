import XCTest

/// P1-4：「背景被擋」不是單行道——被擋期間每隔一段時間放一次換句更新出去探測，
/// 系統只是慢（不是拒絕）時，歌詞才不會一路凍結到換歌 / 回前景
final class LiveActivityProbeTests: XCTestCase {
    private let policy = LiveActivityUpdatePolicy()

    func testDefaultProbeInterval() {
        XCTAssertEqual(policy.blockedProbeInterval, 15)
        XCTAssertFalse(policy.shouldProbe(secondsSinceLastSend: 14.9))
        XCTAssertTrue(policy.shouldProbe(secondsSinceLastSend: 15))
        XCTAssertTrue(policy.shouldProbe(secondsSinceLastSend: .infinity))
    }

    /// 被擋 + 背景 + 換句：剛送過就先記住，隔夠久就探測
    func testBlockedRoutineProbesAfterInterval() {
        XCTAssertEqual(policy.decide(.init(isActive: true, backgroundBlocked: true, isInBackground: true,
                                           secondsSinceLastSend: 3)), .store)
        XCTAssertEqual(policy.decide(.init(isActive: true, backgroundBlocked: true, isInBackground: true,
                                           secondsSinceLastSend: 16)), .send)
        // 沒給就當成剛送過（舊呼叫端的行為不變）
        XCTAssertEqual(policy.decide(.init(isActive: true, backgroundBlocked: true, isInBackground: true)), .store)
    }

    /// 探測間隔只影響「被擋 + 背景 + 換句」這一種情況
    func testProbeIntervalDoesNotAffectOtherDecisions() {
        XCTAssertEqual(policy.decide(.init(isActive: true, backgroundBlocked: true, isInBackground: true,
                                           priority: .important, secondsSinceLastSend: 0)), .send)
        XCTAssertEqual(policy.decide(.init(isActive: true, backgroundBlocked: true, isInBackground: false,
                                           secondsSinceLastSend: 0)), .send)
        XCTAssertEqual(policy.decide(.init(isActive: true, backgroundBlocked: false, isInBackground: true,
                                           secondsSinceLastSend: 0)), .send)
        XCTAssertEqual(policy.decide(.init(isActive: true, backgroundBlocked: true, isInBackground: true,
                                           sameAsLast: true, secondsSinceLastSend: 100)), .skip)
        XCTAssertEqual(policy.decide(.init(isActive: false, backgroundBlocked: true, isInBackground: true,
                                           secondsSinceLastSend: 100)), .start)
        XCTAssertEqual(policy.decide(.init(isActive: false, startBlockedUntilForeground: true,
                                           secondsSinceLastSend: 100)), .skip)
    }

    func testProbeIntervalIsTunable() {
        var custom = policy
        custom.blockedProbeInterval = 30
        XCTAssertEqual(custom.decide(.init(isActive: true, backgroundBlocked: true, isInBackground: true,
                                           secondsSinceLastSend: 20)), .store)
        XCTAssertEqual(custom.decide(.init(isActive: true, backgroundBlocked: true, isInBackground: true,
                                           secondsSinceLastSend: 30)), .send)
        XCTAssertNotEqual(custom, policy)
    }

    /// 模擬一段被擋期間的換句序列：每 3 秒一句，只有每 15 秒那一次會送出
    func testProbeCadenceOverLineChanges() {
        var lastSend: TimeInterval = 0
        var sent: [TimeInterval] = []
        for t in stride(from: 3.0, through: 60, by: 3) {
            let decision = policy.decide(.init(isActive: true, backgroundBlocked: true, isInBackground: true,
                                               secondsSinceLastSend: t - lastSend))
            if decision == .send {
                sent.append(t)
                lastSend = t
            }
        }
        XCTAssertEqual(sent, [15, 30, 45, 60])
    }
}
