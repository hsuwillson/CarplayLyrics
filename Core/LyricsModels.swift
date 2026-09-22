import Foundation

struct TrackQuery: Equatable, Sendable {
    let trackID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
}

/// 歌詞查詢結果（會寫入快取，所以保持 Codable 且格式不變）
enum LyricsResult: Codable, Equatable, Sendable {
    case synced(String)
    case plain(String)
    case instrumental
    case notFound
    case failed(String)

    var shortDescription: String {
        switch self {
        case .synced: return "同步歌詞"
        case .plain: return "未同步歌詞"
        case .instrumental: return "純音樂"
        case .notFound: return "找不到"
        case .failed: return "失敗"
        }
    }

    /// LRCLIB 的一筆結果 → 歌詞結果；沒有內容時回傳 nil
    init?(track t: LRCLIBTrack) {
        if t.hasSynced, let s = t.syncedLyrics { self = .synced(s) }
        else if t.instrumental == true { self = .instrumental }
        else if t.hasPlain, let p = t.plainLyrics { self = .plain(p) }
        else { return nil }
    }
}

/// 畫面上的歌詞狀態。取代以前用字串比對的 `lyricsStatus`。
enum LyricsState: Equatable, Sendable {
    case idle
    case searching
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
    case failed(UserFacingError)

    init(_ result: LyricsResult) {
        switch result {
        case .synced(let lrc):
            let lines = LRCParser.parse(lrc)
            self = lines.isEmpty ? .plain(lrc) : .synced(lines)
        case .plain(let text): self = .plain(text)
        case .instrumental: self = .instrumental
        case .notFound: self = .notFound
        case .failed(let message): self = .failed(.lyricsUnavailable(message))
        }
    }

    var lines: [LyricLine] {
        if case .synced(let l) = self { return l }
        return []
    }

    var plainText: String? {
        if case .plain(let t) = self { return t }
        return nil
    }

    var isSearching: Bool { self == .searching }

    /// 簡短狀態文字（狀態列、診斷頁）
    var label: String {
        switch self {
        case .idle: return "沒有播放中的歌曲"
        case .searching: return "搜尋歌詞中…"
        case .synced(let l): return "同步歌詞（\(l.count) 行）"
        case .plain: return "只有未同步歌詞"
        case .instrumental: return "純音樂"
        case .notFound: return "找不到歌詞"
        case .failed: return "歌詞載入失敗"
        }
    }
}
