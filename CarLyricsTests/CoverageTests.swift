import XCTest

// 補齊 Core 每一條分支的測試（目標：Core 100% 覆蓋率）。內容全部是自編字串。

final class SpotifyModelsCoverageTests: XCTestCase {
    func testErrorDescriptions() {
        XCTAssertEqual(SpotifyAPIError.http(500, "x").errorDescription, "Spotify API 錯誤（HTTP 500）x")
        XCTAssertNotNil(SpotifyAPIError.forbidden("y").errorDescription)
        XCTAssertNotNil(SpotifyAPIError.noActiveDevice.errorDescription)
        let auth: [SpotifyAuthError] = [.notLoggedIn, .cancelled, .invalidCallback("a"), .stateMismatch,
                                        .missingRefreshToken, .tokenRequestFailed(400, "b")]
        for e in auth { XCTAssertFalse((e.errorDescription ?? "").isEmpty) }
    }

    func testNonMusicLabels() {
        XCTAssertEqual(NonMusicKind.ad.label, "廣告播放中")
        XCTAssertEqual(NonMusicKind.episode.label, "Podcast 播放中")
        XCTAssertEqual(NonMusicKind.unknown.label, "正在播放非音樂內容")
    }

    func testUnknownTypeIsNonMusic() throws {
        let r = try SpotifyResponseParser.parsePlayer(
            Data(#"{"is_playing": true, "currently_playing_type": "unknown", "item": null}"#.utf8),
            measuredAt: Date(), sentAt: Date())
        XCTAssertEqual(r, .nonMusic(.unknown, isPlaying: true))
    }

    func testCommandsAll() {
        let all: [PlayerCommand] = [.previous, .next, .play, .pause, .restart, .seek(ms: 1500)]
        XCTAssertEqual(all.map(\.name), ["previous", "next", "play", "pause", "restart", "seek 1500ms"])
        XCTAssertEqual(all.map(\.method), ["POST", "POST", "PUT", "PUT", "PUT", "PUT"])
        XCTAssertEqual(all.map(\.path), ["previous", "next", "play", "pause", "seek?position_ms=0", "seek?position_ms=1500"])
    }

    func testWithKeepsArtwork() {
        var np = Fixture.nowPlaying()
        np.artworkURL = URL(string: "https://example.com/a.jpg")
        let p = np.with(progress: 1)
        XCTAssertEqual(p.artworkURL, np.artworkURL)
        XCTAssertEqual(p.progress, 1)
        XCTAssertEqual(np.with(isPlaying: false).progress, np.progress)
    }

    func testPickWithoutImages() {
        XCTAssertNil(SpotifyResponseParser.pick([], target: 64))
    }
}

final class UserFacingErrorCoverageTests: XCTestCase {
    struct Other: Error {}

    func testMappingBranches() {
        XCTAssertEqual(UserFacingError(UserFacingError.quotaExceeded), .quotaExceeded)
        XCTAssertEqual(UserFacingError(URLError(.networkConnectionLost)), .offline)
        XCTAssertEqual(UserFacingError(URLError(.cannotFindHost)), .timeout)
        XCTAssertEqual(UserFacingError(URLError(.badURL)), .unknown("網路錯誤（\(URLError.Code.badURL.rawValue)）"))
        XCTAssertEqual(UserFacingError(SpotifyAPIError.http(401, "")), .spotifyUnauthorized)
        XCTAssertEqual(UserFacingError(SpotifyAuthError.notLoggedIn), .spotifyUnauthorized)
        XCTAssertEqual(UserFacingError(SpotifyAuthError.tokenRequestFailed(500, "")), .spotifyServer(500))
        XCTAssertEqual(UserFacingError(SpotifyAuthError.stateMismatch),
                       .loginFailed(SpotifyAuthError.stateMismatch.localizedDescription))
        if case .unknown = UserFacingError(Other()) {} else { XCTFail() }
    }

