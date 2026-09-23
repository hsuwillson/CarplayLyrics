import Foundation
import Network

/// 監看網路狀態：離線時暫停輪詢、恢復連線時立刻重新查詢
@MainActor
final class Reachability {
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true
    /// Wi-Fi（不計流量、也沒開「低數據模式」）：可以放心預先載入整個播放佇列
    private(set) var isWiFi = false
    /// 網路狀態改變（true = 恢復連線）
    var onChange: ((Bool) -> Void)?
    /// 上次記錄的網路種類（只在改變時記一行）
    private var lastKind: String?

    nonisolated private static func describe(_ path: NWPath) -> String {
        var s = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.cellular) ? "行動網路" : "其他"
        if path.isExpensive { s += "（計量）" }
        if path.isConstrained { s += "（低數據模式）" }
        return s
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let wifi = online && path.usesInterfaceType(.wifi) && !path.isExpensive && !path.isConstrained
            let kind = Self.describe(path)
            Task { @MainActor in
                guard let self else { return }
                self.isWiFi = wifi
                if online, kind != self.lastKind {
                    // 網路種類改變（Wi-Fi ↔ 行動網路、低數據模式）：影響預先載入與耗電，記下來
                    if self.lastKind != nil { debugLog("網路：\(kind)") }
                    self.lastKind = kind
                }
                guard self.isOnline != online else { return }
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
