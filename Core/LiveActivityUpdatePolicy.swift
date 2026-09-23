import Foundation

/// 即時動態「要不要送這次更新」的決策（純邏輯，可測試）。
/// ActivityKit 的呼叫留在 `LiveActivityManager`。
struct LiveActivityUpdatePolicy: Equatable, Sendable {
    /// 這次更新的重要程度
    enum Priority: Equatable, Sendable {
        /// 換句：背景被系統擋住時略過
        case routine
        /// 換歌、暫停、播放：被擋住時仍然嘗試（也用來偵測系統行為是否改變）
        case important
    }

    enum Decision: Equatable, Sendable {
        /// 還沒有即時動態 → 開一個新的
        case start
        case send
        /// 背景被擋：只記住最新內容，回前景再送
        case store
        case skip
    }

    struct Input: Sendable {
        var isActive: Bool
        var startBlockedUntilForeground: Bool
        var backgroundBlocked: Bool
        var isInBackground: Bool
        var priority: Priority
        /// 與目前已送出的內容相同
        var sameAsLast: Bool

        init(isActive: Bool, startBlockedUntilForeground: Bool = false, backgroundBlocked: Bool = false,
             isInBackground: Bool = false, priority: Priority = .routine, sameAsLast: Bool = false) {
            self.isActive = isActive
            self.startBlockedUntilForeground = startBlockedUntilForeground
            self.backgroundBlocked = backgroundBlocked
            self.isInBackground = isInBackground
            self.priority = priority
            self.sameAsLast = sameAsLast
        }
    }

    /// 連續幾次背景更新沒被套用就判定「被系統擋住」
    var backgroundRejectLimit = 5

    func decide(_ input: Input) -> Decision {
        guard input.isActive else {
            return input.startBlockedUntilForeground ? .skip : .start
        }
        if input.sameAsLast { return .skip }
        if input.backgroundBlocked && input.priority == .routine && input.isInBackground { return .store }
        return .send
    }

    /// 更新被擋的次數 → 要不要進入「背景被擋」模式
    func shouldEnterBlocked(backgroundRejectStreak: Int) -> Bool {
        backgroundRejectStreak >= backgroundRejectLimit
    }
}
