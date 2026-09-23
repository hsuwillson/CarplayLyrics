import Foundation

/// 診斷快照：寫進紀錄檔、分享紀錄時放在最上面。
/// 只有「資料 → 文字」，方便測試；不含 token、帳號或任何可以登入的資訊。
struct DiagnosticsReport: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var key: String
        var value: String
    }

    struct Section: Equatable, Sendable {
        var title: String
        var items: [Item]
    }

    /// 為什麼記這一筆（啟動、進入背景、定期、分享…）
    var reason: String
    private(set) var sections: [Section] = []

    init(reason: String) {
        self.reason = reason
    }

    /// 加一個區塊；值為 nil 的項目略過，整個區塊都沒有值就不加
    mutating func add(_ title: String, _ items: [(String, String?)]) {
        let kept = items.compactMap { key, value in value.map { Item(key: key, value: $0) } }
        guard !kept.isEmpty else { return }
        sections.append(Section(title: title, items: kept))
    }

    /// 每個區塊一行，方便在紀錄裡掃
    var text: String {
        var lines = ["［狀態快照：\(reason)］"]
        for s in sections {
            lines.append("〔\(s.title)〕" + s.items.map { "\($0.key)=\($0.value)" }.joined(separator: "，"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 格式小工具

    static func seconds(_ t: TimeInterval?) -> String? {
        t.map { String(format: "%.1f 秒", $0) }
    }

    static func ago(_ date: Date?, now: Date) -> String? {
        date.map { "\(max(0, Int(now.timeIntervalSince($0)))) 秒前" }
    }

    static func yesNo(_ b: Bool) -> String { b ? "是" : "否" }

    static func percent(_ level: Float) -> String? {
        level < 0 ? nil : "\(Int((level * 100).rounded()))%"
    }
}
