import Foundation

/// 即時動態 `staleDate` 的選法，以及 stale 之後畫面該顯示什麼（純邏輯，App 與小工具 extension 共用）。
///
/// 背景更新被系統擋掉時，App 沒有任何辦法再改即時動態的內容；唯一免費的「時間到自動變化」是
/// `staleDate`：到時系統把 `isStale` 變成 true 並重畫一次（只有一次，之後不會再自己變）。
/// 所以每次更新都把 staleDate 設在「下一句開始 + 寬限」：
/// - 前景更新正常時，下一句的更新會先到並把 staleDate 往後推，畫面永遠不會 stale；
/// - 背景被擋時，下一句開始後寬限一到，畫面自己把「下一句」升成目前句（免費推進一次），
///   並標示「歌詞未更新」；歌曲播完後改顯示「打開 CarLyrics」，不把上一首掛著假裝還在同步。
struct LiveActivityStalePolicy: Equatable, Sendable {
    /// 換句後給系統套用更新的寬限（秒）：前景時系統多半 1 秒內套用，不會碰到；
    /// 背景被擋時最多晚這麼久才推進到下一句
    var grace: TimeInterval = 2
    /// 歌曲播完後的寬限（秒）：前景時換歌的更新要等輪詢回來（往返可能 1–2 秒）再加歌詞搜尋，
    /// 給寬一點，免得每首歌結尾都閃一下「打開 CarLyrics」；背景被擋時播完 6 秒後才改顯示提示
    var endGrace: TimeInterval = 6
    /// 沒有下一句、沒在播放、不知道時刻時：多久沒更新才算 stale（keepAlive 每 45 秒續期）
    var fallback: TimeInterval = 120
    /// staleDate 距離現在至少這麼久（下一句就在眼前時，避免一送出就 stale）
    var minimum: TimeInterval = 1
    /// stale 之後「免費推進一次」的有效時間窗（秒）：系統在這段時間內重畫才把下一句當成目前句，
    /// 更晚（例如解鎖時才重畫）就不知道唱到哪了，改顯示提示
    var advanceWindow: TimeInterval = 15

    /// stale 時畫面顯示什麼
    struct Display: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// 下一句已經開始：把下一句升成目前句
            case advanced
            /// 歌曲已播完：不顯示舊歌詞
            case songOver
            /// 推進時間窗已過：不知道唱到哪，只顯示提示
            case expired
            /// 還沒到下一句（暫停、沒有下一句、App 被終止）：維持原內容
            case unchanged
        }

        var kind: Kind
        var current: String
        var next: String
        /// 目前句之後的視窗（各自帶起訖時刻，畫面放系統自己推進的進度條）；沒有視窗的內容是空的
        var upcoming: [ActivityUpcomingLine] = []
        /// 由視窗升上來的目前句的起訖區間（畫面在它底下放系統推進的進度條）；不是從視窗來的就 nil
        var currentInterval: ClosedRange<Date>?

        init(kind: Kind, current: String, next: String, upcoming: [ActivityUpcomingLine] = [],
             currentInterval: ClosedRange<Date>? = nil) {
            self.kind = kind
            self.current = current
            self.next = next
            self.upcoming = upcoming
            self.currentInterval = currentInterval
        }
    }

    static let openAppLine = "打開 CarLyrics 繼續同步歌詞"
    static let expiredLine = "歌詞沒跟上"

    /// 下一句開始的真實時刻：有歌詞文字時是 `lineEndAt`，間奏時是倒數用的 `nextLineAt`
    static func nextLineStart(_ m: ActivityContentModel) -> Date? {
        m.lineEndAt ?? m.nextLineAt
    }

    /// 這次更新的 staleDate
    func staleDate(for m: ActivityContentModel, now: Date) -> Date {
        let latest = now.addingTimeInterval(fallback)
        guard m.isPlaying else { return latest }
        var candidates: [Date] = []
        if let next = Self.nextLineStart(m) { candidates.append(next.addingTimeInterval(grace)) }
        if let end = m.songEnd { candidates.append(end.addingTimeInterval(endGrace)) }
        guard let chosen = candidates.min() else { return latest }
        return min(max(chosen, now.addingTimeInterval(minimum)), latest)
    }

    /// 距離現在幾秒（記錄 / 診斷用）
    func staleInterval(for m: ActivityContentModel, now: Date) -> TimeInterval {
        staleDate(for: m, now: now).timeIntervalSince(now)
    }

    /// `isStale` 為 true 時畫面要顯示的內容（`now` = 畫面重畫的時刻）。
    /// 內容帶有視窗（`upcoming`）時，用視窗算出 `now` 正在唱哪一句；舊版內容只能推進一句。
    func display(for m: ActivityContentModel, now: Date) -> Display {
        if let end = m.songEnd, now >= end {
            return Display(kind: .songOver, current: Self.openAppLine, next: "")
        }
        let window = m.upcoming ?? []
        let unchanged = Display(kind: .unchanged, current: m.currentLine, next: m.nextLine, upcoming: window)
        guard m.isPlaying else { return unchanged }
        if !window.isEmpty { return windowDisplay(m, window: window, now: now, unchanged: unchanged) }
        guard let next = Self.nextLineStart(m), now >= next else { return unchanged }
        if now < next.addingTimeInterval(advanceWindow) {
            // 下一句是間奏（空白句）時顯示 ♪，和正常更新時一樣
            return Display(kind: .advanced, current: m.nextLine.isEmpty ? "♪" : m.nextLine, next: m.nextLine2 ?? "")
        }
        return Display(kind: .expired, current: Self.expiredLine, next: Self.openAppLine)
    }

    /// 有視窗：`now` 落在哪一句就顯示哪一句，之後的句子留在視窗裡（進度條由系統推進）
    private func windowDisplay(_ m: ActivityContentModel, window: [ActivityUpcomingLine], now: Date,
                               unchanged: Display) -> Display {
        guard let i = window.lastIndex(where: { $0.startAt <= now }) else {
            // 視窗第一句還沒開始：目前句唱完了就是間奏，否則維持原內容
            if let next = Self.nextLineStart(m), now >= next {
                return Display(kind: .advanced, current: "♪", next: window[0].text, upcoming: window)
            }
            return unchanged
        }
        let line = window[i]
        let rest = Array(window[(i + 1)...])
        // 這句的結束時刻：不知道時給推進時間窗的寬度
        let end = line.endAt ?? line.startAt.addingTimeInterval(advanceWindow)
        if now < end {
            return Display(kind: .advanced, current: line.text.isEmpty ? "♪" : line.text,
                           next: rest.first?.text ?? "", upcoming: rest, currentInterval: line.progressInterval)
        }
        if let following = rest.first {
            // 這句唱完、下一句還沒開始：間奏
            return Display(kind: .advanced, current: "♪", next: following.text, upcoming: rest)
        }
        // 視窗最後一句也唱完了：不知道唱到哪
        return Display(kind: .expired, current: Self.expiredLine, next: Self.openAppLine)
    }
}
