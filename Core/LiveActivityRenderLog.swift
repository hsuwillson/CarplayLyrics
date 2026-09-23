import Foundation

/// 即時動態畫面「實際被系統重畫」的時刻紀錄（純邏輯，可測試）。
///
/// App 送出的更新被系統套用，不代表 CarPlay 儀表板馬上重畫：build 45 實測 CarPlay 大約每分鐘才重畫一次，
/// 鎖定畫面則每句都會。小工具 extension 在畫面 body 裡記下時刻（每個 family 一份），App 在診斷頁算出
/// 「最近 N 次，平均 / 最長幾秒」，下一份實測紀錄就能確認節奏。
/// - 同一次重畫 SwiftUI 可能評估 body 好幾次：`minGap` 內的呼叫一律不記（也就不會寫檔）
/// - 只留最近 `maxSamples` 筆；超過 `maxGap` 的間隔不算節奏（中間根本沒有即時動態）
struct LiveActivityRenderLog: Equatable, Sendable {
    var maxSamples: Int
    var minGap: TimeInterval
    var maxGap: TimeInterval
    private(set) var times: [Date]

    init(times: [Date] = [], maxSamples: Int = 40, minGap: TimeInterval = 5, maxGap: TimeInterval = 600) {
        self.times = times
        self.maxSamples = max(2, maxSamples)
        self.minGap = minGap
        self.maxGap = maxGap
    }

    /// 畫面 body 呼叫；回傳 true 代表這次有記下來（呼叫端才需要寫入 App Group）
    @discardableResult
    mutating func record(now: Date) -> Bool {
        if let last = times.last {
            let gap = now.timeIntervalSince(last)
            // 時鐘倒退（gap < 0）當成新的一筆
            if gap >= 0, gap < minGap { return false }
        }
        times.append(now)
        if times.count > maxSamples { times.removeFirst(times.count - maxSamples) }
        return true
    }

    var lastRenderAt: Date? { times.last }

    /// 相鄰兩次重畫的間隔（只算 `maxGap` 內、而且時間往前走的）
    var gaps: [TimeInterval] {
        zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }.filter { $0 >= 0 && $0 <= maxGap }
    }

    struct Stats: Equatable, Sendable {
        var count: Int
        var average: TimeInterval
        var longest: TimeInterval
        var shortest: TimeInterval
    }

    /// 間隔統計；連一個間隔都沒有時 nil
    var stats: Stats? {
        let g = gaps
        guard let longest = g.max(), let shortest = g.min() else { return nil }
        return Stats(count: g.count, average: g.reduce(0, +) / Double(g.count), longest: longest, shortest: shortest)
    }

    /// 「最近 N 次，平均 X 秒／最長 Y 秒」；沒有資料時 nil
    var summary: String? {
        guard let s = stats else { return nil }
        return "最近 \(s.count) 次，平均 \(Self.seconds(s.average)) 秒／最長 \(Self.seconds(s.longest)) 秒"
    }

    private static func seconds(_ t: TimeInterval) -> String {
        t < 10 ? String(format: "%.1f", t) : "\(Int(t.rounded()))"
    }
}