    func testAllTextAndActions() {
        let all: [UserFacingError] = [.offline, .timeout, .spotifyUnauthorized, .spotifyForbidden, .spotifyNoDevice,
                                      .spotifyServer(503), .rateLimited(seconds: 3), .quotaExceeded, .missingControlScope,
                                      .lyricsUnavailable("x"), .loginFailed("y"), .unknown("z")]
        for e in all {
            XCTAssertFalse(e.title.isEmpty)
            XCTAssertFalse(e.message.isEmpty)
            _ = e.needsAttention
            switch e.action {
            case .none: XCTAssertNil(e.actionTitle)
            default: XCTAssertNotNil(e.actionTitle)
            }
        }
        XCTAssertEqual(UserFacingError.loginFailed("y").message, "y")
        XCTAssertEqual(UserFacingError.unknown("z").message, "z")
        XCTAssertEqual(UserFacingError.spotifyForbidden.action, .relogin)
        XCTAssertEqual(UserFacingError.lyricsUnavailable("x").action, .retry)
        XCTAssertEqual(UserFacingError.spotifyServer(1).action, .retry)
        XCTAssertTrue(UserFacingError.quotaExceeded.needsAttention)
        XCTAssertFalse(UserFacingError.timeout.needsAttention)
    }

    func testActionTitles() {
        XCTAssertEqual(UserFacingError.missingControlScope.actionTitle, "重新登入")
        XCTAssertEqual(UserFacingError.timeout.actionTitle, "重試")
    }
}

final class LyricsModelsCoverageTests: XCTestCase {
    func testShortDescriptions() {
        XCTAssertEqual([LyricsResult.synced(""), .plain(""), .instrumental, .notFound, .failed("")].map(\.shortDescription),
                       ["同步歌詞", "未同步歌詞", "純音樂", "找不到", "失敗"])
    }

    func testResultFromTrackVariants() {
        func t(instrumental: Bool?, plain: String?) -> LRCLIBTrack {
            LRCLIBTrack(id: 1, trackName: nil, artistName: nil, albumName: nil, duration: nil,
                        instrumental: instrumental, plainLyrics: plain, syncedLyrics: nil)
        }
        XCTAssertEqual(LyricsResult(track: t(instrumental: true, plain: nil)), .instrumental)
        XCTAssertEqual(LyricsResult(track: t(instrumental: false, plain: "未同步")), .plain("未同步"))
    }

    func testStateAccessorsAndLabels() {
        XCTAssertEqual(LyricsState.plain("x").plainText, "x")
        XCTAssertNil(LyricsState.idle.plainText)
        XCTAssertEqual(LyricsState.idle.lines, [])
        let labels = [LyricsState.idle, .plain(""), .instrumental, .notFound, .failed(.offline)].map(\.label)
        XCTAssertEqual(labels, ["沒有播放中的歌曲", "只有未同步歌詞", "純音樂", "找不到歌詞", "歌詞載入失敗"])
        XCTAssertFalse(LyricsState.idle.isSearching)
    }

    func testTrackQueryEquality() {
        let a = TrackQuery(trackID: "a", title: "t", artist: "r", album: "b", duration: 1)
        XCTAssertEqual(a, TrackQuery(trackID: "a", title: "t", artist: "r", album: "b", duration: 1))
    }
}

final class LyricsCacheCoverageTests: XCTestCase {
    func testStandardAndSlashInID() {
        let std = LyricsCache.standard()
        XCTAssertTrue(std.cacheDirectory.path.contains("lyrics-v2"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = LyricsCache(cacheDirectory: dir.appendingPathComponent("c"), overrideDirectory: dir.appendingPathComponent("o"))
        c.save(.instrumental, trackID: "a/b")
        XCTAssertEqual(c.cached("a/b"), .instrumental)
        // 壞掉的檔案 → 當成沒有
        try? Data("壞掉".utf8).write(to: dir.appendingPathComponent("c/x.json"))
        XCTAssertNil(c.cached("x"))
    }
}

final class PoliciesCoverageTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 50_000)

