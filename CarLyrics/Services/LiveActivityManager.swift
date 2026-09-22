import ActivityKit
import Foundation

/// 管理歌詞 Live Activity（鎖定畫面、靈動島、CarPlay）
///
/// - iOS 只允許 App 在前景時「開始」Live Activity；背景失敗後就不再重試，等回到前景
/// - 更新依序送出（串成一條鏈），避免較舊的內容最後才到
/// - 每次更新帶 staleDate；App 被系統終止後，Widget 會顯示「未更新」
@MainActor
final class LiveActivityManager {
    typealias State = LyricsActivityAttributes.ContentState

    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: State?
    private var chain: Task<Void, Never>?
    private var stateObserver: Task<Void, Never>?
    private var startBlockedUntilForeground = false

    private(set) var updateCount = 0
    private(set) var startedAt: Date?
    private(set) var lastUpdateAt: Date?
    private(set) var lastError: String?

    /// 超過這個秒數沒更新，系統會把 Live Activity 標成 stale
    private static let staleAfter: TimeInterval = 90
    /// 內容沒變時，每隔這麼久重送一次（延長 staleDate）
    private static let keepAliveInterval: TimeInterval = 45

    /// `.stale` 只是太久沒更新，仍然可以更新（更新後會回到 `.active`）
    var isActive: Bool {
        switch activity?.activityState {
        case .active, .stale: return true
        default: return false
        }
    }

    var stateDescription: String {
        guard let activity else { return startBlockedUntilForeground ? "未啟動（等回到前景）" : "未啟動" }
        return "\(activity.activityState)"
    }

    /// App 回到前景：解除封鎖、接手既有的 Live Activity
    func appBecameActive() {
        startBlockedUntilForeground = false
        let existing = Activity<LyricsActivityAttributes>.activities
        if activity == nil,
           let first = existing.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
            activity = first
            observe(first)
            debugLog("接手既有的 Live Activity")
        }
        for extra in existing where extra.id != activity?.id {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func update(_ state: State) {
        guard isActive, let activity else {
            self.activity = nil
            lastState = nil
            guard !startBlockedUntilForeground else { return }
            start(state)
            return
        }
        guard state != lastState else { return }
        send(state, to: activity)
    }

    /// 內容沒變也定期重送，避免被標成 stale（由輪詢迴圈呼叫）
    func keepAlive() {
        guard isActive, let activity, let lastState, let lastUpdateAt,
              Date().timeIntervalSince(lastUpdateAt) > Self.keepAliveInterval else { return }
        send(lastState, to: activity)
    }

    func end() {
        stateObserver?.cancel()
        stateObserver = nil
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        let previous = chain
        chain = Task {
            await previous?.value
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        debugLog("Live Activity 已結束")
    }

    // MARK: - 內部

    private func send(_ state: State, to activity: Activity<LyricsActivityAttributes>) {
        lastState = state
        updateCount += 1
        lastUpdateAt = Date()
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
        let previous = chain
        chain = Task {
            await previous?.value
            await activity.update(content)
        }
    }

    private func start(_ state: State) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "使用者已關閉 Live Activities"
            return
        }
        do {
            let new = try Activity.request(
                attributes: LyricsActivityAttributes(sessionID: UUID().uuidString),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter)),
                pushType: nil
            )
            activity = new
            lastState = state
            startedAt = Date()
            lastUpdateAt = Date()
            lastError = nil
            observe(new)
            debugLog("Live Activity 已開始")
        } catch {
            startBlockedUntilForeground = true
            lastError = error.localizedDescription
            debugLog("Live Activity 無法開始（回到前景會再試）：\(error.localizedDescription)")
        }
    }

    /// 使用者滑掉、或 8 小時上限到期 → 清掉參考，回前景時會重新開始
    private func observe(_ a: Activity<LyricsActivityAttributes>) {
        stateObserver?.cancel()
        stateObserver = Task { [weak self] in
            for await state in a.activityStateUpdates {
                guard let self else { return }
                if state == .dismissed || state == .ended {
                    debugLog("Live Activity 被關閉（\(state)）")
                    if self.activity?.id == a.id {
                        self.activity = nil
                        self.lastState = nil
                        // 背景時無法重新開始，等回到前景
                        self.startBlockedUntilForeground = true
                    }
                }
            }
        }
    }
}
