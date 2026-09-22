import Foundation

/// 解析 App 內附的 embedded.mobileprovision（AltStore / Sideloadly 重簽後的描述檔）。
/// - App Group 的 ID 會被重簽工具改名，執行時從這裡讀出實際授權的 group
/// - 免費 Apple ID 的簽名 7 天到期，`expirationDate` 用來提醒重新整理
struct ProvisioningProfile: Equatable, Sendable {
    var name: String?
    var teamName: String?
    var expirationDate: Date?
    var appGroups: [String]

    /// 描述檔是 CMS 簽章包住的 XML plist：找出 `<?xml` … `</plist>` 這一段來解析
    init?(data: Data) {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else { return nil }
        name = plist["Name"] as? String
        teamName = plist["TeamName"] as? String
        expirationDate = plist["ExpirationDate"] as? Date
        let entitlements = plist["Entitlements"] as? [String: Any]
        appGroups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
    }

    static func embedded(in bundle: Bundle = .main) -> ProvisioningProfile? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return ProvisioningProfile(data: data)
    }

    /// 剩幾天到期（無條件捨去；已過期為負數）
    func daysRemaining(now: Date = Date()) -> Int? {
        guard let expirationDate else { return nil }
        return Int(floor(expirationDate.timeIntervalSince(now) / 86_400))
    }
}