    func testNonMusicAndLoggedOut() {
        let p = PollPolicy()
        XCTAssertEqual(p.delay(for: .nonMusic), 5)
        XCTAssertEqual(p.delay(for: .nonMusic, quotaActive: true), 10)
        XCTAssertEqual(p.delay(for: .loggedOut), 10)
    }

    func testIdleLimits() {
        let p = IdlePolicy()
        XCTAssertEqual(p.limit(for: .paused), 1800)
        XCTAssertEqual(p.limit(for: .nothing), 600)
    }

    func testOptimisticGuardInactive() {
        var g = OptimisticGuard()
        XCTAssertFalse(g.isActive(now: t0))
        let s = PlaybackSnapshot(trackID: "a", progress: 1, duration: 10, isPlaying: true, timestamp: t0)
        XCTAssertFalse(g.shouldIgnore(current: s, incoming: s, now: t0))
        g.arm(now: t0)
        XCTAssertTrue(g.isActive(now: t0.addingTimeInterval(1)))
        XCTAssertFalse(g.shouldIgnore(current: nil, incoming: s, now: t0))
    }

    func testReloadPolicyMisc() {
        var p = WidgetReloadPolicy()
        XCTAssertFalse(p.isDisabled(now: t0))
        XCTAssertEqual(p, WidgetReloadPolicy())
        XCTAssertNil(p.lastWindowResult)
        XCTAssertTrue(p.allowLineReload(now: t0, isForeground: false, renderCount: 0))
        p.resetWindow()
        XCTAssertNotEqual(p, WidgetReloadPolicy())
        XCTAssertEqual(p.recent, [t0])
        XCTAssertEqual(p.lastRequestAt, t0)
        XCTAssertNil(p.disabledUntil)
        XCTAssertEqual(p.lastImportantAt, .distantPast)
        // 視窗判定後會記錄結果
        var q = WidgetReloadPolicy(windowSize: 1)
        XCTAssertTrue(q.allowLineReload(now: t0, isForeground: false, renderCount: 0))
        XCTAssertTrue(q.allowLineReload(now: t0.addingTimeInterval(3), isForeground: false, renderCount: 5))
        XCTAssertEqual(q.lastWindowResult?.rendered, 5)
        XCTAssertEqual(q.lastWindowResult?.requested, 1)
    }
}

final class TimelineCoverageTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 20_000)

    func testLastLineHasNoMoreFrames() {
        let s = LyricsTimelineSnapshot(trackID: "a", title: "測試", artist: "甲", lines: Fixture.lines(count: 2),
                                       songStart: t0, isPlaying: true, message: nil, updatedAt: t0)
        let f = s.frames(from: t0.addingTimeInterval(100))
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].next, "")
        XCTAssertNil(s.playbackInterval)       // 長度未知
    }

    func testPausedHasNoInterval() {
        var s = LyricsTimelineSnapshot.idle("x", at: t0)
        s.duration = 100
        XCTAssertNil(s.playbackInterval)
        XCTAssertTrue(s.isSameTimeline(as: .idle("x", at: t0)))
        XCTAssertEqual(LyricsTimelineMode(rawValue: "paragraph"), .paragraph)
    }

    func testMessageWhilePlayingWithoutLines() {
        let s = LyricsTimelineSnapshot(trackID: "a", title: "測試", artist: "", lines: [], songStart: t0,
                                       isPlaying: true, message: nil, updatedAt: t0)
        let f = s.frames(from: t0)
        XCTAssertEqual(f[0].current, "測試")
        XCTAssertEqual(f[0].upcoming, [])
    }
}

final class ActivityContentCoverageTests: XCTestCase {
    func testStaticContents() {
        XCTAssertEqual(LiveActivityContentBuilder.connecting.currentLine, "連接 Spotify 中…")
        XCTAssertEqual(LiveActivityContentBuilder.stopped.currentLine, "Spotify 沒有在播放")
        XCTAssertEqual(LiveActivityContentBuilder.backgroundOff.currentLine, "背景執行已關閉")
        let ad = LiveActivityContentBuilder.nonMusic(.ad)
        XCTAssertEqual(ad.currentLine, "廣告播放中")
        XCTAssertTrue(ad.isPlaying)
    }

