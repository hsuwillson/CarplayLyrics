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
}

/// 以 Spotify 的進度 + 本地時鐘推算目前位置，並偵測換歌、暫停、拖動進度
struct LyricsSyncEngine: Sendable {
    /// 推算值與實際進度差超過這個秒數，視為拖動進度
    var seekThreshold: TimeInterval = 2
    private(set) var snapshot: PlaybackSnapshot?

    @discardableResult
    mutating func update(_ new: PlaybackSnapshot) -> PlaybackChange {
        let old = snapshot
        snapshot = new
        guard let old else { return .newTrack }
        if old.trackID != new.trackID { return .newTrack }
        if old.isPlaying != new.isPlaying { return .playStateChanged }
        let expected = old.position(at: new.timestamp)
        return abs(expected - new.progress) > seekThreshold ? .seeked : .none
    }

    mutating func reset() {
        snapshot = nil
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
