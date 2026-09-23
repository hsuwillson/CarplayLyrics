import Foundation

/// 歌詞來源（方便以假物件測試 / 替換）
protocol LyricsProviding: Sendable {
    func lyrics(for query: TrackQuery) async -> LyricsResult?
    /// 預先載入前的便宜檢查：不連網、不解碼歌詞
    func prefetchCheck(_ trackID: String) async -> PrefetchCheck
    func candidates(for query: TrackQuery) async -> [LRCLIBTrack]
    func search(text: String, duration: TimeInterval) async -> [LRCLIBTrack]
    func hasOverride(_ trackID: String) async -> Bool
    func setOverride(_ result: LyricsResult, trackID: String) async
    func removeOverride(_ trackID: String) async
    func clearCache() async
}

/// 預先載入前的檢查結果
enum PrefetchCheck: Sendable {
    /// 已有快取或手動指定，不必再查
    case cached
    /// 最近查詢失敗過（逾時、LRCLIB 忙碌），先不重試
    case recentlyFailed
    /// 需要連網查詢
    case needed
}

/// LRCLIB 忙碌或故障（HTTP 429 / 5xx）：當成失敗而不是「找不到」，不會被快取一天，也不再繼續打
struct LRCLIBUnavailableError: LocalizedError {
    let status: Int
    var errorDescription: String? { "LRCLIB 暫時無法使用（HTTP \(status)）" }
}

