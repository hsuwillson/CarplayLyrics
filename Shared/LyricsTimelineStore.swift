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
    /// 系統這次重新整理距離 App 最後寫入時間軸多久（秒）：看得出系統多晚才執行 reload
    private static let renderLagKey = "widgetRenderLag"
    private static let renderLagMaxKey = "widgetRenderLagMax"
    /// 最近一次重新整理時，時間軸產生了幾格、第一格是第幾句（診斷用）
    private static let renderEntriesKey = "widgetRenderEntries"
    private static let renderFirstIndexKey = "widgetRenderFirstIndex"

    /// 距離 App 寫入超過這麼久的重新整理，多半是系統自己排的（不是 App 要求的），不算進「最大延遲」
    static let renderLagMeasureLimit: TimeInterval = 300

    /// 小工具每次被系統要時間軸時呼叫。
    /// - Parameters:
    ///   - snapshotUpdatedAt: App 最後寫入時間軸的時刻（有的話順便記錄「要求 → 實際重新整理」的延遲）
    ///   - entryCount: 這次交給系統幾格
    ///   - firstIndex: 第一格是第幾句（nil = 間奏 / 沒在播放）
    static func recordRender(snapshotUpdatedAt: Date? = nil, entryCount: Int? = nil, firstIndex: Int? = nil,
                             now: Date = Date()) {
        guard let d = AppGroup.defaults else { return }
        d.set(d.integer(forKey: renderCountKey) + 1, forKey: renderCountKey)
        d.set(now.timeIntervalSince1970, forKey: renderAtKey)
        if let updatedAt = snapshotUpdatedAt {
            let lag = max(0, now.timeIntervalSince(updatedAt))
            d.set(lag, forKey: renderLagKey)
            if lag <= renderLagMeasureLimit, lag > d.double(forKey: renderLagMaxKey) {
                d.set(lag, forKey: renderLagMaxKey)
            }
        }
        if let entryCount { d.set(entryCount, forKey: renderEntriesKey) }
        // -1 = 沒有目前句（間奏、沒在播放）
        d.set(firstIndex ?? -1, forKey: renderFirstIndexKey)
    }

    static var renderCount: Int { AppGroup.defaults?.integer(forKey: renderCountKey) ?? 0 }

    static var lastRenderAt: Date? {
        guard let t = AppGroup.defaults?.double(forKey: renderAtKey), t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// 最近一次「App 寫入 → 系統實際重新整理」的延遲（秒）；還沒量到時 nil
    static var lastRenderLag: TimeInterval? {
        guard let d = AppGroup.defaults, d.object(forKey: renderLagKey) != nil else { return nil }
        return d.double(forKey: renderLagKey)
    }

    /// 量到過的最大延遲（只算 `renderLagMeasureLimit` 內的）；還沒量到時 nil
    static var maxRenderLag: TimeInterval? {
        guard let d = AppGroup.defaults, d.object(forKey: renderLagMaxKey) != nil else { return nil }
        return d.double(forKey: renderLagMaxKey)
    }

    /// 最近一次重新整理交給系統的格數；還沒量到時 nil
    static var lastRenderEntryCount: Int? {
        guard let d = AppGroup.defaults, d.object(forKey: renderEntriesKey) != nil else { return nil }
        return d.integer(forKey: renderEntriesKey)
    }

    /// 最近一次重新整理時第一格是第幾句；nil = 間奏 / 沒在播放 / 還沒量到
    static var lastRenderFirstIndex: Int? {
        guard let d = AppGroup.defaults, d.object(forKey: renderFirstIndexKey) != nil else { return nil }
        let i = d.integer(forKey: renderFirstIndexKey)
        return i >= 0 ? i : nil
    }

    /// 小工具從來沒有被系統畫過：多半是根本沒加到任何畫面（CarPlay 小工具頁、主畫面、鎖定畫面）
    static var neverRendered: Bool { renderCount == 0 && lastRenderAt == nil }

    /// 清掉延遲統計（次數與最後時間保留，因為節流判定要用）
    static func resetRenderLagStats() {
        guard let d = AppGroup.defaults else { return }
        d.removeObject(forKey: renderLagKey)
        d.removeObject(forKey: renderLagMaxKey)
        d.removeObject(forKey: renderEntriesKey)
        d.removeObject(forKey: renderFirstIndexKey)
    }

    static func load() -> LyricsTimelineSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LyricsTimelineSnapshot.self, from: data)
    }
}
