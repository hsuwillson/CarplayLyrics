import Foundation
import WidgetKit

/// 把整首歌的時間軸寫進 App Group，並在需要時請系統重新整理小工具。
/// - 重要事件（換歌、拖動、暫停、歌詞載入、調整延遲）：一定重新整理
/// - 換句：交給 `WidgetReloadPolicy` 決定（被系統節流時自動改用段落模式）
@MainActor
final class WidgetTimelinePublisher {
    private var lastSnapshot: LyricsTimelineSnapshot?
    private(set) var policy = WidgetReloadPolicy()
    private(set) var requestCount = 0
    private(set) var lastRequestAt: Date?
    /// 低耗電時停用逐句更新
    var lineReloadsEnabled = true
    private var loggedMode: LyricsTimelineMode = .perLine

    var mode: LyricsTimelineMode { policy.mode(now: Date()) }
    var renderCount: Int { LyricsTimelineStore.renderCount }
    var lastRenderAt: Date? { LyricsTimelineStore.lastRenderAt }

    var modeDescription: String {
        switch mode {
        case .perLine: return "逐句更新"
        case .paragraph:
            if let until = policy.disabledUntil {
                return "段落模式（系統節流，\(until.formatted(date: .omitted, time: .shortened)) 後再試）"
            }
            return "段落模式"
        }
    }

    /// 寫入新的時間軸；內容和上次相同就不重新整理
    func publish(_ snapshot: LyricsTimelineSnapshot) {
        var snapshot = snapshot
        snapshot.mode = mode
        if let last = lastSnapshot, last.isSameTimeline(as: snapshot) { return }
        lastSnapshot = snapshot
        guard LyricsTimelineStore.save(snapshot) else {
            debugLog("小工具時間軸寫入失敗（App Group 無法使用）")
            return
        }
        policy.recordImportant(now: Date())
        reload()
    }

    /// 換句時呼叫
    func lineChanged(isForeground: Bool) {
        guard lineReloadsEnabled, lastSnapshot?.isPlaying == true else { return }
        let now = Date()
        let allowed = policy.allowLineReload(now: now, isForeground: isForeground, renderCount: renderCount)
        let mode = policy.mode(now: now)
        if mode != loggedMode {
            loggedMode = mode
            if mode == .paragraph {
                debugLog("小工具逐句更新被系統節流，改用段落模式 30 分鐘")
            } else {
                debugLog("小工具恢復逐句更新")
            }
            // 模式改變 → 重寫時間軸（段落模式多顯示一句）
            if var s = lastSnapshot {
                s.mode = mode
                lastSnapshot = s
                LyricsTimelineStore.save(s)
                reload()
                return
            }
        }
        guard allowed else { return }
        reload()
        if requestCount % 50 == 0 {
            let lag = lastRenderAt.map { String(format: "%.1f", now.timeIntervalSince($0)) } ?? "—"
            debugLog("小工具：要求重新整理 \(requestCount) 次，系統實際執行 \(renderCount) 次，最後一次在 \(lag) 秒前")
        }
    }

    func appBecameActive() {
        policy.resetWindow()
    }

    private func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: LyricsTimelineStore.widgetKind)
        requestCount += 1
        lastRequestAt = Date()
    }
}
