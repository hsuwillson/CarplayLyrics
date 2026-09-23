import Foundation

/// 即時動態每次更新帶的「接下來幾句」視窗（純邏輯，可測試）。
///
/// 背景更新被系統擋掉時，畫面只會在 staleDate 那一刻重畫一次（見 `LiveActivityStalePolicy`），
/// 之後就不會再變；而 CarPlay 儀表板就算 App 在前景、每句更新都被套用，也大約每分鐘才重畫一次
/// （build 45 實測）。把接下來幾句連同各自的起訖時刻一起送出去：
/// - 畫面任何一次重畫（staleDate、解鎖、CarPlay 重畫）都能算出那一刻正在唱哪一句，不只推進一句；
/// - 每句底下放系統自己推進的進度條（`ProgressView(timerInterval:)`），沒有任何更新也看得出唱到哪：
///   CarPlay 兩次重畫之間（~60 秒）就靠這些進度條當卡拉 OK 視窗；
/// - 背景被擋期間的探測更新間隔很疏（15–120 秒），一次送出的視窗要涵蓋到下一次探測之前。
struct LiveActivityWindowPolicy: Equatable, Sendable {
    /// 視窗涵蓋從現在起幾秒內會開始的句子（CarPlay 重畫間隔約 60 秒，留一點餘裕）
    var seconds: TimeInterval = 75
    /// 至少 / 最多帶幾句（時間窗內不夠時仍帶 `minLines` 句；太密時最多 `maxLines` 句：
    /// CarPlay 卡片放得下的列數有限、內容也有 4 KB 上限）
    var minLines = 2
    var maxLines = 6
    /// 每句最多幾個字（一列只顯示一行；中文一列約 20 字，超過的截斷加「…」，也守住 4 KB）
    var maxCharacters = 40

    /// - Parameters:
    ///   - lines: 整首歌的同步歌詞（依時間排序）
    ///   - currentIndex: 目前句（還沒到第一句時 nil）
    ///   - effectivePosition: 目前位置（秒，已含歌詞延遲）
    ///   - now: `effectivePosition` 成立的真實時刻
    ///   - songEnd: 歌曲結束的真實時刻（最後一句的結束時刻用）；未知時 nil
    /// - Returns: 目前句之後、有文字的句子（空白句不列，但它們仍決定前一句的結束時刻）
    func upcoming(lines: [LyricLine], currentIndex: Int?, effectivePosition: TimeInterval, now: Date,
                  songEnd: Date? = nil) -> [ActivityUpcomingLine] {
        let from = (currentIndex ?? -1) + 1
        guard from < lines.count else { return [] }
        let limit = effectivePosition + seconds
        var result: [ActivityUpcomingLine] = []
        for j in from..<lines.count {
            let line = lines[j]
            if line.text.isEmpty { continue }
            if result.count >= maxLines { break }
            if line.time >= limit, result.count >= minLines { break }
            let start = now.addingTimeInterval(line.time - effectivePosition)
            let end = j + 1 < lines.count ? now.addingTimeInterval(lines[j + 1].time - effectivePosition) : songEnd
            result.append(ActivityUpcomingLine(text: truncated(line.text), startAt: start,
                                               endAt: end.flatMap { $0 > start ? $0 : nil }))
        }
        return result
    }

    /// 超過 `maxCharacters` 的句子截斷加「…」（畫面一列只放一行，太長也只是被 SwiftUI 截掉）
    func truncated(_ text: String) -> String {
        guard text.count > maxCharacters, maxCharacters > 1 else { return text }
        return String(text.prefix(maxCharacters - 1)) + "…"
    }
}