/// 從 LRCLIB 取得歌詞，並以 Spotify 曲目 ID 為 key 快取在本機。
/// 是 actor：每首歌最多 6 個請求，JSON 解碼與檔案讀寫都不在主執行緒。
actor LyricsService: LyricsProviding {
    private let cache: LyricsCache
    private let userAgent = "CarLyrics/0.2 (personal use; https://github.com/hsuwillson/CarplayLyrics)"
    /// 每首歌最多幾個 LRCLIB 請求（含 /get）
    static let maxRequestsPerSong = 6
    /// 最多試幾種歌名寫法
    static let maxTitleVariants = 4

    /// 進行中的查詢：同一首歌同時被預先載入與前景載入時，共用同一組請求
    private struct Flight {
        let task: Task<LyricsResult, Error>
        var waiters: Set<Int>
    }
    private var inFlight: [String: Flight] = [:]
    private var nextWaiter = 0

    init(cache: LyricsCache = .standard()) {
        self.cache = cache
    }

    /// 回傳 nil 代表查詢途中被取消（換歌 / 使用者手動選擇），呼叫端應忽略
    func lyrics(for query: TrackQuery) async -> LyricsResult? {
        if let manual = cache.override(query.trackID) {
            debugLog("使用手動指定的歌詞")
            return manual
        }
        if let cached = cache.cached(query.trackID) {
            debugLog("歌詞來自快取：\(query.title)")
            return cached
        }
        do {
            let result = try await sharedFetch(query)
            guard !Task.isCancelled else { return nil }
            return result
        } catch {
            if Task.isCancelled || Self.isCancellation(error) { return nil }
            // 網路錯誤不快取（已在 fetchAndStore 記錄），下次換歌回來會重試
            return .failed(error.localizedDescription)
        }
    }

    /// 預先載入前的檢查：只看檔案是否存在 / 大小，不解碼歌詞
    func prefetchCheck(_ trackID: String) -> PrefetchCheck {
        if cache.contains(trackID) { return .cached }
        if cache.recentlyFailed(trackID) { return .recentlyFailed }
        return .needed
    }

    func hasOverride(_ trackID: String) -> Bool { cache.override(trackID) != nil }
    func setOverride(_ result: LyricsResult, trackID: String) { cache.setOverride(result, trackID: trackID) }
    func removeOverride(_ trackID: String) { cache.removeOverride(trackID) }
    func clearCache() { cache.clear() }

    // MARK: 同一首歌只查一次

    /// 同一首歌已經在查（例如預先載入中剛好切到這首）就等同一個結果，不重複連網。
    /// 等待者全部離開（取消）時才取消網路查詢。
    private func sharedFetch(_ q: TrackQuery) async throws -> LyricsResult {
        let id = q.trackID
        let waiter = nextWaiter
        nextWaiter += 1
        let task: Task<LyricsResult, Error>
        if var flight = inFlight[id] {
            flight.waiters.insert(waiter)
            inFlight[id] = flight
            task = flight.task
        } else {
            task = Task { try await self.fetchAndStore(q) }
            inFlight[id] = Flight(task: task, waiters: [waiter])
        }
        defer { leave(id, waiter: waiter) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.leave(id, waiter: waiter) }
        }
    }

    /// 等待者離開；沒有人在等了就取消查詢並移除
    private func leave(_ id: String, waiter: Int) {
        guard var flight = inFlight[id], flight.waiters.remove(waiter) != nil else { return }
        if flight.waiters.isEmpty {
            flight.task.cancel()
            inFlight[id] = nil
        } else {
            inFlight[id] = flight
        }
    }

    /// 連網查詢並寫入快取；失敗（不是取消）時記下來，預先載入一段時間內不再重試
    private func fetchAndStore(_ q: TrackQuery) async throws -> LyricsResult {
        do {
            let result = try await fetch(q)
            cache.save(result, trackID: q.trackID)
            return result
        } catch {
            if !Task.isCancelled, !Self.isCancellation(error) {
                cache.recordFailure(q.trackID)
                debugLog("歌詞查詢失敗：\(q.title)（\(error.localizedDescription)）")
            }
            throw error
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let e = error as? URLError, e.code == .cancelled { return true }
        return false
    }

    // MARK: 網路

    private func fetch(_ q: TrackQuery) async throws -> LyricsResult {
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [
            URLQueryItem(name: "track_name", value: q.title),
            URLQueryItem(name: "artist_name", value: q.artist),
            URLQueryItem(name: "album_name", value: q.album),
            URLQueryItem(name: "duration", value: String(Int(q.duration.rounded()))),
        ]
        let (data, status) = try await request(get.url!)
        try Self.checkAvailable(status)
        if status == 200, let t = try? JSONDecoder().decode(LRCLIBTrack.self, from: data), let r = LyricsResult(track: t) {
            debugLog("LRCLIB /get 命中")
            return r
        }

        // 放寬搜尋（連同 /get 最多 6 個請求），用歌曲長度過濾，找到就停。
        // 同一筆（LRCLIB id）在前面的搜尋已經比對過、不符合，後面再出現就不必再比
        var seen = Set<Int>()
        for items in Self.searchPlan(q).prefix(Self.maxRequestsPerSong - 1) {
            try Task.checkCancellation()
            var search = URLComponents(string: "https://lrclib.net/api/search")!
            search.queryItems = items
            let (sdata, sstatus) = try await request(search.url!)
            try Self.checkAvailable(sstatus)
            guard sstatus == 200 else { continue }
            let list = (try? JSONDecoder().decode([LRCLIBTrack].self, from: sdata)) ?? []
            let fresh = list.filter { seen.insert($0.id).inserted }
            let label = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
            debugLog("LRCLIB search \(label)：\(list.count) 筆（新 \(fresh.count) 筆）")
            if let best = LRCLIBMatcher.bestMatch(fresh, duration: q.duration), let r = LyricsResult(track: best) {
                debugLog("採用 LRCLIB #\(best.id)：\(best.trackName ?? "") – \(best.artistName ?? "")")
                return r
            }
        }
        return .notFound
    }

    /// 放寬搜尋的順序：前幾種歌名寫法 × 指定歌手 → 一次全文搜尋（去裝飾的歌名 + 歌手）
    /// → 原歌名不指定歌手（結果很大，太短的歌名不查；超過請求上限就不會查到）
    static func searchPlan(_ q: TrackQuery) -> [[URLQueryItem]] {
        var plan: [[URLQueryItem]] = TitleVariants.make(q.title).prefix(maxTitleVariants).map { title in
            [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: q.artist)]
        }
        let stripped = TitleVariants.stripDecorations(TitleVariants.normalizeWidth(q.title))
        plan.append([URLQueryItem(name: "q", value: "\(stripped.isEmpty ? q.title : stripped) \(q.artist)")])
        if q.title.count >= 4 {
            plan.append([URLQueryItem(name: "track_name", value: q.title)])
        }
        return plan
    }

    /// 429 / 5xx：LRCLIB 忙碌或故障，停止並回報失敗（不要當成「找不到」）
    private static func checkAvailable(_ status: Int) throws {
        if status == 429 || (500...599).contains(status) {
            throw LRCLIBUnavailableError(status: status)
        }
    }

    // MARK: 手動選擇

    /// 「選擇歌詞」清單：多種搜尋方式合併後排序
    func candidates(for q: TrackQuery) async -> [LRCLIBTrack] {
        var all: [LRCLIBTrack] = []
        for title in TitleVariants.make(q.title).prefix(3) {
            all += await search(items: [URLQueryItem(name: "track_name", value: title),
                                        URLQueryItem(name: "artist_name", value: q.artist)])
            all += await search(items: [URLQueryItem(name: "q", value: "\(title) \(q.artist)")])
        }
        return LRCLIBMatcher.rank(all, duration: q.duration)
    }

    /// 自由文字搜尋
    func search(text: String, duration: TimeInterval) async -> [LRCLIBTrack] {
        LRCLIBMatcher.rank(await search(items: [URLQueryItem(name: "q", value: text)]), duration: duration)
    }

    private func search(items: [URLQueryItem]) async -> [LRCLIBTrack] {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = items
        guard let url = c.url, let res = try? await request(url), res.1 == 200 else { return [] }
        return (try? JSONDecoder().decode([LRCLIBTrack].self, from: res.0)) ?? []
    }

    private func request(_ url: URL) async throws -> (Data, Int) {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: r)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
