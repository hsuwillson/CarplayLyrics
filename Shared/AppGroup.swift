import Foundation

/// App 與 Widget Extension 共用的設定。
///
/// 用免費 Apple ID 透過 AltStore / Sideloadly 重簽時，App Group 的 ID 會被改名
/// （例如加上 Team ID），所以執行時先從 bundle 內的 embedded.mobileprovision
/// 讀出實際授權的 App Group，讀不到才用預設值。
enum AppGroup {
    static let defaultIdentifier = "group.com.willsonhsu.CarLyrics"

    /// Extension 的 bundle 裡也有自己的描述檔
    static let profile: ProvisioningProfile? = ProvisioningProfile.embedded()

    static let identifier: String = {
        let groups = profile?.appGroups ?? []
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
}
