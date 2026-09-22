import XCTest

final class LyricsStateTests: XCTestCase {
    func testFromResult() {
        XCTAssertEqual(LyricsState(.synced(Fixture.lrc(count: 3))).lines.count, 3)
        XCTAssertEqual(LyricsState(.plain("未同步")), .plain("未同步"))
        XCTAssertEqual(LyricsState(.instrumental), .instrumental)
        XCTAssertEqual(LyricsState(.notFound), .notFound)
        // 「同步」但解析不出任何一行 → 當成未同步文字
        XCTAssertEqual(LyricsState(.synced("沒有時間碼")), .plain("沒有時間碼"))
        if case .failed = LyricsState(.failed("x")) {} else { XCTFail() }
    }

    func testLabels() {
        XCTAssertEqual(LyricsState.searching.label, "搜尋歌詞中…")
        XCTAssertTrue(LyricsState.searching.isSearching)
        XCTAssertEqual(LyricsState.synced(Fixture.lines(count: 2)).label, "同步歌詞（2 行）")
    }

    func testResultFromLRCLIBTrack() {
        let synced = LRCLIBTrack(id: 1, trackName: nil, artistName: nil, albumName: nil, duration: nil,
                                 instrumental: false, plainLyrics: "未同步", syncedLyrics: Fixture.lrc(count: 1))
        XCTAssertEqual(LyricsResult(track: synced), .synced(Fixture.lrc(count: 1)))
        let empty = LRCLIBTrack(id: 2, trackName: nil, artistName: nil, albumName: nil, duration: nil,
                                instrumental: nil, plainLyrics: " ", syncedLyrics: nil)
        XCTAssertNil(LyricsResult(track: empty))
    }
}

final class UserFacingErrorTests: XCTestCase {
    func testURLErrors() {
        XCTAssertEqual(UserFacingError(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(UserFacingError(URLError(.timedOut)), .timeout)
    }

    func testSpotifyErrors() {
        XCTAssertEqual(UserFacingError(SpotifyAPIError.forbidden("")), .spotifyForbidden)
        XCTAssertEqual(UserFacingError(SpotifyAPIError.noActiveDevice), .spotifyNoDevice)
        XCTAssertEqual(UserFacingError(SpotifyAPIError.http(502, "")), .spotifyServer(502))
        XCTAssertEqual(UserFacingError(SpotifyAuthError.tokenRequestFailed(400, "invalid_grant")), .spotifyUnauthorized)
    }

    func testActionsAndChineseText() {
        XCTAssertEqual(UserFacingError.missingControlScope.action, .relogin)
        XCTAssertEqual(UserFacingError.timeout.action, .retry)
        XCTAssertEqual(UserFacingError.offline.action, .none)
        XCTAssertFalse(UserFacingError.offline.title.contains("Internet"))
        XCTAssertTrue(UserFacingError.spotifyUnauthorized.needsAttention)
    }
}

final class PreferencesTests: XCTestCase {
    func testDefaultsAndClamping() {
        let suite = "CarLyricsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let p = Preferences(defaults: d)
        XCTAssertTrue(p.backgroundEnabled)
        XCTAssertTrue(p.liveActivityEnabled)
        XCTAssertFalse(p.keepScreenOn)
        XCTAssertEqual(p.focusFontScale, 1)
        p.focusFontScale = 3
        XCTAssertEqual(p.focusFontScale, 1.4)
        p.globalOffset = 0.75
        XCTAssertEqual(d.double(forKey: "lyricsOffset"), 0.75)   // 沿用舊 key
        XCTAssertNil(p.lastHeartbeat)
        p.lastHeartbeat = (Date(timeIntervalSince1970: 100), true)
        XCTAssertEqual(p.lastHeartbeat?.inBackground, true)
    }
}
