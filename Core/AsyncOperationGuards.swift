import Foundation

/// A successful login and logout both invalidate work belonging to the previous session.
struct SessionGeneration: Equatable, Sendable {
    private var value: UInt64 = 0
    mutating func advance() { value &+= 1 }
}

/// Shared by automatic polling and immediate retries. Uses the caller's monotonic clock.
struct RequestCooldown: Sendable {
    private var deadline = Date.distantPast

    mutating func impose(seconds: TimeInterval, now: Date) {
        guard seconds.isFinite, seconds > 0 else { return }
        deadline = max(deadline, now.addingTimeInterval(seconds))
    }

    func remaining(at now: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }
}

enum LyricsSelectionPolicy {
    static func canApply(target: String?, current: String?) -> Bool {
        guard let target else { return false }
        return target == current
    }
}