    func testUnknownDurationHasNoInterval() {
        let np = Fixture.nowPlaying(duration: 0)
        let m = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: .instrumental, display: .empty,
                                                 songStart: Date(), artworkFile: nil)
        XCTAssertNil(m.songEnd)
    }
}

final class MiscCoverageTests: XCTestCase {
    func testAppClock() {
        let a = AppClock.now()
        let b = AppClock.now()
        XCTAssertGreaterThanOrEqual(b, a)
        XCTAssertEqual(AppClock.wallDate(for: b).timeIntervalSince(Date()), 0, accuracy: 1)
    }

    func testSessionLabels() {
        let all: [SessionState] = [.loggedOut, .connecting, .notPlaying, .nonMusic(.ad), .paused, .playing]
        XCTAssertEqual(all.map(\.label), ["請先登入 Spotify", "連接 Spotify 中…", "Spotify 沒有在播放", "廣告播放中", "已暫停", "播放中"])
    }

    func testPreferencesAllSetters() {
        let suite = "CoverageTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let p = Preferences(defaults: d)
        p.backgroundEnabled = false
        p.liveActivityEnabled = false
        p.keepScreenOn = true
        p.hasSeenSetup = true
        XCTAssertEqual(p.globalOffset, 0)
        XCTAssertFalse(p.backgroundEnabled)
        XCTAssertFalse(p.liveActivityEnabled)
        XCTAssertTrue(p.keepScreenOn)
        XCTAssertTrue(p.hasSeenSetup)
        XCTAssertFalse(Preferences().defaults === d)
        p.lastHeartbeat = (Date(timeIntervalSince1970: 5), false)
        p.lastHeartbeat = nil
        XCTAssertNil(p.lastHeartbeat)
    }

    func testProvisioningProfileEdgeCases() {
        // 測試 bundle 沒有描述檔
        XCTAssertNil(ProvisioningProfile.embedded(in: Bundle(for: MiscCoverageTests.self)))
        // 有 <?xml 但沒有 </plist>
        XCTAssertNil(ProvisioningProfile(data: Data("<?xml version=\"1.0\"?><plist>".utf8)))
        // XML 不是字典
        let arrayPlist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array><string>a</string></array></plist>
        """
        XCTAssertNil(ProvisioningProfile(data: Data(arrayPlist.utf8)))
    }

    func testParserRejections() {
        XCTAssertNil(LRCParser.parseTimestamp("1:2:3:4"))
        XCTAssertNil(LRCParser.parseTimestamp("-1:02"))
        XCTAssertNil(LRCParser.parseTimestamp("00:02.x"))
        XCTAssertNil(LRCParser.parseOffset("offset:abc"))
        XCTAssertNil(LRCParser.parseOffset("length:100"))
        XCTAssertTrue(LRCParser.isCredit("Composer: 測試"))
        XCTAssertFalse(LRCParser.isCredit("測試第一句"))
        XCTAssertEqual(LRCParser.cleanText("  測試   句  "), "測試 句")
        // 只有製作名單的歌詞不會被清空
        XCTAssertEqual(LRCParser.parse("[00:00.00]作詞：測試").count, 1)
    }

    func testEngineResetAndEmptyDisplay() {
        var e = LyricsSyncEngine()
        e.update(PlaybackSnapshot(trackID: "a", progress: 1, duration: 10, isPlaying: true, timestamp: Date()))
        e.reset()
        XCTAssertNil(e.snapshot)
        XCTAssertNil(e.position(at: Date()))
        XCTAssertEqual(LyricsDisplay.empty, LyricsDisplay(index: nil, current: "", next: ""))
    }

    func testMatcherHelpers() {
        let t = LRCLIBTrack(id: 1, trackName: nil, artistName: nil, albumName: nil, duration: 100,
                            instrumental: true, plainLyrics: nil, syncedLyrics: nil)
        XCTAssertFalse(t.hasPlain)
        XCTAssertFalse(t.hasSynced)
        // 不知道歌曲長度時照同步優先排序，純音樂也保留
        XCTAssertEqual(LRCLIBMatcher.rank([t], duration: 0).map(\.id), [1])
        XCTAssertNil(LRCLIBMatcher.bestMatch([t], duration: 100))
    }

    func testBackoffZero() {
        XCTAssertEqual(PollBackoff.delay(forErrorStreak: 0), 5)
        XCTAssertEqual(PollBackoff.delay(forErrorStreak: 20), 60)
    }

    func testEmbeddedProfileFromBundle() throws {
        XCTAssertNil(ProvisioningProfile.embedded())   // 測試執行檔沒有描述檔
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Entitlements</key><dict>\
        <key>com.apple.security.application-groups</key><array><string>group.test</string></array></dict></dict></plist>
        """
        try Data(xml.utf8).write(to: dir.appendingPathComponent("embedded.mobileprovision"))
        let bundle = try XCTUnwrap(Bundle(url: dir))
        XCTAssertEqual(ProvisioningProfile.embedded(in: bundle)?.appGroups, ["group.test"])
    }

