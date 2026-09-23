import AppIntents
import Foundation

/// 要開啟的畫面
enum CarLyricsScreen: String, AppEnum {
    case lyrics
    case focus

    // 用 let：Swift 6 不允許可變的全域／靜態變數（並行安全）
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "CarLyrics 畫面"
    static let caseDisplayRepresentations: [CarLyricsScreen: DisplayRepresentation] = [
        .lyrics: "歌詞",
        .focus: "專注模式",
    ]
}

/// 開啟 CarLyrics（控制中心按鈕、捷徑、Siri 共用）。
/// Apple 文件：開啟 App 的控制要用 `OpenIntent`，且 intent 必須同時屬於 App 與 Widget Extension，
/// 所以放在 Shared/。
struct OpenCarLyricsIntent: OpenIntent {
    static let title: LocalizedStringResource = "開啟 CarLyrics"
    static let description = IntentDescription("打開 CarLyrics 開始同步歌詞（讓鎖定畫面與 CarPlay 的即時動態可以啟動）。")

    @Parameter(title: "畫面", default: .lyrics)
    var target: CarLyricsScreen

    init() {}

    init(target: CarLyricsScreen) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // 冷啟動時畫面可能還沒掛上 → 先寫一份，AppModel 啟動時會讀
        Preferences().pendingScreen = target.rawValue
        NotificationCenter.default.post(name: .carLyricsOpenScreen, object: nil,
                                        userInfo: ["screen": target.rawValue])
        return .result()
    }
}

extension Notification.Name {
    static let carLyricsOpenScreen = Notification.Name("CarLyricsOpenScreen")
}
