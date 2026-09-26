import XCTest

final class ReviewRegressionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    func testEndFramesNeverContainKaraokeRowsIncludingLateReload() {
        for mode in [LyricsTimelineMode.perLine, .paragraph] {
            for offset in [-2.0, 0, 2] {
                let snapshot = LyricsTimelineSnapshot(trackID: "test", title: "測試", artist: "測試",
                    lines: Fixture.lines(count: 3), songStart: t0.addingTimeInterval(-offset),
                    isPlaying: true, message: nil, updatedAt: t0, appliedOffset: offset,
                    duration: 30, mode: mode)
                let terminalDate = t0.addingTimeInterval(33)
                let last = snapshot.frames(from: t0).last!
                XCTAssertEqual(last.date, terminalDate)
                XCTAssertEqual(last.current, "♪ 等待下一首")
                XCTAssertTrue(snapshot.karaokeRows(at: last.date).isEmpty)
                for date in [terminalDate, t0.addingTimeInterval(100)] {
                    let frames = snapshot.frames(from: date)
                    XCTAssertEqual(frames.count, 1)
                    XCTAssertEqual(frames[0].current, "♪ 等待下一首")
                    XCTAssertTrue(snapshot.karaokeRows(at: date).isEmpty)
                }
                XCTAssertFalse(snapshot.karaokeRows(at: t0.addingTimeInterval(29)).isEmpty)
                var paused = snapshot
                paused.isPlaying = false
                XCTAssertFalse(paused.hasFinished(at: terminalDate))
            }
        }
    }

    @MainActor
    func testReturningToPublishedStateCancelsPendingSearch() async throws {
        for debounce in [true, false] {
            let sink = RecordingTimelineSink()
            let publisher = WidgetTimelinePublisher(sink: sink)
            let ready = LyricsTimelineSnapshot.idle("已載入測試歌詞", at: t0)
            publisher.publish(ready)
            publisher.publish(.idle("搜尋中", at: t0), debounce: true)
            publisher.publish(ready, debounce: debounce)
            try await Task.sleep(for: .milliseconds(850))
            XCTAssertEqual(sink.saved, [ready])
            XCTAssertEqual(sink.reloads, 1)
            // 取消後仍能正常發布下一筆，而不是被舊的 pendingTask 卡住。
            let next = LyricsTimelineSnapshot.idle("下一首", at: t0)
            publisher.publish(next, debounce: true)
            try await Task.sleep(for: .milliseconds(850))
            XCTAssertEqual(sink.saved.last, next)
        }
    }

    func testAllEndpointTypesShareRateLimitAndResumeAfterExpiry() async throws {
        let paths = ["currently-playing", "pause", "queue"]
        for limitingPath in paths {
            let clock = ReviewClock(t0)
            let server = ReviewServer()
            let transport = SpotifyHTTPTransport(now: { clock.now() }, sender: { request in
                await server.respond(request)
            })
            func request(_ path: String) -> URLRequest {
                URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/\(path)")!)
            }
            do {
                _ = try await transport.data(for: request(limitingPath))
                XCTFail("Expected 429")
            } catch let error as SpotifyRateLimitError {
                XCTAssertEqual(error.retryAfter, 60)
                XCTAssertTrue(error.quotaExceeded)
                XCTAssertEqual(UserFacingError(error), .quotaExceeded)
            }
            clock.advance(10)
            for blockedPath in paths {
                do {
                    _ = try await transport.data(for: request(blockedPath))
                    XCTFail("Cooldown must block \(blockedPath)")
                } catch let error as SpotifyRateLimitError {
                    XCTAssertEqual(error.retryAfter, 50)
                }
            }
            let blockedCount = await server.count
            XCTAssertEqual(blockedCount, 1)
            clock.advance(50)
            _ = try await transport.data(for: request("currently-playing"))
            let resumedCount = await server.count
            XCTAssertEqual(resumedCount, 2)
        }
        XCTAssertEqual(UserFacingError(SpotifyRateLimitError(retryAfter: 2.1, quotaExceeded: false)),
                       .rateLimited(seconds: 3))
    }
}

private final class RecordingTimelineSink: TimelineSink, @unchecked Sendable {
    // publisher 與測試均在 MainActor 呼叫；沒有跨執行緒存取。
    var saved: [LyricsTimelineSnapshot] = []
    var reloads = 0
    let renderCount = 0
    let lastRenderAt: Date? = nil
    func save(_ snapshot: LyricsTimelineSnapshot) -> Bool { saved.append(snapshot); return true }
    func reload() { reloads += 1 }
}

private final class ReviewClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}

private actor ReviewServer {
    private(set) var count = 0
    func respond(_ request: URLRequest) -> (Data, URLResponse) {
        count += 1
        return (Data("{\"reason\":\"QUOTA_EXCEEDED\"}".utf8),
                HTTPURLResponse(url: request.url!, statusCode: count == 1 ? 429 : 200,
                                httpVersion: nil, headerFields: ["Retry-After": "60"])!)
    }
}
