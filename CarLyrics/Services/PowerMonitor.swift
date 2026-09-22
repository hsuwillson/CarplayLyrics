import Foundation

/// 低耗電模式 / 過熱：放慢輪詢、停止預先載入與逐句更新小工具
@MainActor
final class PowerMonitor {
    private(set) var isConstrained = false
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        isConstrained = Self.evaluate()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    var description: String {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return "低耗電模式（放慢更新）" }
        switch info.thermalState {
        case .serious, .critical: return "裝置過熱（放慢更新）"
        default: return "一般"
        }
    }

    private func refresh() {
        let new = Self.evaluate()
        guard new != isConstrained else { return }
        isConstrained = new
        debugLog("耗電狀態：\(description)")
        onChange?(new)
    }

    private static func evaluate() -> Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }
}
