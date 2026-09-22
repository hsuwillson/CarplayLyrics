import XCTest

final class LyricsCacheTests: XCTestCase {
    var dir: URL!
    var cache: LyricsCache!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cache = LyricsCache(cacheDirectory: dir.appendingPathComponent("c"), overrideDirectory: dir.appendingPathComponent("o"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSaveAndLoad() {
        cache.save(.synced(Fixture.lrc(count: 2)), trackID: "a")
        XCTAssertEqual(cache.cached("a"), .synced(Fixture.lrc(count: 2)))
        XCTAssertNil(cache.cached("b"))
    }

    func testFailedIsNotCached() {
        cache.save(.failed("逾時"), trackID: "a")
        XCTAssertNil(cache.cached("a"))
    }

    func testNotFoundExpiresAfterOneDay() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        cache.save(.notFound, trackID: "a", now: t)
        XCTAssertEqual(cache.cached("a", now: t.addingTimeInterval(3600)), .notFound)
        XCTAssertNil(cache.cached("a", now: t.addingTimeInterval(86_401)))
    }

    func testOverrideSurvivesClearCache() {
        cache.save(.plain("自動"), trackID: "a")
        cache.setOverride(.plain("手動"), trackID: "a")
        cache.clear()
        XCTAssertNil(cache.cached("a"))
        XCTAssertEqual(cache.override("a"), .plain("手動"))
        cache.removeOverride("a")
        XCTAssertNil(cache.override("a"))
    }
}
