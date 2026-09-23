import Foundation
import os

/// 即時動態畫面實際被系統重畫的時刻（小工具 extension 寫、App 讀，透過 App Group）。
/// 決策 / 統計在 `LiveActivityRenderLog`；這裡只做「什麼時候寫檔」與存取：
/// - 畫面 body 每次評估都會呼叫，但 `LiveActivityRenderLog.minGap`（5 秒）內的呼叫直接返回，不碰 UserDefaults
/// - 真的記下時只寫一個小陣列（最多 40 個時間戳）；寫的東西畫面不讀，不會造成重畫迴圈
/// - extension 程序內用鎖保護記憶體裡的紀錄（View body 不是 actor）
enum LiveActivityRenderStore {
    /// 即時動態的呈現位置（`activityFamily`）
    enum Family: String, CaseIterable, Sendable {
        /// CarPlay 儀表板 / Apple Watch（`.small`）
        case small
        /// 鎖定畫面（`.medium`）
        case lockScreen

        var label: String {
            switch self {
            case .small: return "CarPlay 重畫間隔（small）"
            case .lockScreen: return "鎖定畫面重畫間隔"
            }
        }
    }

    private static let logs = OSAllocatedUnfairLock(initialState: [Family: LiveActivityRenderLog]())

    private static func key(_ family: Family) -> String { "liveActivityRender." + family.rawValue }

    /// 由即時動態畫面的 body 呼叫（extension 程序）
    static func recordRender(family: Family, now: Date = Date()) {
        let changed: LiveActivityRenderLog? = logs.withLock { table in
            var log = table[family] ?? load(family)
            guard log.record(now: now) else { return nil }
            table[family] = log
            return log
        }
        guard let changed, let d = AppGroup.defaults else { return }
        d.set(changed.times.map(\.timeIntervalSince1970), forKey: key(family))
    }

    /// App 讀（診斷頁 / 診斷報告）
    static func load(_ family: Family) -> LiveActivityRenderLog {
        let raw = AppGroup.defaults?.array(forKey: key(family)) as? [Double] ?? []
        return LiveActivityRenderLog(times: raw.map { Date(timeIntervalSince1970: $0) })
    }

    /// 「重設統計」
    static func reset() {
        guard let d = AppGroup.defaults else { return }
        for family in Family.allCases { d.removeObject(forKey: key(family)) }
    }
}
