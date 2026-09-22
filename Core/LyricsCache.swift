import Foundation

/// 歌詞的本機快取與手動指定（以 Spotify 曲目 ID 為 key）。
/// - 快取放 Caches（系統可清除）；手動指定屬於使用者資料，放 Application Support
/// - 「找不到」只快取一天；失敗不快取
struct LyricsCache: Sendable {
    private struct Entry: Codable {
        let result: LyricsResult
        let savedAt: Date
    }

    let cacheDirectory: URL
    let overrideDirectory: URL
    static let notFoundTTL: TimeInterval = 86_400

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

    func clear() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
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
