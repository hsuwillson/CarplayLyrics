import Foundation

/// 所有使用者設定集中在這裡（key 沿用舊版，升級不會遺失設定）
final class Preferences {
    enum Key {
        static let globalOffset = "lyricsOffset"
        static let backgroundEnabled = "backgroundEnabled"
        static let liveActivityEnabled = "liveActivityEnabled"
        static let keepScreenOn = "keepScreenOn"
        static let hasSeenSetup = "hasSeenSetup"
        static let focusFontScale = "focusFontScale"
        static let focusLandscapeLock = "focusLandscapeLock"
        static let autoFocusInCar = "autoFocusInCar"
        static let endActivityWhenIdle = "endActivityWhenIdle"
        static let pendingScreen = "pendingScreen"
        static let prefetchQueueOnWiFi = "prefetchQueueOnWiFi"
        static let lastHeartbeat = "lastHeartbeat"
        static let lastHeartbeatInBackground = "lastHeartbeatInBackground"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    var globalOffset: TimeInterval {
        get { defaults.double(forKey: Key.globalOffset) }
        set { defaults.set(newValue, forKey: Key.globalOffset) }
    }

    var backgroundEnabled: Bool {
        get { bool(Key.backgroundEnabled, default: true) }
        set { defaults.set(newValue, forKey: Key.backgroundEnabled) }
    }

    var liveActivityEnabled: Bool {
        get { bool(Key.liveActivityEnabled, default: true) }
        set { defaults.set(newValue, forKey: Key.liveActivityEnabled) }
    }

    var keepScreenOn: Bool {
        get { bool(Key.keepScreenOn, default: false) }
        set { defaults.set(newValue, forKey: Key.keepScreenOn) }
    }

    var hasSeenSetup: Bool {
        get { bool(Key.hasSeenSetup, default: false) }
        set { defaults.set(newValue, forKey: Key.hasSeenSetup) }
    }

    /// 專注模式字級倍率（0.8–1.4）
    var focusFontScale: Double {
        get {
            let v = defaults.double(forKey: Key.focusFontScale)
            return v == 0 ? 1 : min(1.4, max(0.8, v))
        }
        set { defaults.set(min(1.4, max(0.8, newValue)), forKey: Key.focusFontScale) }
    }

    /// 專注模式鎖定橫向（車架橫放時，系統方向鎖定也擋不住）
    var focusLandscapeLock: Bool {
        get { bool(Key.focusLandscapeLock, default: false) }
        set { defaults.set(newValue, forKey: Key.focusLandscapeLock) }
    }

    /// 連上車用音訊時自動進入專注模式
    var autoFocusInCar: Bool {
        get { bool(Key.autoFocusInCar, default: true) }
        set { defaults.set(newValue, forKey: Key.autoFocusInCar) }
    }

    /// 沒在播放時結束即時動態（不要一直佔用靈動島）
    var endActivityWhenIdle: Bool {
        get { bool(Key.endActivityWhenIdle, default: true) }
        set { defaults.set(newValue, forKey: Key.endActivityWhenIdle) }
    }

    /// Wi-Fi 時預先載入整個播放佇列的歌詞（進隧道 / 地下停車場也有歌詞）
    var prefetchQueueOnWiFi: Bool {
        get { bool(Key.prefetchQueueOnWiFi, default: true) }
        set { defaults.set(newValue, forKey: Key.prefetchQueueOnWiFi) }
    }

    /// 控制中心 / 捷徑要求開啟的畫面（App 還沒啟動時先寫在這裡）
    var pendingScreen: String? {
        get { defaults.string(forKey: Key.pendingScreen) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.pendingScreen) }
            else { defaults.removeObject(forKey: Key.pendingScreen) }
        }
    }

    /// 上一次輪詢的時間與當時是否在背景（偵測 App 被系統終止）
    var lastHeartbeat: (date: Date, inBackground: Bool)? {
        get {
            let t = defaults.double(forKey: Key.lastHeartbeat)
            guard t > 0 else { return nil }
            return (Date(timeIntervalSince1970: t), defaults.bool(forKey: Key.lastHeartbeatInBackground))
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.lastHeartbeat)
                return
            }
            defaults.set(newValue.date.timeIntervalSince1970, forKey: Key.lastHeartbeat)
            defaults.set(newValue.inBackground, forKey: Key.lastHeartbeatInBackground)
        }
    }
}
