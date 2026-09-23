import Foundation
import WidgetKit

/// 時間軸的寫入端（正式版寫 App Group + 請系統重新整理；測試可替換）
protocol TimelineSink: Sendable {
    @discardableResult func save(_ snapshot: LyricsTimelineSnapshot) -> Bool
    func reload()
    var renderCount: Int { get }
    var lastRenderAt: Date? { get }
}

struct AppGroupTimelineSink: TimelineSink {
    @discardableResult
    func save(_ snapshot: LyricsTimelineSnapshot) -> Bool { LyricsTimelineStore.save(snapshot) }
    func reload() { WidgetCenter.shared.reloadTimelines(ofKind: LyricsTimelineStore.widgetKind) }
    var renderCount: Int { LyricsTimelineStore.renderCount }
    var lastRenderAt: Date? { LyricsTimelineStore.lastRenderAt }
}

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

    /// 小工具實際被系統重新整理的次數（小工具寫、App 讀，用來判斷換句要求有沒有被系統執行）
    private static let renderCountKey = "widgetTimelineCount"
    private static let renderAtKey = "widgetTimelineAt"

    static func recordRender() {
        guard let d = AppGroup.defaults else { return }
        d.set(d.integer(forKey: renderCountKey) + 1, forKey: renderCountKey)
        d.set(Date().timeIntervalSince1970, forKey: renderAtKey)
    }

    static var renderCount: Int { AppGroup.defaults?.integer(forKey: renderCountKey) ?? 0 }

    static var lastRenderAt: Date? {
        guard let t = AppGroup.defaults?.double(forKey: renderAtKey), t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static func load() -> LyricsTimelineSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LyricsTimelineSnapshot.self, from: data)
    }
}
