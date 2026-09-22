import Foundation

struct TrackQuery {
    let trackID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
}

enum LyricsResult: Codable, Equatable {
    case synced(String)
    case plain(String)
    case instrumental
    case notFound
    case failed(String)
}

/// 從 LRCLIB 取得歌詞，並以 Spotify 曲目 ID 為 key 快取在本機
@MainActor
final class LyricsService {
    private struct CacheEntry: Codable {
        let result: LyricsResult
        let savedAt: Date
    }

    private let cacheDirectory: URL
    private let userAgent = "CarLyrics/0.1 (personal use; https://github.com/hsuwillson/CarplayLyrics)"

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = base.appendingPathComponent("lyrics-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func lyrics(for query: TrackQuery) async -> LyricsResult {
        if let cached = loadCache(query.trackID) {
            debugLog("歌詞來自快取")
            return cached
        }
        do {
            let result = try await fetch(query)
            saveCache(result, trackID: query.trackID)
            return result
        } catch {
            // 網路錯誤不快取，下次換歌回來會重試
            return .failed(error.localizedDescription)
        }
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
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
        if status == 200, let t = try? JSONDecoder().decode(LRCLIBTrack.self, from: data), let r = result(from: t) {
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
                var search = URLComponents(string: "https://lrclib.net/api/search")!
                search.queryItems = items
                let (sdata, sstatus) = try await request(search.url!)
                guard sstatus == 200 else { continue }
                let list = (try? JSONDecoder().decode([LRCLIBTrack].self, from: sdata)) ?? []
                let label = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
                debugLog("LRCLIB search \(label)：\(list.count) 筆")
                if let best = LRCLIBMatcher.bestMatch(list, duration: q.duration), let r = result(from: best) {
                    debugLog("採用 LRCLIB #\(best.id)：\(best.trackName ?? "") – \(best.artistName ?? "")")
                    return r
                }
            }
        }
        return .notFound
    }

    private func result(from t: LRCLIBTrack) -> LyricsResult? {
        if t.hasSynced, let s = t.syncedLyrics { return .synced(s) }
        if t.instrumental == true { return .instrumental }
        if t.hasPlain, let p = t.plainLyrics { return .plain(p) }
        return nil
    }

    private func request(_ url: URL) async throws -> (Data, Int) {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: r)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: 快取

    private func cacheURL(_ trackID: String) -> URL {
        cacheDirectory.appendingPathComponent("\(trackID).json")
    }

    private func loadCache(_ trackID: String) -> LyricsResult? {
        guard let data = try? Data(contentsOf: cacheURL(trackID)),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else { return nil }
        // 「找不到」只快取一天，之後重新查詢（LRCLIB 可能新增了）
        if entry.result == .notFound, Date().timeIntervalSince(entry.savedAt) > 86_400 { return nil }
        return entry.result
    }

    private func saveCache(_ result: LyricsResult, trackID: String) {
        if case .failed = result { return }
        let entry = CacheEntry(result: result, savedAt: Date())
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: cacheURL(trackID), options: .atomic)
        }
    }
}
