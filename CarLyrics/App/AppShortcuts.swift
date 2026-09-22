import AppIntents

/// 讓捷徑 / Siri 認得「用 CarLyrics 同步歌詞」；
/// 建議在捷徑 App 建立自動化「連接 CarPlay 時 → 開啟 CarLyrics」。
struct CarLyricsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenCarLyricsIntent(target: .lyrics),
                    phrases: ["用 \(.applicationName) 同步歌詞", "打開 \(.applicationName)"],
                    shortTitle: "同步歌詞",
                    systemImageName: "music.note.list")
        AppShortcut(intent: OpenCarLyricsIntent(target: .focus),
                    phrases: ["\(.applicationName) 專注模式"],
                    shortTitle: "專注模式",
                    systemImageName: "car.fill")
    }
}
