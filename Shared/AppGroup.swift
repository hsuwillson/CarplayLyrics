import Foundation

/// App 與 Widget Extension 共用的設定。
///
/// 用免費 Apple ID 透過 AltStore / Sideloadly 重簽時，App Group 的 ID 會被改名
/// （例如加上 Team ID），所以執行時先從 bundle 內的 embedded.mobileprovision
/// 讀出實際授權的 App Group，讀不到才用預設值。
enum AppGroup {
    static let defaultIdentifier = "group.com.willsonhsu.CarLyrics"

    static let identifier: String = {
        let groups = provisionedGroups()
        // 優先找名稱裡含 CarLyrics 的 group，其次取第一個
        return groups.first { $0.localizedCaseInsensitiveContains("CarLyrics") }
            ?? groups.first
            ?? defaultIdentifier
    }()

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// 從 embedded.mobileprovision 解析 `com.apple.security.application-groups`
    static func provisionedGroups(bundle: Bundle = .main) -> [String] {
        // Extension 的 bundle 裡也有自己的描述檔
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return [] }

        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }
}
