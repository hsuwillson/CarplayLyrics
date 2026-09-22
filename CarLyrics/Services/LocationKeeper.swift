import CoreLocation
import Foundation

/// 用「背景定位」讓 App 在背景持續執行。
/// iOS 會擋掉「只播放背景音訊」的 App 在背景更新 Live Activity；
/// 同時有定位工作階段時，系統不把 App 當成單純的音訊 App（需實測驗證）。
/// 只用最低精準度，不記錄、不上傳任何位置。
@MainActor
final class LocationKeeper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private(set) var wantsRunning = false
    private(set) var isUpdating = false
    private(set) var updateCount = 0
    private(set) var lastUpdateAt: Date?
    private(set) var lastError: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 1000
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
    }

    var authorizationDescription: String {
        switch manager.authorizationStatus {
        case .notDetermined: return "尚未詢問"
        case .denied: return "已拒絕"
        case .restricted: return "受限制"
        case .authorizedWhenInUse: return "使用 App 期間"
        case .authorizedAlways: return "永遠"
        @unknown default: return "未知"
        }
    }

    private var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }

    /// 需在前景呼叫（「使用 App 期間」的權限 + 從前景開始，才能在背景持續）
    func start() {
        wantsRunning = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            return
        case .denied, .restricted:
            lastError = "定位權限未允許"
            return
        default:
            break
        }
        guard !isUpdating else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        manager.startUpdatingLocation()
        isUpdating = true
        debugLog("背景定位已啟動")
    }

    func stop() {
        wantsRunning = false
        guard isUpdating || backgroundSession != nil else { return }
        manager.stopUpdatingLocation()
        backgroundSession?.invalidate()
        backgroundSession = nil
        isUpdating = false
        debugLog("背景定位已停止")
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            debugLog("定位權限：\(authorizationDescription)")
            if wantsRunning && isAuthorized && !isUpdating { start() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            updateCount += 1
            lastUpdateAt = Date()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            lastError = error.localizedDescription
        }
    }
}
