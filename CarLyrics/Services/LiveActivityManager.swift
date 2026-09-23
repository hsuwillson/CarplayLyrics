import ActivityKit
import Foundation
import UIKit

/// 管理歌詞即時動態（鎖定畫面、動態島、CarPlay）
///
/// - iOS 只允許 App 在前景時「開始」即時動態；背景失敗後就不再重試，等回到前景
/// - 更新依序送出（串成一條鏈），避免較舊的內容最後才到
/// - 每次更新帶 staleDate；App 被系統終止後，畫面會顯示「暫停更新」
/// - iOS 會擋掉只播背景音訊的 App 在背景的更新：連續被擋 5 次後，背景只在換歌 / 暫停時嘗試
/// - 接近 8 小時上限且 App 在前景時，自動重新開始一個
@MainActor
final class LiveActivityManager {
    typealias State = LyricsActivityAttributes.ContentState

    typealias Priority = LiveActivityUpdatePolicy.Priority

    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: State?
    private var chain: Task<Void, Never>?
    private var stateObserver: Task<Void, Never>?
    private var startBlockedUntilForeground = false

    private(set) var updateCount = 0
    private(set) var startedAt: Date?
    private(set) var lastUpdateAt: Date?
    private(set) var lastError: String?
    /// 送出後系統實際套用 / 沒有套用的次數
    private(set) var acceptedCount = 0
    private(set) var rejectedCount = 0
    private(set) var lastRejectedAt: Date?
    /// 最近一次判定「沒有被套用」時，是哪個欄位不同（診斷用）
    private(set) var lastMismatchField: String?
    /// 背景被擋期間累積、還沒送出的內容
    private var hasUnsentState = false
    /// 背景更新被系統擋掉（回前景時清除）
    private(set) var backgroundBlocked = false
    private var backgroundRejectStreak = 0
    private var loggedRejectionStreak = false
    private let policy = LiveActivityUpdatePolicy()

    /// 超過這個秒數沒更新，系統會把即時動態標成 stale
    private static let staleAfter: TimeInterval = 120
    /// 內容沒變時，每隔這麼久重送一次（延長 staleDate）
    var keepAliveInterval: TimeInterval = 45
    /// iOS 8 小時上限前 30 分鐘，在前景時自動換新
    private static let renewAfter: TimeInterval = 7.5 * 3600

    /// `.stale` 只是太久沒更新，仍然可以更新（更新後會回到 `.active`）
    var isActive: Bool {
        switch activity?.activityState {
        case .active, .stale: return true
        default: return false
        }
    }

    var stateDescription: String {
        guard let activity else { return startBlockedUntilForeground ? "未啟動（等回到前景）" : "未啟動" }
        switch activity.activityState {
        case .active: return backgroundBlocked ? "進行中（背景更新被系統暫停）" : "進行中"
        case .stale: return "暫停更新"
        case .ended: return "已結束"
        case .dismissed: return "已關閉"
        @unknown default: return "未知"
        }
    }

    private var isInBackground: Bool {
        UIApplication.shared.applicationState != .active
    }

    /// App 回到前景：解除封鎖、接手既有的即時動態、必要時換新
    func appBecameActive() {
        startBlockedUntilForeground = false
        if backgroundBlocked { debugLog("回到前景，恢復即時動態更新") }
        backgroundBlocked = false
        backgroundRejectStreak = 0
        let existing = Activity<LyricsActivityAttributes>.activities
        if activity == nil,
           let first = existing.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
            activity = first
            observe(first)
            debugLog("接手既有的即時動態")
        }
        for extra in existing where extra.id != activity?.id {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        if let startedAt, Date().timeIntervalSince(startedAt) > Self.renewAfter, let state = lastState {
            debugLog("即時動態接近 8 小時上限，自動換新")
            end()
            start(state)
        }
    }

