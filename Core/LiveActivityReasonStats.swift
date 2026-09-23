import Foundation

/// 即時動態更新送出時，App 是「為了什麼理由」在執行（純邏輯，可測試）。
///
/// iOS 擋掉的是「只有背景音訊」的程序在背景送出的更新；有背景任務或定位撐著時是不是就放行，
/// 只有分開統計才知道。`LiveActivityManager` 每次送出 / 驗證都記在對應的理由底下，
/// 診斷頁與狀態快照顯示 `summary`，實測紀錄一眼就能看出哪個理由被套用過。
enum LiveActivityBackgroundReason: String, Equatable, Sendable, CaseIterable {
    /// App 在前景（一定被套用；當對照組）
    case foreground
    /// 背景，只有無聲音訊撐著
    case audioOnly
    /// 背景，剛進背景申請的 `beginBackgroundTask` 還在
    case backgroundTask
    /// 背景，定位保活執行中（有沒有背景任務都算定位）
    case location

    var label: String {
        switch self {
        case .foreground: return "前景"
        case .audioOnly: return "音訊"
        case .backgroundTask: return "背景任務"
        case .location: return "定位"
        }
    }

    /// 送出當下的理由
    static func current(background: Bool, locationActive: Bool, backgroundTask: Bool) -> LiveActivityBackgroundReason {
        guard background else { return .foreground }
        if locationActive { return .location }
        return backgroundTask ? .backgroundTask : .audioOnly
    }
}

/// 各理由的「送出 / 套用 / 被擋」次數
struct LiveActivityReasonStats: Equatable, Sendable {
    struct Bucket: Equatable, Sendable {
        var sent = 0
        var accepted = 0
        var rejected = 0
    }

    private(set) var buckets: [LiveActivityBackgroundReason: Bucket] = [:]

    subscript(reason: LiveActivityBackgroundReason) -> Bucket {
        buckets[reason] ?? Bucket()
    }

    mutating func recordSent(_ reason: LiveActivityBackgroundReason) {
        buckets[reason, default: Bucket()].sent += 1
    }

    mutating func record(_ reason: LiveActivityBackgroundReason, accepted: Bool) {
        if accepted {
            buckets[reason, default: Bucket()].accepted += 1
        } else {
            buckets[reason, default: Bucket()].rejected += 1
        }
    }

    /// 診斷用：「前景 套用55 擋0 送55 · 音訊 套用0 擋26 送30」（只列有送過的；
    /// 送出 > 套用＋被擋 的差額是來不及驗證的）
    var summary: String {
        let parts = LiveActivityBackgroundReason.allCases.compactMap { reason -> String? in
            guard let b = buckets[reason], b.sent > 0 else { return nil }
            return "\(reason.label) 套用\(b.accepted) 擋\(b.rejected) 送\(b.sent)"
        }
        return parts.isEmpty ? "尚未送出" : parts.joined(separator: " · ")
    }

    /// 實驗結論的一句話：定位保活期間有沒有被套用（沒送過就 nil）
    var locationVerdict: String? {
        let b = self[.location]
        guard b.accepted + b.rejected > 0 else { return nil }
        if b.rejected == 0 { return "定位保活期間全部被套用（\(b.accepted) 次）" }
        if b.accepted == 0 { return "定位保活期間全部被擋（\(b.rejected) 次）" }
        return "定位保活期間部分被套用（套用 \(b.accepted)、被擋 \(b.rejected)）"
    }
}
