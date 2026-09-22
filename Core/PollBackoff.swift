import Foundation

/// 網路錯誤時的指數退避：5 → 10 → 20 → 40 → 60 秒（上限）
enum PollBackoff {
    static func delay(forErrorStreak streak: Int, base: TimeInterval = 5, cap: TimeInterval = 60) -> TimeInterval {
        guard streak > 0 else { return base }
        let exponent = min(streak - 1, 10)
        return min(cap, base * pow(2, Double(exponent)))
    }
}
