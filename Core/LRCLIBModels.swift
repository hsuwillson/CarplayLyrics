import Foundation

/// LRCLIB API 回傳的曲目資料（/api/get 與 /api/search 共用）
struct LRCLIBTrack: Decodable, Equatable, Sendable {
    let id: Int
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    var hasSynced: Bool {
        !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasPlain: Bool {
        !(plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum LRCLIBMatcher {
    /// 給「選擇歌詞」清單用：去除重複、只留有內容的，同步歌詞優先，再依長度差排序
    static func rank(_ results: [LRCLIBTrack], duration: TimeInterval) -> [LRCLIBTrack] {
        var seen = Set<Int>()
        let unique = results.filter { seen.insert($0.id).inserted }
        func diff(_ t: LRCLIBTrack) -> TimeInterval {
            guard let d = t.duration, duration > 0 else { return .infinity }
            return abs(d - duration)
        }
        return unique
            .filter { $0.hasSynced || $0.hasPlain || $0.instrumental == true }
            .sorted { a, b in
                if a.hasSynced != b.hasSynced { return a.hasSynced }
                return diff(a) < diff(b)
            }
    }

    /// 從搜尋結果挑最適合的一筆：長度差在 `tolerance` 秒內，優先有同步歌詞，其次長度最接近
    static func bestMatch(_ results: [LRCLIBTrack], duration: TimeInterval, tolerance: TimeInterval = 5) -> LRCLIBTrack? {
        func diff(_ t: LRCLIBTrack) -> TimeInterval {
            guard let d = t.duration else { return .infinity }
            return abs(d - duration)
        }
        let candidates = results.filter { diff($0) <= tolerance }
        return candidates.filter(\.hasSynced).min { diff($0) < diff($1) }
            ?? candidates.filter(\.hasPlain).min { diff($0) < diff($1) }
    }
}
