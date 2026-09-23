import CoreLocation
import Foundation
import Observation

/// 定位保活（實驗）：開車、即時動態進行中時，用最低精準度的定位讓系統多一個「定位」的執行理由。
///
/// - iOS 擋掉的是「只播放背景音訊」的程序在背景送出的即時動態更新；Apple 文件（`allowsBackgroundLocationUpdates`）
///   說在前景開始定位更新後「Core Location configures the system to keep the app running」，
///   「使用 App 期間」的授權就夠，背景時狀態列會出現藍色定位指示（系統行為，關不掉）
/// - 依 Apple 文件（`pausesLocationUpdatesAutomatically`）的建議：關掉自動暫停 + `kCLLocationAccuracyThreeKilometers`，
///   「使用 App 期間」的 App 才能省電地持續收到更新（自動暫停後就收不到了）
/// - 同時開一個 `CLBackgroundActivitySession`（iOS 17+，Apple 文件：keeps your app in use in the background）
/// - 位置本身完全不用：不記錄、不上傳、不寫進紀錄檔；只數更新次數當作「定位真的在跑」的證據
/// - 決策在 `LocationKeepAlivePolicy`；這裡只做 CoreLocation 的呼叫
@MainActor
@Observable
final class LocationKeepAlive: NSObject, CLLocationManagerDelegate {
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?

    private(set) var isRunning = false
    private(set) var startedAt: Date?
    /// 收到定位更新的次數（不存位置）
    private(set) var updateCount = 0
    private(set) var lastUpdateAt: Date?
    private(set) var lastError: String?
    private(set) var authorization: LocationKeepAlivePolicy.Authorization
    /// 授權狀態改變（使用者在系統詢問按了允許 / 不允許、或到設定改了）
    @ObservationIgnored var onAuthorizationChanged: (() -> Void)?

    override init() {
        authorization = Self.map(manager.authorizationStatus)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 500
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
    }

    /// 系統的定位權限詢問（只在前景有用；問過一次之後系統不會再問）
    func requestAuthorization() {
        guard authorization == .notDetermined else { return }
        debugLog("定位保活：詢問定位權限")
        manager.requestWhenInUseAuthorization()
    }

    /// 在前景呼叫（Apple 文件：定位更新要在前景開始，之後進背景才會持續）
    func start() {
        guard !isRunning, authorization.isGranted else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        backgroundSession = CLBackgroundActivitySession()
        isRunning = true
        startedAt = Date()
        updateCount = 0
        lastError = nil
        let precision = manager.accuracyAuthorization == .reducedAccuracy ? "概略位置" : "最低精準度"
        debugLog("定位保活：開始（\(precision)，背景時狀態列會有藍色定位指示）")
    }

    /// - Parameter reason: 寫進紀錄（下車、即時動態結束、設定關閉、登出…）
    func stop(reason: String) {
        guard isRunning else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        isRunning = false
        let lived = startedAt.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
        startedAt = nil
        debugLog("定位保活：停止（\(reason)；持續 \(lived) 分鐘，收到 \(updateCount) 次更新）")
    }

    var authorizationLabel: String {
        switch authorization {
        case .notDetermined: return "尚未詢問"
        case .denied: return "不允許"
        case .restricted: return "受限制"
        case .whenInUse: return "使用 App 期間"
        case .always: return "永遠"
        }
    }

    private static func map(_ status: CLAuthorizationStatus) -> LocationKeepAlivePolicy.Authorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways: return .always
        case .authorizedWhenInUse: return .whenInUse
        @unknown default: return .denied
        }
    }

    // MARK: - CLLocationManagerDelegate
    // CLLocationManager 在主執行緒建立，回呼都在主執行緒的 RunLoop（Apple 文件），所以可以 assumeIsolated

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            let new = Self.map(manager.authorizationStatus)
            guard new != authorization else { return }
            authorization = new
            debugLog("定位權限：\(authorizationLabel)")
            if !new.isGranted, isRunning { stop(reason: "定位權限被收回") }
            onAuthorizationChanged?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            // 只數次數：位置本身不用、不記錄
            updateCount += 1
            lastUpdateAt = Date()
            if updateCount == 1 { debugLog("定位保活：收到第一次定位更新") }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            lastError = error.localizedDescription
            debugLog("定位保活：錯誤 \(error.localizedDescription)")
        }
    }
}
