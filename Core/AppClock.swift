import Foundation

/// 單調時鐘：以開機後經過時間推算「現在」，不受系統校時（NTP 修正、手動改時間）影響。
/// 同步引擎的所有時間點都用它，避免校時造成歌詞突然跳一下。
/// 需要真實時刻（例如交給小工具的時間軸）時用 `wallDate(for:)` 換算。
enum AppClock {
    private static let referenceDate = Date()
    private static let referenceUptime = monotonicSeconds()

    /// CLOCK_MONOTONIC：不受校時影響，裝置睡眠期間也持續前進
    static func monotonicSeconds() -> TimeInterval {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
    }

    static func now() -> Date {
        referenceDate.addingTimeInterval(monotonicSeconds() - referenceUptime)
    }

    /// 單調時鐘的某個時刻 → 目前系統時鐘上對應的時刻
    static func wallDate(for monotonic: Date) -> Date {
        Date().addingTimeInterval(monotonic.timeIntervalSince(now()))
    }
}
