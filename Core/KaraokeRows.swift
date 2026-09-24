import Foundation

/// 卡拉 OK 視窗的一列：歌詞 + 這句唱的區間（畫面上用系統自己推進的進度條顯示）
struct KaraokeRow: Equatable, Sendable {
    let text: String
    let start: Date
    let end: Date

    var interval: ClosedRange<Date> { start...end }
}

/// CarPlay 小工具頁的歌詞小工具（實測約一分鐘才重畫一次）：與其只放「目前句 + 下一句」然後卡一分鐘，
/// 不如列出接下來一分多鐘會唱的句子，每句底下一條系統推進的進度條（空的＝還沒到、在走＝正在唱、滿的＝唱過了），
/// 兩次重畫之間看哪一條在動就知道唱到哪一句。
extension LyricsTimelineSnapshot {
    /// 視窗涵蓋從現在起幾秒內會開始的句子（CarPlay 重畫約 60 秒一次，留一點餘裕）
    static let karaokeWindow: TimeInterval = 75
    /// 最多列幾句（實際放得下幾句由畫面的 ViewThatFits 決定）
    static let karaokeMaxRows = 6
    /// 最後一句不知道何時結束（也不知道歌曲長度）時，假設唱幾秒
    static let karaokeLastLine: TimeInterval = 6

    /// 從 `date` 正在唱的句子（還沒開始唱就從第一句）開始，列出 `window` 秒內會開始的句子，每句帶起訖時刻。
    /// 空白句（間奏）不列，但它的開始就是前一句的結束。沒在播放、沒有同步歌詞時是空的。
    func karaokeRows(at date: Date, window: TimeInterval = karaokeWindow,
                     maxRows: Int = karaokeMaxRows) -> [KaraokeRow] {
        guard isPlaying, !lines.isEmpty, maxRows > 0 else { return [] }
        let windowEnd = date.addingTimeInterval(window)
        var rows: [KaraokeRow] = []
        var i = lines.index(at: date.timeIntervalSince(songStart)) ?? 0
        while i < lines.count, rows.count < maxRows {
            let start = songStart.addingTimeInterval(lines[i].time)
            // 至少列一句；之後超出時間窗就停
            if start > windowEnd, !rows.isEmpty { break }
            let end = max(start.addingTimeInterval(1), lineEnd(after: i, start: start))
            let text = lines[i].text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                rows.append(KaraokeRow(text: text, start: start, end: end))
            }
            i += 1
        }
        return rows
    }

    /// 第 `i` 句的結束：下一句開始；最後一句是歌曲結束（長度未知時唱 `karaokeLastLine` 秒）
    private func lineEnd(after i: Int, start: Date) -> Date {
        if i + 1 < lines.count { return songStart.addingTimeInterval(lines[i + 1].time) }
        guard duration > 0 else { return start.addingTimeInterval(Self.karaokeLastLine) }
        return songStart.addingTimeInterval(appliedOffset + duration)
    }
}