    func testSongOffsetStoreDefaultInit() {
        XCTAssertEqual(SongOffsetStore().defaults, UserDefaults.standard)
    }

    func testPlainFallbackPicksClosest() {
        func t(_ id: Int, _ d: Double) -> LRCLIBTrack {
            LRCLIBTrack(id: id, trackName: nil, artistName: nil, albumName: nil, duration: d,
                        instrumental: false, plainLyrics: "未同步", syncedLyrics: nil)
        }
        XCTAssertEqual(LRCLIBMatcher.bestMatch([t(1, 104), t(2, 101)], duration: 100)?.id, 2)
    }

    func testImageWithoutWidthAndQueueWithoutID() {
        let imgs = [CurrentlyPlayingResponse.Image(url: "https://example.com/x.jpg", width: nil, height: nil),
                    CurrentlyPlayingResponse.Image(url: "https://example.com/y.jpg", width: 60, height: 60)]
        XCTAssertEqual(SpotifyResponseParser.pick(imgs, target: 64)?.absoluteString, "https://example.com/y.jpg")
        let json = #"{"queue": [{"id": null, "name": "本機", "duration_ms": 1}]}"#
        XCTAssertNil(SpotifyResponseParser.parseQueueFirst(Data(json.utf8)))
    }

    func testEnginePausedToPaused() {
        let t0 = Date(timeIntervalSince1970: 0)
        var e = LyricsSyncEngine()
        e.update(PlaybackSnapshot(trackID: "a", progress: 5, duration: 10, isPlaying: false, timestamp: t0))
        XCTAssertEqual(e.update(PlaybackSnapshot(trackID: "a", progress: 5, duration: 10, isPlaying: false,
                                                 timestamp: t0.addingTimeInterval(3))), .none)
    }

    func testRemainingPartialRegions() {
        // 描述檔沒有 Entitlements
        let xml = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Name</key><string>x</string></dict></plist>"#
        XCTAssertEqual(ProvisioningProfile(data: Data(xml.utf8))?.appGroups, [])
        // 非 ASCII 數字的小數（isNumber 但 Double 解析不了）→ 小數當 0
        XCTAssertEqual(LRCParser.parseTimestamp("00:01.٣"), 1)
        // 第一張圖有寬度、第二張沒有
        let imgs = [CurrentlyPlayingResponse.Image(url: "https://example.com/y.jpg", width: 60, height: 60),
                    CurrentlyPlayingResponse.Image(url: "https://example.com/x.jpg", width: nil, height: nil)]
        XCTAssertEqual(SpotifyResponseParser.pick(imgs, target: 64)?.absoluteString, "https://example.com/y.jpg")
        // 沒有任何歌詞
        XCTAssertEqual(LyricsDisplay(lines: [], position: 3), .empty)
    }
}
