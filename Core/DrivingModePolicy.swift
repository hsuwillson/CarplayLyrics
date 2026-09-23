import Foundation

/// 開車模式（讓 CarLyrics 留在前景）的決策（純邏輯，可測試）。
///
/// 實測（build 36）：只靠背景音訊活著的 App，在背景送出的即時動態更新會被系統擋掉
/// （進背景 3–13 秒後開始被擋，之後每句都不會套用），CarPlay 儀表板就停在最後一次
/// 前景送出的內容（第一句 / 上一首）。iOS 沒有給免費的替代路徑（推播要伺服器與付費帳號），
/// 所以最可靠的做法是：連著 CarPlay 時讓 App 留在螢幕上——螢幕不自動關閉、必要時調暗。
/// UIKit 的呼叫在 AppModel / ScreenDimmer；這裡只算「該不該」。
struct DrivingModePolicy: Equatable, Sendable {
    struct Input: Equatable, Sendable {
        /// App 在前景（scenePhase == .active）
        var isForeground: Bool
        /// 接著車用音訊（CarPlay）
        var carConnected: Bool
        /// 設定：開車時保持螢幕開著（預設開）
        var keepAwakeWhileDriving: Bool
        /// 設定：開車時把螢幕調暗（預設關）
        var dimWhileDriving: Bool
        /// 設定：鎖定畫面與 CarPlay 歌詞（即時動態）有開；關掉的話留在前景沒有意義
        var liveActivityEnabled: Bool
        /// 專注模式畫面開著（本來就不讓螢幕關）
        var focusModeActive: Bool
        /// 設定：播放時螢幕不自動關閉（開車以外也適用）
        var keepScreenOn: Bool
        var isPlaying: Bool
        /// 定位保活執行中（鎖定後也會嘗試更新；見 LocationKeepAlivePolicy）：提示改成說明實驗中
        var locationKeepAlive: Bool

        init(isForeground: Bool, carConnected: Bool, keepAwakeWhileDriving: Bool = true,
             dimWhileDriving: Bool = false, liveActivityEnabled: Bool = true, focusModeActive: Bool = false,
             keepScreenOn: Bool = false, isPlaying: Bool = false, locationKeepAlive: Bool = false) {
            self.isForeground = isForeground
            self.carConnected = carConnected
            self.keepAwakeWhileDriving = keepAwakeWhileDriving
            self.dimWhileDriving = dimWhileDriving
            self.liveActivityEnabled = liveActivityEnabled
            self.focusModeActive = focusModeActive
            self.keepScreenOn = keepScreenOn
            self.isPlaying = isPlaying
            self.locationKeepAlive = locationKeepAlive
        }
    }

    /// 開車模式的變化（記錄用）
    enum Change: Equatable, Sendable {
        case entered
        case exited
        case none
    }

    /// 調暗時的亮度（0–1）。專注模式幾乎全黑（OLED 不耗電），這個值只是讓白字不刺眼
    var dimmedBrightness: Double = 0.3

    /// 開車模式現在是否生效：在前景、接著 CarPlay、設定有開、而且即時動態有開
    func isDriving(_ i: Input) -> Bool {
        i.isForeground && i.carConnected && i.keepAwakeWhileDriving && i.liveActivityEnabled
    }

    /// 螢幕不自動關閉（`isIdleTimerDisabled`）：只在前景有意義
    func shouldDisableIdleTimer(_ i: Input) -> Bool {
        i.isForeground && (isDriving(i) || i.focusModeActive || (i.keepScreenOn && i.isPlaying))
    }

    /// 要把螢幕調到多亮；nil = 不動（或該恢復原本亮度）
    func targetBrightness(_ i: Input) -> Double? {
        isDriving(i) && i.dimWhileDriving ? dimmedBrightness : nil
    }

    func change(from wasDriving: Bool, to isDriving: Bool) -> Change {
        switch (wasDriving, isDriving) {
        case (false, true): return .entered
        case (true, false): return .exited
        default: return .none
        }
    }

    /// 給畫面的一句話：為什麼要留在螢幕上；不需要提醒時 nil
    func hint(_ i: Input) -> String? {
        guard i.carConnected, i.liveActivityEnabled else { return nil }
        if i.locationKeepAlive {
            return "定位保活執行中：鎖定後也會嘗試更新 CarPlay 歌詞（實驗）。沒跟上就回到 CarLyrics"
        }
        return i.keepAwakeWhileDriving
            ? "讓 CarLyrics 留在螢幕上，CarPlay 歌詞才會即時更新（鎖定後只剩小工具會動）"
            : "鎖定手機後 iOS 會停止更新 CarPlay 歌詞；到設定打開「開車時保持螢幕開著」"
    }
}
