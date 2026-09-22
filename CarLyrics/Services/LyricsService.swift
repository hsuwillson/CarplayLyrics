import Foundation

/// 歌詞來源（方便以假物件測試 / 替換）
protocol LyricsProviding: Sendable {
    func lyrics(for query: TrackQuery) async -> LyricsResult?
    func candidates(for query: TrackQuery) async -> [LRCLIBTrack]
    func search(text: String, duration: TimeInterval) async -> [LRCLIBTrack]
    func hasOverride(_ trackID: String) async -> Bool
    func setOverride(_ result: LyricsResult, trackID: String) async
    func removeOverride(_ trackID: String) async
    func clearCache() async
}

/// 從 LRCLIB 取得歌詞，並以 Spotify 曲目 ID 為 key 快取在本機。
/// 是 actor：搜尋最多十幾個請求、JSON 解碼與檔案讀寫都不在主執行緒。
actor LyricsService: LyricsProviding {
    private let cache: LyricsCache
    private let userAgent = "CarLyrics/0.2 (personal use; https://github.com/hsuwillson/CarplayLyrics)"

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
            debugLog("歌詞來自快取")
            return cached
        }
        do {
            let result = try await fetch(query)
            guard !Task.isCancelled else { return nil }
            cache.save(result, trackID: query.trackID)
            return result
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            // 網路錯誤不快取，下次換歌回來會重試
            debugLog("歌詞查詢失敗：\(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    func hasOverride(_ trackID: String) -> Bool { cache.override(trackID) != nil }
    func setOverride(_ result: LyricsResult, trackID: String) { cache.setOverride(result, trackID: trackID) }
    func removeOverride(_ trackID: String) { cache.removeOverride(trackID) }
    func clearCache() { cache.clear() }

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
        if status == 200, let t = try? JSONDecoder().decode(LRCLIBTrack.self, from: data), let r = LyricsResult(track: t) {
            debugLog("LRCLIB /get 命中")
            return r
        }

        // 放寬搜尋：多種歌名寫法 × (指定歌手 / 全文搜尋)，用歌曲長度過濾，找到就停
        for title in TitleVariants.make(q.title) {
            let searches: [[URLQueryItem]] = [
                [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: q.artist)],
                [URLQueryItem(name: "q", value: "\(title) \(q.artist)")],
                [URLQueryItem(name: "track_name", value: title)],
            ]
            for items in searches {
                try Task.checkCancellation()
                var search = URLComponents(string: "https://lrclib.net/api/search")!
                search.queryItems = items
                let (sdata, sstatus) = try await request(search.url!)
                guard sstatus == 200 else { continue }
                let list = (try? JSONDecoder().decode([LRCLIBTrack].self, from: sdata)) ?? []
                let label = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
                debugLog("LRCLIB search \(label)：\(list.count) 筆")
                if let best = LRCLIBMatcher.bestMatch(list, duration: q.duration), let r = LyricsResult(track: best) {
                    debugLog("採用 LRCLIB #\(best.id)：\(best.trackName ?? "") – \(best.artistName ?? "")")
                    return r
                }
            }
        }
        return .notFound
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
