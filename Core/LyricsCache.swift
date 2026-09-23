import Foundation

/// 歌詞的本機快取與手動指定（以 Spotify 曲目 ID 為 key）。
/// - 快取放 Caches（系統可清除）；手動指定屬於使用者資料，放 Application Support
/// - 「找不到」只快取一天；失敗不快取
/// - 另外記下最近的查詢失敗（放在快取資料夾的 failures/，6 小時），只給預先載入參考
struct LyricsCache: Sendable {
    private struct Entry: Codable {
        let result: LyricsResult
        let savedAt: Date
    }

    let cacheDirectory: URL
    let overrideDirectory: URL
    static let notFoundTTL: TimeInterval = 86_400
    /// 查詢失敗後，預先載入多久內不再重試
    static let failureTTL: TimeInterval = 6 * 3600
    /// 超過這個大小的快取檔一定是歌詞內容（「找不到」/「純音樂」只有幾十個位元組）
    static let smallEntryBytes = 256

    /// 最近查詢失敗的紀錄；放在快取資料夾裡，清除快取時一起清掉
    var failureDirectory: URL { cacheDirectory.appendingPathComponent("failures", isDirectory: true) }

    init(cacheDirectory: URL, overrideDirectory: URL) {
        self.cacheDirectory = cacheDirectory
        self.overrideDirectory = overrideDirectory
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
    }

    static func standard() -> LyricsCache {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LyricsCache(cacheDirectory: caches.appendingPathComponent("lyrics-v2", isDirectory: true),
                           overrideDirectory: support.appendingPathComponent("lyrics-overrides", isDirectory: true))
    }

    // MARK: 快取

    func cached(_ trackID: String, now: Date = Date()) -> LyricsResult? {
        guard let entry = read(cacheDirectory, trackID) else { return nil }
        if entry.result == .notFound, now.timeIntervalSince(entry.savedAt) > Self.notFoundTTL { return nil }
        return entry.result
    }

    func save(_ result: LyricsResult, trackID: String, now: Date = Date()) {
        if case .failed = result { return }
        write(Entry(result: result, savedAt: now), cacheDirectory, trackID)
    }

    /// 便宜的存在檢查（預先載入用）：有手動指定、或有未過期的快取就回傳 true。
    /// 大檔一定是歌詞（不會過期），只看檔案大小、不解碼；小檔可能是「找不到」，才解碼檢查期限。
    func contains(_ trackID: String, now: Date = Date()) -> Bool {
        if FileManager.default.fileExists(atPath: url(overrideDirectory, trackID).path) { return true }
        guard let size = try? url(cacheDirectory, trackID).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size > Self.smallEntryBytes || cached(trackID, now: now) != nil
    }

    func clear() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: 最近的查詢失敗（只有預先載入參考；前景載入與手動重試不看）

    func recordFailure(_ trackID: String, now: Date = Date()) {
        try? FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        write(Entry(result: .failed(""), savedAt: now), failureDirectory, trackID)
    }

    func recentlyFailed(_ trackID: String, now: Date = Date()) -> Bool {
        guard let entry = read(failureDirectory, trackID) else { return false }
        return now.timeIntervalSince(entry.savedAt) <= Self.failureTTL
    }

    // MARK: 手動指定

    func override(_ trackID: String) -> LyricsResult? {
        read(overrideDirectory, trackID)?.result
    }

    func setOverride(_ result: LyricsResult, trackID: String) {
        write(Entry(result: result, savedAt: Date()), overrideDirectory, trackID)
    }

    func removeOverride(_ trackID: String) {
        try? FileManager.default.removeItem(at: url(overrideDirectory, trackID))
    }

    // MARK: 檔案

    private func url(_ dir: URL, _ trackID: String) -> URL {
        // 曲目 ID 只含英數；保險起見去掉路徑字元
        let safe = trackID.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).json")
    }

    private func read(_ dir: URL, _ trackID: String) -> Entry? {
        guard let data = try? Data(contentsOf: url(dir, trackID)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func write(_ entry: Entry, _ dir: URL, _ trackID: String) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url(dir, trackID), options: .atomic)
    }
}
