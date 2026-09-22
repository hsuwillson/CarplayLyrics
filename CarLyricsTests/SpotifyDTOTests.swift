import XCTest

// 自編 JSON fixture（歌名、歌手都是假的）
final class SpotifyDTOTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_000)

    private func parse(_ json: String) throws -> PlayerPollResult {
        try SpotifyResponseParser.parsePlayer(Data(json.utf8), measuredAt: t, sentAt: t)
    }

    func testTrack() throws {
        let r = try parse("""
        {"is_playing": true, "progress_ms": 12345, "currently_playing_type": "track",
         "item": {"id": "abc", "name": "測試歌名", "duration_ms": 200000,
                  "album": {"name": "測試專輯", "images": [
                      {"url": "https://example.com/640.jpg", "width": 640, "height": 640},
                      {"url": "https://example.com/300.jpg", "width": 300, "height": 300},
                      {"url": "https://example.com/64.jpg", "width": 64, "height": 64}]},
                  "artists": [{"name": "甲"}, {"name": "乙"}]}}
        """)
        guard case .playing(let np, _, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(np.trackID, "abc")
        XCTAssertEqual(np.artist, "甲, 乙")
        XCTAssertEqual(np.primaryArtist, "甲")
        XCTAssertEqual(np.progress, 12.345, accuracy: 0.0001)
        XCTAssertEqual(np.duration, 200)
        XCTAssertEqual(np.artworkURL?.absoluteString, "https://example.com/300.jpg")
        XCTAssertEqual(np.smallArtworkURL?.absoluteString, "https://example.com/64.jpg")
    }

    func testAdIsNonMusic() throws {
        let r = try parse(#"{"is_playing": true, "progress_ms": 1000, "currently_playing_type": "ad", "item": null}"#)
        XCTAssertEqual(r, .nonMusic(.ad, isPlaying: true))
    }

    func testEpisodeIsNonMusic() throws {
        let r = try parse("""
        {"is_playing": false, "progress_ms": 1000, "currently_playing_type": "episode",
         "item": {"id": "ep1", "name": "測試節目", "duration_ms": 3600000}}
        """)
        XCTAssertEqual(r, .nonMusic(.episode, isPlaying: false))
    }

    func testMissingItemOrProgress() throws {
        XCTAssertEqual(try parse(#"{"is_playing": false, "progress_ms": null, "item": null}"#), .nothing)
        let r = try parse(#"{"is_playing": true, "item": {"id": "x", "name": "測試", "duration_ms": 1000}}"#)
        guard case .playing(let np, _, _) = r else { return XCTFail() }
        XCTAssertEqual(np.progress, 0)
        XCTAssertEqual(np.album, "")
        XCTAssertNil(np.artworkURL)
    }

    func testLocalFileWithoutIDIsNothing() throws {
        let r = try parse(#"{"is_playing": true, "currently_playing_type": "track", "item": {"id": null, "name": "本機", "duration_ms": 1000}}"#)
        XCTAssertEqual(r, .nothing)
    }

    func testQueue() {
        let json = #"{"queue": [{"id": "q1", "name": "下一首", "duration_ms": 150000, "artists": [{"name": "丙"}]}]}"#
        let np = SpotifyResponseParser.parseQueueFirst(Data(json.utf8))
        XCTAssertEqual(np?.trackID, "q1")
        XCTAssertEqual(np?.isPlaying, false)
        XCTAssertNil(SpotifyResponseParser.parseQueueFirst(Data(#"{"queue": []}"#.utf8)))
    }

    func testCommandPaths() {
        XCTAssertEqual(PlayerCommand.restart.path, "seek?position_ms=0")
        XCTAssertEqual(PlayerCommand.seek(ms: -5).path, "seek?position_ms=0")
        XCTAssertEqual(PlayerCommand.next.method, "POST")
        XCTAssertEqual(PlayerCommand.pause.method, "PUT")
    }
}
