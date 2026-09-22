import Foundation

/// 某個時間點的播放狀態（來自 Spotify 輪詢）
struct PlaybackSnapshot: Equatable, Sendable {
    let trackID: String
    /// `timestamp` 當下的播放進度（秒）
    let progress: TimeInterval
    /// 歌曲長度（秒）
    let duration: TimeInterval
    let isPlaying: Bool
    /// 本地時間，代表 `progress` 成立的時刻
    let timestamp: Date

    /// 用本地時鐘推算 `date` 時的播放進度
    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return progress }
        let p = progress + date.timeIntervalSince(timestamp)
        return duration > 0 ? min(duration, p) : p
    }
}

enum PlaybackChange: Equatable, Sendable {
    case none
    case newTrack
    case seeked
    case playStateChanged
    /// Spotify 回傳的進度沒有前進（快取的舊資料），已忽略，繼續用本地時鐘推算
    case stale
}

/// 以 Spotify 的進度 + 本地時鐘推算目前位置，並偵測換歌、暫停、拖動進度
struct LyricsSyncEngine: Sendable {
    /// 推算值與實際進度差超過這個秒數，視為拖動進度
    var seekThreshold: TimeInterval = 2
    /// 連續幾次「進度沒前進」內都當成過期資料忽略；超過就相信 Spotify（可能真的卡住緩衝）
    var maxStaleUpdates = 4
    private(set) var snapshot: PlaybackSnapshot?
    private(set) var staleCount = 0

    @discardableResult
    mutating func update(_ new: PlaybackSnapshot) -> PlaybackChange {
        guard let old = snapshot else {
            accept(new)
            return .newTrack
        }
        if old.trackID != new.trackID {
            accept(new)
            return .newTrack
        }
        if old.isPlaying != new.isPlaying {
            accept(new)
            return .playStateChanged
        }

        // Spotify 偶爾會連續回傳同一個 progress_ms（過期資料）。
        // 如果照單全收，每次輪詢都會把位置拉回原點，歌詞就卡在同一句。
        let elapsed = new.timestamp.timeIntervalSince(old.timestamp)
        if new.isPlaying, elapsed > 1, abs(new.progress - old.progress) < 0.05, staleCount < maxStaleUpdates {
            staleCount += 1
            return .stale
        }

        let expected = old.position(at: new.timestamp)
        accept(new)
        return abs(expected - new.progress) > seekThreshold ? .seeked : .none
    }

    private mutating func accept(_ new: PlaybackSnapshot) {
        snapshot = new
        staleCount = 0
    }

    mutating func reset() {
        snapshot = nil
        staleCount = 0
    }

    /// `offset` 為正值時歌詞提前出現
    func position(at date: Date, offset: TimeInterval = 0) -> TimeInterval? {
        snapshot.map { $0.position(at: date) + offset }
    }
}

/// 畫面上要顯示的目前句與下一句
struct LyricsDisplay: Equatable, Sendable {
    var index: Int?
    var current: String
    var next: String

    static let empty = LyricsDisplay(index: nil, current: "", next: "")

    init(index: Int?, current: String, next: String) {
        self.index = index
        self.current = current
        self.next = next
    }

    init(lines: [LyricLine], position: TimeInterval) {
        let i = lines.index(at: position)
        index = i
        if let i {
            current = lines[i].text
            next = i + 1 < lines.count ? lines[i + 1].text : ""
        } else {
            current = ""
            next = lines.first?.text ?? ""
        }
    }
}

extension Array where Element == LyricLine {
    /// `time` 之後下一次換句的時間；沒有下一句時回傳 nil
    func nextChangeTime(after time: TimeInterval) -> TimeInterval? {
        let next = (index(at: time) ?? -1) + 1
        return next < count ? self[next].time : nil
    }
}
