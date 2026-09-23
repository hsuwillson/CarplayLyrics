import Foundation
import Observation
import UserNotifications

/// 通知的識別碼（同一個 id 重送會取代前一則；回前景時用它收掉）
private let carConnectNoticeIdentifier = "CarLyrics.carConnected"

/// 上車提醒的本機通知（決策在 `CarConnectNoticePolicy`；這裡只做 UserNotifications 的呼叫）。
/// - 權限只在前景、由使用者看得到原因的地方詢問（設定的開關、設定檢查、主畫面橫幅），不在車上問
/// - 通知內容固定、不含歌名；點通知就是打開 App（系統預設行為，不需要 delegate）
/// - 通知只會出現在 iPhone：CarPlay 螢幕要顯示通知需要 CarPlay 授權（Apple 文件 `allowInCarPlay`），本 App 沒有
@MainActor
@Observable
final class CarConnectNotifier {
    private(set) var authorization: CarConnectNoticePolicy.Authorization = .notDetermined
    /// 使用者在系統詢問按了允許 / 不允許
    @ObservationIgnored var onAuthorizationChanged: (() -> Void)?

    init() {
        Task { await refreshAuthorization() }
    }

    /// 讀目前的通知權限（使用者可能到系統設定改過）
    func refreshAuthorization() async {
        let status = await Self.currentStatus()
        let new = Self.map(status)
        guard new != authorization else { return }
        authorization = new
        onAuthorizationChanged?()
    }

    /// 系統的通知權限詢問（問過一次之後系統不會再問）
    func requestAuthorization() {
        guard authorization == .notDetermined else { return }
        debugLog("上車提醒：詢問通知權限")
        Task {
            let result = await Self.request()
            switch result {
            case .success(let granted): debugLog(granted ? "通知權限：允許" : "通知權限：不允許")
            case .failure(let error): debugLog("通知權限詢問失敗：\(error.localizedDescription)")
            }
            await refreshAuthorization()
        }
    }

    /// 送出通知（立即）；回傳是否送出成功
    func post(title: String, body: String) async -> Bool {
        await Self.deliver(title: title, body: body)
    }

    /// 回到前景：提醒已經沒有意義，收掉
    func clearDelivered() {
        Self.clear()
    }

    var authorizationLabel: String {
        switch authorization {
        case .notDetermined: return "尚未詢問"
        case .denied: return "不允許"
        case .authorized: return "已允許"
        }
    }

    // MARK: - 內部（UNUserNotificationCenter 的物件不跨 actor：在 nonisolated 裡建立、送出）

    nonisolated private static func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    nonisolated private static func request() async -> Result<Bool, any Error> {
        do {
            return .success(try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]))
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [carConnectNoticeIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [carConnectNoticeIdentifier])
    }

    nonisolated private static func deliver(title: String, body: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: carConnectNoticeIdentifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    private static func map(_ status: UNAuthorizationStatus) -> CarConnectNoticePolicy.Authorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }
}
