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

    /// 使用者現在看得到什麼（決定要多即時）
    enum Surface: Equatable, Sendable {
        /// App 在前景
        case foreground
        /// 背景，但鎖定畫面 / CarPlay 的即時動態正常更新，或連著車用音訊
        case visible
        /// 背景，而且沒有任何會即時更新的畫面（即時動態被擋或沒開）
        case hidden
    }

    var playingInterval: TimeInterval { constrained ? 5 : 2.5 }
    var pausedInterval: TimeInterval { constrained ? 10 : 5 }

    /// 歌曲進行中、沒有剛發生的變化時的間隔：位置可以自己推算，輪詢只是為了發現暫停 / 跳歌 / 拖動
    func steadyInterval(for surface: Surface) -> TimeInterval {
        switch surface {
        case .foreground: return playingInterval
        case .visible: return constrained ? 8 : 5
        case .hidden: return constrained ? 20 : 15
        }
    }

    /// 暫停越久問得越少（剛暫停常常馬上繼續，久了多半是真的停了）
    func pausedDelay(idleFor: TimeInterval) -> TimeInterval {
        if idleFor < 120 { return pausedInterval }
        if idleFor < 600 { return pausedInterval * 2 }
        return pausedInterval * 4
    }

    /// - Parameters:
    ///   - surface: 使用者看得到什麼；預設前景（最即時）
    ///   - hot: 剛發生換歌 / 拖動 / 暫停 / 操作後的一小段時間，維持最快的頻率
    ///   - idleFor: 暫停 / 沒在播放已經多久
    ///   - inCar: 連著車用音訊：「沒在播放」多半是暫停後 Spotify 回 204，很快會續播，前 10 分鐘問勤一點
    func delay(for outcome: PollOutcome, quotaActive: Bool = false, preferFullPlayer: Bool = false,
               surface: Surface = .foreground, hot: Bool = false, idleFor: TimeInterval = 0,
               inCar: Bool = false) -> TimeInterval {
        switch outcome {
        case .idleStopped:
            return 30
        case .loggedOut:
            return 10
        case .playing(let isPlaying, let remaining):
            if quotaActive { return 6 }
            if preferFullPlayer { return 1 }          // 過期資料 → 盡快用另一個端點確認
            guard isPlaying else { return pausedDelay(idleFor: idleFor) }
            let base = hot ? playingInterval : steadyInterval(for: surface)
            // 接近歌曲結尾：在預計換歌後馬上查一次（任何模式都一樣）
            if let remaining, remaining > 0, remaining < base {
                return max(0.5, remaining + 0.4)
            }
            return base
        case .nonMusic:
            if quotaActive { return 10 }
            return idleFor < 300 ? 5 : 10
        case .nothing(let streak):
            // 偶發的 204（切歌、切換裝置）先快速重試；沒在播放久了就放慢
            if streak < 2 { return 3 }
            if idleFor < 120 { return inCar ? 5 : 10 }
            return inCar && idleFor < 600 ? 10 : 30
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
    /// 沒在播放這麼久之後結束即時動態（不要一直佔用動態島）
    var activityEndAfterNothing: TimeInterval = 30
    /// 暫停這麼久之後結束即時動態（暫停常常只是等紅燈，給久一點）；連著車用音訊時不適用
    var activityEndAfterPaused: TimeInterval = 300

    func limit(for kind: Kind, carConnected: Bool = false) -> TimeInterval {
        let base: TimeInterval
        switch kind {
        case .paused: base = pausedLimit
        case .nothing: base = nothingLimit
        case .nonMusic: base = nonMusicLimit
        }
        return carConnected ? base * carMultiplier : base
    }

    /// 閒置多久之後結束即時動態；廣告 / Podcast 還在播就不結束。
    /// 收起即時動態只是為了不佔用動態島，那是「不在車上」才有的問題：
    /// 連著車用音訊時暫停（得來速、等人、講電話）一律不收，因為 App 在背景收掉之後就開不回來，
    /// 接下來整趟車鎖定畫面 / CarPlay 都不會有歌詞；「沒在播放」則放寬到暫停的停止門檻（30 分鐘）。
    func activityEndDelay(for kind: Kind, carConnected: Bool = false) -> TimeInterval? {
        switch kind {
        case .nothing: return carConnected ? pausedLimit : activityEndAfterNothing
        case .paused: return carConnected ? nil : activityEndAfterPaused
        case .nonMusic: return nil
        }
    }

    /// 即時動態閒置太久 → 結束（與 shouldStop 不同：這個前景也會做，因為佔用動態島）。
    /// 這一輪還沒播過任何歌時不收：使用者常常先開 CarLyrics 再去 Spotify 按播放，
    /// 這時候收掉的話，App 在背景就沒辦法再開始即時動態了。
    func shouldEndActivity(kind: Kind, since: Date, now: Date, carConnected: Bool = false,
                           hasPlayed: Bool = true) -> Bool {
        guard hasPlayed, let delay = activityEndDelay(for: kind, carConnected: carConnected) else { return false }
        return now.timeIntervalSince(since) >= delay
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

    /// 換句時呼叫；回傳 true 代表可以請系統重新整理。
    /// - Parameter neverRendered: 小工具從來沒有被系統畫過（renderCount == 0 且沒有 lastRenderAt）：
    ///   多半是根本沒加到任何畫面上，這時候不做節流判定，否則會誤判成「被系統節流」而改用段落模式。
    mutating func allowLineReload(now: Date, isForeground: Bool, renderCount: Int,
                                  neverRendered: Bool = false) -> Bool {
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

        // 回饋控制：每 windowSize 次檢查一次系統實際執行了幾次（小工具還沒加入時量不到，先不算）
        if neverRendered {
            resetWindow()
        } else {
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
