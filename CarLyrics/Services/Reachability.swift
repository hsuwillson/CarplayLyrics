import Foundation
import Network

/// 監看網路狀態：離線時暫停輪詢、恢復連線時立刻重新查詢
@MainActor
final class Reachability {
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true
    /// 網路狀態改變（true = 恢復連線）
    var onChange: ((Bool) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                debugLog(online ? "網路已恢復" : "網路中斷")
                self.onChange?(online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "CarLyrics.Reachability"))
    }

    func stop() {
        monitor.cancel()
    }
}
