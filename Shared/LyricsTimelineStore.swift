import Foundation

/// 透過 App Group 在 App 與小工具之間傳遞歌詞時間軸
enum LyricsTimelineStore {
    static let widgetKind = "LyricsWidget"

    static var fileURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("lyrics-timeline.json")
    }

    @discardableResult
    static func save(_ snapshot: LyricsTimelineSnapshot) -> Bool {
        guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func load() -> LyricsTimelineSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LyricsTimelineSnapshot.self, from: data)
    }
}
