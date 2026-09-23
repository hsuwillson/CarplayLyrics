import Foundation

// 從 AppModel 抽出的決策邏輯：純結構、不碰 UIKit / 網路，全部可以單元測試。

// MARK: - 輪詢間隔

/// 一次輪詢的結果摘要（決定下一次要等多久）
enum PollOutcome: Equatable, Sendable {
    /// 正在播放音樂；`remaining` = 距離歌曲結束的秒數（未知時 nil）
    case playing(isPlaying: Bool, remaining: TimeInterval?)
    case nonMusic
    /// 連續第 `streak` 次沒在播放
    case nothing(streak: Int)
    case rateLimited(retryAfter: TimeInterval, quotaExceeded: Bool)
    case error(streak: Int)
    case loggedOut
    /// 閒置太久已停止背景執行
    case idleStopped
}

struct PollPolicy: Equatable, Sendable {
    /// 低耗電模式或過熱：放慢輪詢
    var constrained = false

    var playingInterval: TimeInterval { constrained ? 5 : 2.5 }
    var pausedInterval: TimeInterval { constrained ? 10 : 5 }

    func delay(for outcome: PollOutcome, quotaActive: Bool = false, preferFullPlayer: Bool = false) -> TimeInterval {
        switch outcome {
        case .idleStopped:
            return 30
        case .loggedOut:
            return 10
        case .playing(let isPlaying, let remaining):
            if quotaActive { return 6 }
            if preferFullPlayer { return 1 }          // 過期資料 → 盡快用另一個端點確認
            guard isPlaying else { return pausedInterval }
            // 接近歌曲結尾：在預計換歌後馬上查一次
            if let remaining, remaining > 0, remaining < playingInterval {
                return max(0.5, remaining + 0.4)
            }
            return playingInterval
        case .nonMusic:
            return quotaActive ? 10 : 5
        case .nothing(let streak):
            // 偶發的 204（切歌、切換裝置）先快速重試
            return streak < 2 ? 3 : 10
        case .rateLimited(let retryAfter, let quotaExceeded):
            return quotaExceeded ? max(retryAfter, 30) : max(retryAfter, 1)
        case .error(let streak):
            return PollBackoff.delay(forErrorStreak: streak)
        }
    }
}

// MARK: - 閒置省電

struct IdlePolicy: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case paused
        case nothing
        /// 廣告 / Podcast 播放中
        case nonMusic
    }

    /// 沒有播放中的歌曲：10 分鐘
    var nothingLimit: TimeInterval = 600
    /// 暫停中（例如開車講電話，講完 Spotify 會自動續播）：30 分鐘
    var pausedLimit: TimeInterval = 1800
    /// 廣告 / Podcast 播放中：60 分鐘（人還在聽，只是沒有歌詞）
    var nonMusicLimit: TimeInterval = 3600
    /// 連著車用音訊（CarPlay / 車用藍牙）時放寬幾倍：人還在車上
    var carMultiplier: Double = 3

    func limit(for kind: Kind, carConnected: Bool = false) -> TimeInterval {
        let base: TimeInterval
        switch kind {
        case .paused: base = pausedLimit
        case .nothing: base = nothingLimit
        case .nonMusic: base = nonMusicLimit
        }
        return carConnected ? base * carMultiplier : base
    }

    /// 前景時永遠不停（Live Activity 之後進背景就無法再開始）
    func shouldStop(kind: Kind, since: Date, now: Date, isForeground: Bool, carConnected: Bool = false) -> Bool {
        !isForeground && now.timeIntervalSince(since) > limit(for: kind, carConnected: carConnected)
    }
}

// MARK: - 樂觀更新保護窗

/// 播放控制成功後先更新畫面；接下來 2 秒內與樂觀狀態矛盾的回應視為 Spotify 還沒套用
struct OptimisticGuard: Equatable, Sendable {
    var window: TimeInterval = 2
    var seekThreshold: TimeInterval = 2
    private(set) var until: Date = .distantPast

    mutating func arm(now: Date) {
        until = now.addingTimeInterval(window)
    }

    func isActive(now: Date) -> Bool { now < until }

