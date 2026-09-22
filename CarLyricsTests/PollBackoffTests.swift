import XCTest

final class PollBackoffTests: XCTestCase {
    func testBackoffSequence() {
        XCTAssertEqual(PollBackoff.delay(forErrorStreak: 0), 5)
        XCTAssertEqual(PollBackoff.delay(forErrorStreak: 1), 5)
        XCTAssertEqual(PollBackoff.delay(forErrorStreak: 2), 10)
        XCTAssertEqual(PollBackoff.delay(forErrorStreak: 3), 20)
        XCTAssertEqual(PollBackoff.delay(forErrorStreak: 4), 40)
        XCTAssertEqual(PollBackoff.delay(forErrorStreak: 5), 60)
        XCTAssertEqual(PollBackoff.delay(forErrorStreak: 50), 60)
    }
}