    func update(_ model: ActivityContentModel, priority: Priority = .routine) {
        let state = State(model)
        let decision = policy.decide(.init(isActive: isActive,
                                           startBlockedUntilForeground: startBlockedUntilForeground,
                                           backgroundBlocked: backgroundBlocked,
                                           isInBackground: isInBackground,
                                           priority: priority,
                                           sameAsLast: state == lastState))
        switch decision {
        case .start:
            activity = nil
            lastState = nil
            start(state)
        case .send:
            guard let activity else { return }
            send(state, to: activity)
        case .store:
            // 被擋就不白做工；記住最新內容，回前景或下一次重要更新時送出
            lastState = state
            hasUnsentState = true
        case .skip:
            break
        }
    }

    /// 內容沒變也定期重送，避免被標成 stale（由輪詢迴圈呼叫）
    func keepAlive() {
        guard !backgroundBlocked || !isInBackground,
              isActive, let activity, let lastState, let lastUpdateAt,
              Date().timeIntervalSince(lastUpdateAt) > keepAliveInterval else { return }
        send(lastState, to: activity)
    }

    /// 回到前景時把最新內容送出（只在背景被擋期間累積過內容時）
    func flush() {
        guard hasUnsentState, isActive, let activity, let lastState else { return }
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
        debugLog("即時動態已結束")
    }

    // MARK: - 內部

    private func send(_ state: State, to activity: Activity<LyricsActivityAttributes>) {
        lastState = state
        hasUnsentState = false
        updateCount += 1
        lastUpdateAt = Date()
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            await activity.update(content)
            self?.verify(state, on: activity)
        }
    }

    /// 比對系統裡的內容，確認更新有沒有真的被套用（只記錄次數，不記錄歌詞）
    private func verify(_ state: State, on activity: Activity<LyricsActivityAttributes>) {
        let background = isInBackground
        let mismatch = activity.content.state.model.mismatchField(comparedTo: state.model)
        if mismatch == nil {
            acceptedCount += 1
            backgroundRejectStreak = 0
            if backgroundBlocked {
                backgroundBlocked = false
                debugLog("即時動態背景更新恢復")
            }
            if loggedRejectionStreak {
                loggedRejectionStreak = false
                debugLog("即時動態更新恢復正常（\(background ? "背景" : "前景")）")
            }
        } else {
            rejectedCount += 1
            lastRejectedAt = Date()
            lastMismatchField = mismatch
            if background {
                backgroundRejectStreak += 1
                if policy.shouldEnterBlocked(backgroundRejectStreak: backgroundRejectStreak), !backgroundBlocked {
                    backgroundBlocked = true
                    debugLog("即時動態背景更新被系統擋住，改為只在換歌 / 暫停時嘗試")
                }
            }
            if !loggedRejectionStreak {
                loggedRejectionStreak = true
                debugLog("即時動態更新沒有被系統套用（\(background ? "背景" : "前景")）")
            }
        }
        if (acceptedCount + rejectedCount) % 50 == 0 {
            debugLog("即時動態統計：套用 \(acceptedCount)、被擋 \(rejectedCount)")
        }
    }

    private func start(_ state: State) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "系統設定已關閉即時動態"
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
            debugLog("即時動態已開始")
        } catch {
            startBlockedUntilForeground = true
            lastError = error.localizedDescription
            debugLog("即時動態無法開始（回到前景會再試）：\(error.localizedDescription)")
        }
    }

    /// 使用者滑掉、或 8 小時上限到期 → 清掉參考，回前景時會重新開始
    private func observe(_ a: Activity<LyricsActivityAttributes>) {
        stateObserver?.cancel()
        stateObserver = Task { [weak self] in
            for await state in a.activityStateUpdates {
                guard let self else { return }
                if state == .dismissed || state == .ended {
                    debugLog("即時動態被關閉（\(state)）")
                    if self.activity?.id == a.id {
                        self.activity = nil
                        self.lastState = nil
                        // 背景時無法重新開始，等回到前景；前景則可以立刻換新
                        self.startBlockedUntilForeground = self.isInBackground
                    }
                }
            }
        }
    }
}
