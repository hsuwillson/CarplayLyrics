import Foundation

/// 背景被擋期間的探測節奏（純邏輯，可測試）。
///
/// 實測（build 36）App 在背景送出的即時動態更新會被系統丟掉；Apple 工程師在論壇說背景「只有推播是支援的做法」，
/// 而且系統本來就會節流太密的更新。到底是「一律禁止」還是「太密才被擋」，只有量了才知道：
/// - 被擋期間的探測從 15 秒開始，連續幾次沒被套用就放慢（30 → 60 → 120 秒），省下白送的更新；
/// - 某個間隔連續幾次被套用就加快一級，最快的一級（5 秒）也穩定被套用時才恢復逐句更新；
/// - 每一級各自記「送出 / 套用 / 被擋」與套用的延遲，診斷頁與紀錄檔看得到，下一次的實測紀錄就能下結論。
/// 每次送出的內容都帶著接下來幾句的視窗（`LiveActivityWindowPolicy`），所以就算只有疏疏的更新被套用，
/// 畫面也顯示對的那一段歌詞。
struct LiveActivityCadencePolicy: Equatable, Sendable {
    /// 可用的探測間隔（秒），由快到慢
    let levels: [TimeInterval]
    /// 每次進入「被擋」從哪一級開始
    var startLevel: Int
    /// 同一級連續被擋幾次就放慢一級
    var escalateAfter = 3
    /// 同一級連續被套用幾次就加快一級（最快一級再被套用就恢復逐句）
    var relaxAfter = 2

    /// 一個間隔的統計
    struct Bucket: Equatable, Sendable {
        var sent = 0
        var accepted = 0
        var rejected = 0
        /// 被套用的更新裡，驗證到「已套用」最久等了幾秒
        var maxLatency: TimeInterval = 0

        mutating func record(accepted ok: Bool, latency: TimeInterval) {
            if ok {
                accepted += 1
                maxLatency = max(maxLatency, latency)
            } else {
                rejected += 1
            }
        }
    }

    /// 記錄一次結果後節奏怎麼變
    enum Change: Equatable, Sendable {
        case none
        case slower(TimeInterval)
        case faster(TimeInterval)
        /// 最快一級也穩定被套用：恢復逐句更新
        case resumePerLine
    }

    private(set) var level: Int
    /// 各級的統計（與 `levels` 對應）
    private(set) var buckets: [Bucket]
    /// 背景、還沒判定被擋時的逐句更新（進入被擋前那 8 次也算在這裡）
    private(set) var perLine = Bucket()
    private(set) var rejectStreak = 0
    private(set) var acceptStreak = 0

    init(levels: [TimeInterval] = [5, 15, 30, 60, 120], startLevel: Int = 1) {
        self.levels = levels.isEmpty ? [15] : levels
        self.startLevel = startLevel
        level = min(max(startLevel, 0), self.levels.count - 1)
        buckets = Array(repeating: Bucket(), count: self.levels.count)
    }

    /// 目前的探測間隔（秒）
    var interval: TimeInterval { levels[level] }

    /// 進入「背景被擋」：從起始級重新開始（統計保留、累計）
    mutating func enterBlocked() {
        level = min(max(startLevel, 0), levels.count - 1)
        rejectStreak = 0
        acceptStreak = 0
    }

    mutating func recordProbeSent() {
        buckets[level].sent += 1
    }

    mutating func recordPerLineSent() {
        perLine.sent += 1
    }

    mutating func recordPerLine(accepted: Bool, latency: TimeInterval) {
        perLine.record(accepted: accepted, latency: latency)
    }

    /// 一次探測的驗證結果 → 節奏變化
    mutating func record(accepted: Bool, latency: TimeInterval) -> Change {
        buckets[level].record(accepted: accepted, latency: latency)
        if accepted {
            acceptStreak += 1
            rejectStreak = 0
            guard acceptStreak >= relaxAfter else { return .none }
            acceptStreak = 0
            if level == 0 { return .resumePerLine }
            level -= 1
            return .faster(interval)
        }
        rejectStreak += 1
        acceptStreak = 0
        guard rejectStreak >= escalateAfter, level + 1 < levels.count else { return .none }
        rejectStreak = 0
        level += 1
        return .slower(interval)
    }

    /// 診斷用：「逐句 0/8 · 15秒 0/6（延遲 0.8s）」— 每一級「套用/送出」，只列有送過的
    var summary: String {
        var parts: [String] = []
        if perLine.sent > 0 { parts.append("逐句 \(perLine.accepted)/\(perLine.sent)\(Self.latencyText(perLine))") }
        for (i, b) in buckets.enumerated() where b.sent > 0 {
            parts.append("\(Int(levels[i]))秒 \(b.accepted)/\(b.sent)\(Self.latencyText(b))")
        }
        return parts.isEmpty ? "尚無背景送出" : parts.joined(separator: " · ")
    }

    private static func latencyText(_ b: Bucket) -> String {
        b.accepted > 0 ? String(format: "（延遲 %.1fs）", b.maxLatency) : ""
    }
}
