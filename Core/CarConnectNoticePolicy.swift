import Foundation

/// 「上車提醒」（本機通知）的決策（純邏輯，可測試）。
///
/// ActivityKit 只允許 App 在前景開始即時動態（背景的 `Activity.request` 會丟 "Target is not foreground"）。
/// 連上 CarPlay 時 App 若在背景，鎖定畫面 / CarPlay 就不會有歌詞，要等使用者自己想到去打開 App。
/// 所以上車後 App 還在背景、又沒有即時動態時，送一則本機通知「點一下開始顯示 CarPlay 歌詞」；
/// 點通知就是打開 App（前景）→ 即時動態自然開始。不用推播、不用伺服器，只要通知權限。
///
/// 通知只會出現在 iPhone（鎖定畫面 / 橫幅）。Apple 文件（`UNNotificationCategoryOptions.allowInCarPlay`）：
/// "Apps must be approved for CarPlay overall" 才能讓通知顯示在 CarPlay 螢幕，CarLyrics 沒有 CarPlay 授權。
///
/// 節制：每次上車最多一次；即時動態已經在跑就不送；上車後先等 `delay` 秒（捷徑自動化通常幾秒內就會把
/// App 叫到前景，那就不用吵）。UserNotifications 的呼叫在 `CarConnectNotifier`。
struct CarConnectNoticePolicy: Equatable, Sendable {
    /// 通知權限（對應 UNAuthorizationStatus，不依賴 UserNotifications）
    enum Authorization: Equatable, Sendable {
        case notDetermined
        case denied
        case authorized

        var isGranted: Bool { self == .authorized }
    }

    struct Input: Equatable, Sendable {
        /// 設定：上車時提醒（預設開）
        var enabled: Bool
        var loggedIn: Bool
        /// 設定：鎖定畫面與 CarPlay 歌詞有開，而且系統允許即時動態
        var liveActivityEnabled: Bool
        /// App 在前景（前景的話即時動態自己會開始，不用提醒）
        var isForeground: Bool
        /// 已經有即時動態在進行
        var activityIsActive: Bool
        var authorization: Authorization
        /// 這次上車已經提醒過
        var notifiedThisConnection: Bool

        init(enabled: Bool, loggedIn: Bool = true, liveActivityEnabled: Bool = true, isForeground: Bool = false,
             activityIsActive: Bool = false, authorization: Authorization = .authorized,
             notifiedThisConnection: Bool = false) {
            self.enabled = enabled
            self.loggedIn = loggedIn
            self.liveActivityEnabled = liveActivityEnabled
            self.isForeground = isForeground
            self.activityIsActive = activityIsActive
            self.authorization = authorization
            self.notifiedThisConnection = notifiedThisConnection
        }
    }

    /// 上車後先等這麼久再送（App 若在這段時間內回到前景就不送）
    var delay: TimeInterval = 8

    static let title = "CarPlay 已連接"
    static let body = "點一下開始顯示 CarPlay 歌詞"

    /// 上車當下（排程前）與 `delay` 秒後（送出前）都用同一條規則各判一次
    func shouldNotify(_ i: Input) -> Bool {
        i.enabled && i.loggedIn && i.liveActivityEnabled && !i.isForeground && !i.activityIsActive
            && i.authorization.isGranted && !i.notifiedThisConnection
    }

    /// 設定頁 / 設定檢查用的一句話狀態
    func status(_ i: Input) -> String {
        guard i.enabled else { return "關閉" }
        switch i.authorization {
        case .denied: return "需要通知權限：到系統設定允許通知"
        case .notDetermined: return "尚未允許通知（會在前景詢問一次）"
        case .authorized: break
        }
        if !i.loggedIn { return "請先登入 Spotify" }
        if !i.liveActivityEnabled { return "鎖定畫面歌詞已關閉，用不到提醒" }
        return "上車時 App 在背景才會提醒（只出現在 iPhone 上）"
    }
}
