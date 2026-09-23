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
        /// 背景被擋：只記住最新內容，回前景（或下一次探測）再送
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
        /// 距離上一次真的送出去多久（背景被擋期間用來決定要不要探測）
        var secondsSinceLastSend: TimeInterval

        init(isActive: Bool, startBlockedUntilForeground: Bool = false, backgroundBlocked: Bool = false,
             isInBackground: Bool = false, priority: Priority = .routine, sameAsLast: Bool = false,
             secondsSinceLastSend: TimeInterval = 0) {
            self.isActive = isActive
            self.startBlockedUntilForeground = startBlockedUntilForeground
            self.backgroundBlocked = backgroundBlocked
            self.isInBackground = isInBackground
            self.priority = priority
            self.sameAsLast = sameAsLast
            self.secondsSinceLastSend = secondsSinceLastSend
        }
    }

    /// 連續幾次背景更新沒被套用就判定「被系統擋住」。
    /// 比對本身有時間差（見 LiveActivityManager.scheduleVerify），寧可慢一點判定，
    /// 也不要誤判把逐句更新關掉。
    var backgroundRejectLimit = 8

    /// 「背景被擋」不是單行道：系統可能只是慢（套用超過 2 秒），不是拒絕。
    /// 被擋期間每隔這麼久還是放一次換句更新出去當探測；一被套用就解除封鎖，歌詞繼續動。
    /// 探測失敗的代價是一次白送的更新，誤判的代價是整趟車歌詞都不動。
    var blockedProbeInterval: TimeInterval = 15

    func decide(_ input: Input) -> Decision {
        guard input.isActive else {
            return input.startBlockedUntilForeground ? .skip : .start
        }
        if input.sameAsLast { return .skip }
        if input.backgroundBlocked && input.priority == .routine && input.isInBackground {
            return shouldProbe(secondsSinceLastSend: input.secondsSinceLastSend) ? .send : .store
        }
        return .send
    }

    /// 背景被擋期間，距離上次送出夠久了就探測一次
    func shouldProbe(secondsSinceLastSend: TimeInterval) -> Bool {
        secondsSinceLastSend >= blockedProbeInterval
    }

    /// 更新被擋的次數 → 要不要進入「背景被擋」模式
    func shouldEnterBlocked(backgroundRejectStreak: Int) -> Bool {
        backgroundRejectStreak >= backgroundRejectLimit
    }
}
