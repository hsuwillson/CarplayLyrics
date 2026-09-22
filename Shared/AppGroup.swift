import Foundation

/// App 與 Widget Extension 共用的設定。
enum AppGroup {
    static let identifier = "group.com.willsonhsu.CarLyrics"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
