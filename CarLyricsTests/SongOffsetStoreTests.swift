import XCTest

final class SongOffsetStoreTests: XCTestCase {
    func testSetGetAndRemove() {
        let suite = "SongOffsetStoreTests-\(UUID().uuidString)"
        let store = SongOffsetStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(store.offset(for: "a"), 0)
        store.set(0.75, for: "a")
        XCTAssertEqual(store.offset(for: "a"), 0.75)
        XCTAssertEqual(store.offset(for: "b"), 0)
        store.set(0, for: "a")
        XCTAssertEqual(store.offset(for: "a"), 0)
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
