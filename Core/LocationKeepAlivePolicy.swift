import Foundation

/// 「鎖定時也更新歌詞（開車時使用定位）」的決策（純邏輯，可測試）。
///
/// 背景：iOS 會擋掉「只播放背景音訊」的 App 在背景送出的即時動態更新
/// （liveactivitiesd：「Process is only playing background media so is forbidden to update activity」）。
/// Apple 文件（`allowsBackgroundLocationUpdates`）：在前景開始定位更新後，
/// 「Core Location configures the system to keep the app running to receive continuous background location updates」，
/// 而且「使用 App 期間」的授權就夠（背景時狀態列會出現藍色定位指示）。
/// 開發者論壇（thread 717701）的實測：背景定位 / 子母畫面的 App 在背景更新即時動態沒有被擋，只有背景音訊被擋。
/// 所以這個實驗只在「開車、即時動態進行中」時開最低精準度的定位，讓系統多一個「定位」的執行理由；
/// 結果由 `LiveActivityReasonStats` 分「音訊」「定位」統計，下一份實測紀錄就能下結論。
///
/// 只算「該不該」；CoreLocation 的呼叫在 `LocationKeepAlive`。
struct LocationKeepAlivePolicy: Equatable, Sendable {
    /// 定位授權（對應 CLAuthorizationStatus，不依賴 CoreLocation）
    enum Authorization: Equatable, Sendable {
        case notDetermined
        case denied
        case restricted
        case whenInUse
        case always

        /// 使用 App 期間或永遠：可以開始
        var isGranted: Bool { self == .whenInUse || self == .always }
    }

    struct Input: Equatable, Sendable {
        /// 設定：鎖定時也更新歌詞（開車時使用定位）
        var enabled: Bool
        var loggedIn: Bool
        /// 設定：鎖定畫面與 CarPlay 歌詞（即時動態）有開
        var liveActivityEnabled: Bool
        /// 接著車用音訊，或使用者按了「現在顯示」（車子沒被認出來時的手動出口）
        var inCar: Bool
        /// 目前有即時動態在進行（沒有的話定位保活沒有意義）
        var activityIsActive: Bool
        /// App 在前景（Apple 文件：定位更新要在前景開始，之後進背景才會持續）
        var isForeground: Bool
        var authorization: Authorization
        /// 定位保活目前正在執行
        var isRunning: Bool

        init(enabled: Bool, loggedIn: Bool = true, liveActivityEnabled: Bool = true, inCar: Bool = true,
             activityIsActive: Bool = true, isForeground: Bool = true,
             authorization: Authorization = .whenInUse, isRunning: Bool = false) {
            self.enabled = enabled
            self.loggedIn = loggedIn
            self.liveActivityEnabled = liveActivityEnabled
            self.inCar = inCar
            self.activityIsActive = activityIsActive
            self.isForeground = isForeground
            self.authorization = authorization
            self.isRunning = isRunning
        }
    }

    enum Decision: Equatable, Sendable {
        /// 現在（在前景）開始定位保活
        case start
        case stop
        /// 還沒問過使用者：跳出系統的定位權限詢問
        case requestAuthorization
        /// 維持現狀
        case keep
    }

    /// 現在需要定位保活嗎（不看權限、不看前景）：設定開、已登入、即時動態有開而且進行中、在車上
    func wants(_ i: Input) -> Bool {
        i.enabled && i.loggedIn && i.liveActivityEnabled && i.inCar && i.activityIsActive
    }

    func decide(_ i: Input) -> Decision {
        guard wants(i) else { return i.isRunning ? .stop : .keep }
        switch i.authorization {
        case .notDetermined:
            // 系統的詢問只能在前景出現
            return i.isForeground ? .requestAuthorization : .keep
        case .denied, .restricted:
            return i.isRunning ? .stop : .keep
        case .whenInUse, .always:
            if i.isRunning { return .keep }
            // 背景不能開始（系統不會把它當成從前景開始的定位）：等回到前景
            return i.isForeground ? .start : .keep
        }
    }

    /// 設定頁 / 診斷用的一句話狀態
    func status(_ i: Input) -> String {
        guard i.enabled else { return "關閉" }
        switch i.authorization {
        case .denied: return "需要定位權限：到系統設定允許「使用 App 期間」"
        case .restricted: return "這支 iPhone 不允許定位"
        case .notDetermined: return "尚未允許定位（會在前景詢問一次）"
        case .whenInUse, .always: break
        }
        if i.isRunning { return "執行中（鎖定後也會嘗試更新歌詞）" }
        if !i.loggedIn { return "請先登入 Spotify" }
        if !i.liveActivityEnabled { return "鎖定畫面歌詞已關閉，用不到定位" }
        if !i.inCar { return "連上 CarPlay 後啟動" }
        if !i.activityIsActive { return "等即時動態開始" }
        if !i.isForeground { return "等回到前景再開始" }
        return "準備中"
    }
}
