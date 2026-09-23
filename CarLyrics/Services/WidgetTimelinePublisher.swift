import Foundation

/// 把整首歌的時間軸寫進 App Group，並在需要時請系統重新整理小工具。
/// - 重要事件（換歌、拖動、暫停、歌詞載入、調整延遲）：一定重新整理
/// - 換句：交給 `WidgetReloadPolicy` 決定（被系統節流時自動改用段落模式）
@MainActor
final class WidgetTimelinePublisher {
    private let sink: TimelineSink

    init(sink: TimelineSink = AppGroupTimelineSink()) {
        self.sink = sink
    }

    private var lastSnapshot: LyricsTimelineSnapshot?
    private var pending: LyricsTimelineSnapshot?
    private var pendingTask: Task<Void, Never>?
    private(set) var policy = WidgetReloadPolicy()
    private(set) var requestCount = 0
    private(set) var lastRequestAt: Date?
    /// 低耗電時停用逐句更新
    var lineReloadsEnabled = true
    private var loggedMode: LyricsTimelineMode = .perLine

    var mode: LyricsTimelineMode { policy.mode(now: Date()) }
    var renderCount: Int { sink.renderCount }
    var lastRenderAt: Date? { sink.lastRenderAt }
    /// 小工具從來沒有被系統畫過：多半是根本沒加到任何畫面上（這時候不做節流判定）
    var neverRendered: Bool { renderCount == 0 && lastRenderAt == nil }

    var modeDescription: String {
        if neverRendered { return "小工具尚未加入（沒有任何小工具在顯示）" }
        switch mode {
        case .perLine: return "逐句更新"
        case .paragraph:
            if let until = policy.disabledUntil {
                return "段落模式（系統節流，\(until.formatted(date: .omitted, time: .shortened)) 後再試）"
            }
            return "段落模式"
        }
    }

    /// 寫入新的時間軸；內容和上次相同就不重新整理。
    /// `debounce` = true 時把換歌前後幾次連續更新（搜尋中 → 歌詞 → 封面）合併成一次。
    func publish(_ snapshot: LyricsTimelineSnapshot, debounce: Bool = false) {
        var snapshot = snapshot
        snapshot.mode = mode
        if let last = lastSnapshot, last.isSameTimeline(as: snapshot) { return }
        guard debounce else {
            pendingTask?.cancel()
            pendingTask = nil
            write(snapshot, reloadSystem: true)
            return
        }
        pending = snapshot
        guard pendingTask == nil else { return }
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, let snapshot = self.pending else { return }
            self.pending = nil
            self.pendingTask = nil
            if let last = self.lastSnapshot, last.isSameTimeline(as: snapshot) { return }
            self.write(snapshot, reloadSystem: true)
        }
    }

    /// 只有起點漂移（歌詞、狀態都沒變）→ 重寫檔案讓小工具下次讀到正確時間，不佔用重新整理額度
    func refreshFile(_ snapshot: LyricsTimelineSnapshot) {
        var snapshot = snapshot
        snapshot.mode = mode
        guard let last = lastSnapshot, snapshot.needsFileRefresh(comparedTo: last) else { return }
        write(snapshot, reloadSystem: false)
    }

    private func write(_ snapshot: LyricsTimelineSnapshot, reloadSystem: Bool) {
        // 寫檔失敗時不要更新 lastSnapshot，否則之後內容相同就再也不會重試
        guard sink.save(snapshot) else {
            debugLog("小工具時間軸寫入失敗（App Group 無法使用）")
            return
        }
        lastSnapshot = snapshot
        guard reloadSystem else { return }
        policy.recordImportant(now: Date())
        reload()
    }

    /// 換句時呼叫
    func lineChanged(isForeground: Bool) {
        guard lineReloadsEnabled, lastSnapshot?.isPlaying == true else { return }
        let now = Date()
        let allowed = policy.allowLineReload(now: now, isForeground: isForeground, renderCount: renderCount,
                                             neverRendered: neverRendered)
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
                sink.save(s)
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
        sink.reload()
        requestCount += 1
        lastRequestAt = Date()
    }
}
