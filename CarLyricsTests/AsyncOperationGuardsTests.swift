import XCTest

final class AsyncOperationGuardsTests: XCTestCase {
    func testOldRefreshCannotOwnNewLoginOrClearItsTask() {
        var session = SessionGeneration()
        let oldRefresh = session
        session.advance() // successful reauthorization
        let newRefresh = session
        XCTAssertNotEqual(oldRefresh, session)
        XCTAssertEqual(newRefresh, session)
        session.advance() // logout
        XCTAssertNotEqual(newRefresh, session)
    }

    func testImmediateRetriesCannotShortenCooldown() {
        var cooldown = RequestCooldown()
        let now = Date(timeIntervalSince1970: 100)
        cooldown.impose(seconds: 60, now: now)
        XCTAssertEqual(cooldown.remaining(at: now.addingTimeInterval(5)), 55)
        cooldown.impose(seconds: 2, now: now.addingTimeInterval(5))
        XCTAssertEqual(cooldown.remaining(at: now.addingTimeInterval(10)), 50)
        XCTAssertEqual(cooldown.remaining(at: now.addingTimeInterval(60)), 0)
        cooldown.impose(seconds: 30, now: now.addingTimeInterval(50))
        XCTAssertEqual(cooldown.remaining(at: now.addingTimeInterval(60)), 20)
    }

    func testPickerCannotApplyOldResultsOrImportToNewTrack() {
        XCTAssertTrue(LyricsSelectionPolicy.canApply(target: "A", current: "A"))
        XCTAssertFalse(LyricsSelectionPolicy.canApply(target: "A", current: "B"))
        XCTAssertFalse(LyricsSelectionPolicy.canApply(target: "A", current: nil))
        XCTAssertFalse(LyricsSelectionPolicy.canApply(target: nil, current: nil))
    }
}
