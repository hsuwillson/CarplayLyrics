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

    func testContainsChecksExistenceAndNotFoundExpiry() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(cache.contains("a", now: t))
        // 歌詞內容不會過期
        cache.save(.synced(Fixture.lrc(count: 30)), trackID: "a", now: t)
        XCTAssertTrue(cache.contains("a", now: t.addingTimeInterval(86_400 * 30)))
        // 「找不到」一天後過期
        cache.save(.notFound, trackID: "b", now: t)
        XCTAssertTrue(cache.contains("b", now: t.addingTimeInterval(3600)))
        XCTAssertFalse(cache.contains("b", now: t.addingTimeInterval(86_401)))
        // 小的內容檔也算
        cache.save(.instrumental, trackID: "c")
        XCTAssertTrue(cache.contains("c"))
        // 只有手動指定也算
        cache.setOverride(.plain("手動"), trackID: "d")
        XCTAssertTrue(cache.contains("d"))
    }

    func testContainsTrustsLargeFileWithoutDecoding() throws {
        // 大檔只看大小，不解碼（所以連壞掉的大檔也當作有快取）
        try Data(String(repeating: "x", count: LyricsCache.smallEntryBytes + 1).utf8)
            .write(to: dir.appendingPathComponent("c/big.json"))
        XCTAssertTrue(cache.contains("big"))
        XCTAssertNil(cache.cached("big"))
        // 壞掉的小檔 → 沒有
        try Data("壞掉".utf8).write(to: dir.appendingPathComponent("c/small.json"))
        XCTAssertFalse(cache.contains("small"))
    }

    func testOldFormatStillLoads() throws {
        // 舊版 App 寫的檔案格式（LyricsResult 的預設 Codable）仍能讀
        let json = #"{"result":{"synced":{"_0":"[00:01.00]測試第1句"}},"savedAt":0}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("c/old.json"))
        XCTAssertEqual(cache.cached("old"), .synced("[00:01.00]測試第1句"))
        XCTAssertTrue(cache.contains("old"))
        try Data(#"{"result":{"notFound":{}},"savedAt":0}"#.utf8).write(to: dir.appendingPathComponent("c/nf.json"))
        XCTAssertEqual(cache.cached("nf", now: Date(timeIntervalSinceReferenceDate: 60)), .notFound)
    }

    func testFailureMemoryExpiresAndIsSeparateFromCache() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(cache.recentlyFailed("a", now: t))
        cache.recordFailure("a", now: t)
        XCTAssertTrue(cache.recentlyFailed("a", now: t.addingTimeInterval(3600)))
        XCTAssertFalse(cache.recentlyFailed("a", now: t.addingTimeInterval(LyricsCache.failureTTL + 1)))
        // 失敗紀錄不是快取
        XCTAssertNil(cache.cached("a"))
        XCTAssertFalse(cache.contains("a"))
        // 清除快取時一起清掉，之後還能再記
        cache.recordFailure("b")
        XCTAssertTrue(cache.recentlyFailed("b"))
        cache.clear()
        XCTAssertFalse(cache.recentlyFailed("b"))
        cache.recordFailure("b")
        XCTAssertTrue(cache.recentlyFailed("b"))
    }
}
