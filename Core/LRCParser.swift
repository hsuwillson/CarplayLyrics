import Foundation

/// 一行同步歌詞
struct LyricLine: Codable, Equatable, Sendable {
    /// 開始時間（秒）
    let time: TimeInterval
    let text: String
}

/// LRC 格式解析器
/// - 支援 `[mm:ss]`、`[mm:ss.x]`、`[mm:ss.xx]`、`[mm:ss.xxx]`、`[mm:ss:xx]`
/// - 支援一行多個時間碼：`[00:10.00][00:40.00]同一句`
/// - 支援 `[offset:+500]`（毫秒；正值代表歌詞提早出現）
/// - 忽略 `[ar:]`、`[ti:]` 等 metadata 標籤
enum LRCParser {
    static func parse(_ lrc: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var result: [LyricLine] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var times: [TimeInterval] = []

            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = parseTimestamp(tag) {
                    times.append(t)
                } else if let o = parseOffset(tag) {
                    offset = o
                }
                rest = rest[rest.index(after: close)...]
            }

            guard !times.isEmpty else { continue }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in times {
                result.append(LyricLine(time: t, text: text))
            }
        }

        // offset 標籤可能出現在任何位置，最後統一套用
        return result
            .map { LyricLine(time: max(0, $0.time - offset), text: $0.text) }
            .sorted { $0.time < $1.time }
    }

    /// "mm:ss.xx" → 秒
    static func parseTimestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0]), minutes >= 0 else { return nil }

        let secondsPart: Substring
        var fraction: Substring = ""
        if parts.count == 3 {                // mm:ss:xx
            secondsPart = parts[1]
            fraction = parts[2]
        } else if let dot = parts[1].firstIndex(of: ".") {
            secondsPart = parts[1][..<dot]
            fraction = parts[1][parts[1].index(after: dot)...]
        } else {
            secondsPart = parts[1]
        }

        guard let seconds = Int(secondsPart), (0..<60).contains(seconds),
              fraction.allSatisfy(\.isNumber) else { return nil }
        let frac = fraction.isEmpty ? 0 : (Double("0." + fraction) ?? 0)
        return Double(minutes * 60 + seconds) + frac
    }

    /// "offset:+500" → 0.5 秒
    static func parseOffset(_ tag: Substring) -> TimeInterval? {
        let lower = tag.lowercased()
        guard lower.hasPrefix("offset:") else { return nil }
        let value = lower.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)
        guard let ms = Double(value) else { return nil }
        return ms / 1000
    }
}

extension Array where Element == LyricLine {
    /// 找出在 `time` 秒時正在顯示的那一句（二分搜尋）。還沒到第一句時回傳 nil。
    func index(at time: TimeInterval) -> Int? {
        var lo = 0, hi = count - 1, found: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if self[mid].time <= time {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }
}