    /// 回應是否與目前（樂觀）狀態矛盾，應該忽略
    func shouldIgnore(current: PlaybackSnapshot?, incoming: PlaybackSnapshot, now: Date) -> Bool {
        guard isActive(now: now), let current, current.trackID == incoming.trackID else { return false }
        return current.isPlaying != incoming.isPlaying
            || abs(current.position(at: incoming.timestamp) - incoming.progress) > seekThreshold
    }
}

// MARK: - 小工具逐句重新整理

/// 監督「每換一句就請系統重新整理小工具」：
/// - 前景一律允許（Apple 文件：前景不計額度）
/// - 背景：每 10 次要求若系統實際重新整理不到 3 次 → 判定被節流，停用 30 分鐘並改用段落模式
/// - 每小時上限，避免萬一不豁免時把一天的額度用光
/// - 換歌 / 拖動 / 暫停等「重要」重新整理不受限制，且之後 2 秒內不發逐句
struct WidgetReloadPolicy: Equatable, Sendable {
    var minInterval: TimeInterval = 1
    var hourlyCap = 200
    var windowSize = 10
    var minRenderedPerWindow = 3
    var disableDuration: TimeInterval = 1800
    var quietAfterImportant: TimeInterval = 2

    private(set) var recent: [Date] = []
    private(set) var disabledUntil: Date?
    private(set) var lastRequestAt: Date = .distantPast
    private(set) var lastImportantAt: Date = .distantPast
    private var windowCount = 0
    private var windowStartRenders: Int?
    /// 最近一次判定的比例（診斷用）：實際 / 要求
    private(set) var lastWindowResult: (rendered: Int, requested: Int)?

    init(minInterval: TimeInterval = 1, hourlyCap: Int = 200, windowSize: Int = 10,
         minRenderedPerWindow: Int = 3, disableDuration: TimeInterval = 1800, quietAfterImportant: TimeInterval = 2) {
        self.minInterval = minInterval
        self.hourlyCap = hourlyCap
        self.windowSize = windowSize
        self.minRenderedPerWindow = minRenderedPerWindow
        self.disableDuration = disableDuration
        self.quietAfterImportant = quietAfterImportant
    }

    static func == (a: WidgetReloadPolicy, b: WidgetReloadPolicy) -> Bool {
        a.recent == b.recent && a.disabledUntil == b.disabledUntil && a.lastRequestAt == b.lastRequestAt
    }

    func isDisabled(now: Date) -> Bool {
        if let d = disabledUntil { return now < d }
        return false
    }

    func mode(now: Date) -> LyricsTimelineMode { isDisabled(now: now) ? .paragraph : .perLine }

    mutating func recordImportant(now: Date) {
        lastImportantAt = now
    }

    /// 換句時呼叫；回傳 true 代表可以請系統重新整理
    mutating func allowLineReload(now: Date, isForeground: Bool, renderCount: Int) -> Bool {
        if let d = disabledUntil, now >= d { disabledUntil = nil }
        guard now.timeIntervalSince(lastRequestAt) >= minInterval,
              now.timeIntervalSince(lastImportantAt) >= quietAfterImportant else { return false }
        if isForeground {
            lastRequestAt = now
            return true
        }
        guard !isDisabled(now: now) else { return false }
        recent = recent.filter { now.timeIntervalSince($0) < 3600 }
        guard recent.count < hourlyCap else { return false }

        // 回饋控制：每 windowSize 次檢查一次系統實際執行了幾次
        if windowStartRenders == nil { windowStartRenders = renderCount }
        windowCount += 1
        if windowCount > windowSize, let start = windowStartRenders {
            let rendered = renderCount - start
            lastWindowResult = (rendered, windowSize)
            windowCount = 1
            windowStartRenders = renderCount
            if rendered < minRenderedPerWindow {
                disabledUntil = now.addingTimeInterval(disableDuration)
                return false
            }
        }
        recent.append(now)
        lastRequestAt = now
        return true
    }

    /// 回到前景：重新開始量測
    mutating func resetWindow() {
        windowCount = 0
        windowStartRenders = nil
    }
}
