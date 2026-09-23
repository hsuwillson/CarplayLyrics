import AppIntents
import Foundation

/// 即時動態 / 小工具上的播放控制。
///
/// `LiveActivityIntent` 的 `perform()` 在 **App 的程序**執行（App 沒在跑時系統會啟動它但不開畫面），
/// 所以 token 不需要交給 extension。App 啟動時會把實際執行的工作註冊進 `PlaybackIntentBridge`。
enum PlaybackIntentAction: String, Sendable {
    case playPause, next, previous
}

enum PlaybackIntentBridge {
    /// App 在啟動時註冊；widget 程序裡是 nil
    @MainActor static var handler: ((PlaybackIntentAction) async -> Void)?

    @MainActor
    static func run(_ action: PlaybackIntentAction) async {
        guard let handler else {
            // 極少數情況（App 程序還沒準備好）：留給 App 下次啟動時處理
            Preferences().pendingScreen = CarLyricsScreen.lyrics.rawValue
            return
        }
        await handler(action)
    }
}

struct PlayPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "播放 / 暫停"
    static var description = IntentDescription("在鎖定畫面或小工具控制 Spotify 的播放。")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await PlaybackIntentBridge.run(.playPause)
        return .result()
    }
}

struct NextTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "下一首"
    static var description = IntentDescription("跳到 Spotify 的下一首歌。")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await PlaybackIntentBridge.run(.next)
        return .result()
    }
}

struct PreviousTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "上一首"
    static var description = IntentDescription("回到上一首，或從頭播放目前這首。")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await PlaybackIntentBridge.run(.previous)
        return .result()
    }
}
