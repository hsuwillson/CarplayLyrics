import XCTest

final class LRCLIBMatcherTests: XCTestCase {
    private func track(_ id: Int, _ duration: Double?, synced: String? = nil, plain: String? = nil) -> LRCLIBTrack {
        LRCLIBTrack(id: id, trackName: "測試歌名", artistName: "測試歌手", albumName: nil,
                    duration: duration, instrumental: false, plainLyrics: plain, syncedLyrics: synced)
    }

    func testPrefersSyncedWithinTolerance() {
        let r = [track(1, 200, plain: "測試"), track(2, 203, synced: "[00:01.00]測試")]
        XCTAssertEqual(LRCLIBMatcher.bestMatch(r, duration: 200)?.id, 2)
    }

    func testClosestSynced() {
        let r = [track(1, 204, synced: "[00:01.00]測試"), track(2, 201, synced: "[00:01.00]測試")]
        XCTAssertEqual(LRCLIBMatcher.bestMatch(r, duration: 200)?.id, 2)
    }

    func testRejectsFarDurationAndFallsBackToPlain() {
        let r = [track(1, 260, synced: "[00:01.00]測試"), track(2, 199, plain: "測試")]
        XCTAssertEqual(LRCLIBMatcher.bestMatch(r, duration: 200)?.id, 2)
        XCTAssertNil(LRCLIBMatcher.bestMatch([track(3, nil, synced: "[00:01.00]測試")], duration: 200))
    }

    func testDecodeJSON() throws {
        let json = #"{"id":7,"trackName":"測試歌名","artistName":"測試歌手","albumName":"測試專輯","duration":180.5,"instrumental":false,"plainLyrics":"測試","syncedLyrics":"[00:01.00]測試"}"#
        let t = try JSONDecoder().decode(LRCLIBTrack.self, from: Data(json.utf8))
        XCTAssertEqual(t.id, 7)
        XCTAssertTrue(t.hasSynced)
    }

    func testRankDedupesAndOrders() {
        let r = [track(1, 210, plain: "測試"), track(2, 205, synced: "[00:01.00]測試"),
                 track(2, 205, synced: "[00:01.00]測試"), track(3, 200, synced: "[00:01.00]測試"),
                 track(4, 200)]
        XCTAssertEqual(LRCLIBMatcher.rank(r, duration: 200).map(\.id), [3, 2, 1])
    }
}
