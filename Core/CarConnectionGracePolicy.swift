import Foundation

/// 車用音訊（CarPlay）「離開」的寬限期（純邏輯，可測試）。
///
/// 實測（build 45）：CarPlay 的音訊路由會閃斷——「已離開」10–20 秒後又「已連接」。每次閃斷都立刻結束
/// 即時動態 / 開車模式 / 定位保活的話，重新連上時 App 若在背景就開不回來（ActivityKit 只允許前景開始），
/// 整趟車就沒歌詞了。所以路由消失先等 `grace` 秒：期間對外仍算「連著車」；期間內重新連上就當作沒發生；
/// 寬限到了還沒回來才真的算離開（該收的照收，閒置 / 省電規則照舊）。
/// 對外呈現的狀態是 `isConnected`；AVAudioSession 的通知在 `SilentAudioKeeper`，計時器在 AppModel。
struct CarConnectionGracePolicy: Equatable, Sendable {
    /// 路由消失後等多久才算真的離開（秒）
    var grace: TimeInterval = 30
    /// 對外呈現的狀態（寬限期內仍是 true）
    private(set) var isConnected: Bool
    /// 路由消失、還在寬限期的起點；沒有在寬限期時 nil
    private(set) var pendingSince: Date?

    init(connected: Bool = false, grace: TimeInterval = 30) {
        isConnected = connected
        self.grace = grace
    }

    enum Effect: Equatable, Sendable {
        case none
        /// 真的（第一次）連上：開即時動態、開車模式等
        case connected
        /// 寬限期內重新連上：取消計時器，什麼都不用收（參數：離開了幾秒）
        case reconnected(after: TimeInterval)
        /// 路由消失：排一個 `grace` 秒後的檢查（參數：要等幾秒）
        case disconnectScheduled(grace: TimeInterval)
        /// 寬限到了還沒回來：真的離開
        case disconnected
    }

    var isInGrace: Bool { pendingSince != nil }

    /// 系統回報路由改變
    mutating func routeChanged(connected: Bool, now: Date) -> Effect {
        if connected {
            if let since = pendingSince {
                pendingSince = nil
                return .reconnected(after: now.timeIntervalSince(since))
            }
            guard !isConnected else { return .none }
            isConnected = true
            return .connected
        }
        guard isConnected, pendingSince == nil else { return .none }
        pendingSince = now
        return .disconnectScheduled(grace: grace)
    }

    /// 計時器到了（或任何時候想確認）：寬限期真的過了才算離開
    mutating func graceElapsed(now: Date) -> Effect {
        guard let since = pendingSince, now.timeIntervalSince(since) >= grace else { return .none }
        pendingSince = nil
        isConnected = false
        return .disconnected
    }

    /// 寬限期還剩幾秒（診斷用）；不在寬限期時 nil
    func remainingGrace(now: Date) -> TimeInterval? {
        pendingSince.map { max(0, grace - now.timeIntervalSince($0)) }
    }
}
