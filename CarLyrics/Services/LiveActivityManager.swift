import ActivityKit
import Foundation
import UIKit

/// 管理歌詞即時動態（鎖定畫面、動態島、CarPlay）
///
/// - iOS 只允許 App 在前景時「開始」即時動態；背景失敗後就不再重試，等回到前景
/// - 更新依序送出（串成一條鏈），避免較舊的內容最後才到
/// - 每次更新帶 staleDate；App 被系統終止後，畫面會顯示「暫停更新」
/// - iOS 會擋掉只播背景音訊的 App 在背景的更新：連續被擋 8 次後，背景只在換歌 / 暫停時嘗試，
///   但每隔 15 秒仍放一次換句更新出去探測；一被套用就恢復逐句更新（系統只是慢、不是拒絕時能自癒）
/// - 接近 8 小時上限且 App 在前景時，自動重新開始一個
@MainActor
final class LiveActivityManager {
    typealias State = LyricsActivityAttributes.ContentState

    typealias Priority = LiveActivityUpdatePolicy.Priority

    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: State?
    private var chain: Task<Void, Never>?
    private var stateObserver: Task<Void, Never>?
    private var verifyTask: Task<Void, Never>?
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
    /// 送出後還沒來得及驗證就被更新的內容蓋掉的次數（診斷用）。
    /// 歌詞密集時大多數更新都驗不到，套用／被擋的數字才看得懂。
    private(set) var verifySkipped = 0
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
            // 不知道它是什麼時候開始的：保守當成現在，8 小時換新的時間從這裡起算
            startedAt = Date()
            observe(first)
            debugLog("接手既有的即時動態")
        }
        for extra in existing where extra.id != activity?.id {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        if let startedAt, Date().timeIntervalSince(startedAt) > Self.renewAfter, let state = lastState {
            end(reason: "接近 8 小時上限，自動換新")
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
                                           sameAsLast: isSameAsLast(state),
                                           secondsSinceLastSend: secondsSinceLastSend))
        switch decision {
        case .start:
            activity = nil
            lastState = nil
            start(state)
        case .send:
            guard let activity else { return }
            send(state, to: activity)
        case .store:
            // 被擋就不白做工；記住最新內容，回前景、下一次重要更新或下一次探測時送出
            lastState = state
            hasUnsentState = true
        case .skip:
            break
        }
    }

    /// 內容相同就不送：時間欄位（歌曲開始時刻、下一句時刻）每次重算會差幾毫秒，
    /// 用完全相等比較幾乎永遠不同，會多送很多次一樣的畫面
    private func isSameAsLast(_ state: State) -> Bool {
        guard let lastState else { return false }
        return state.model.isEquivalent(to: lastState.model, tolerance: 0.5)
    }

    private var secondsSinceLastSend: TimeInterval {
        lastUpdateAt.map { Date().timeIntervalSince($0) } ?? .infinity
    }

    /// 內容沒變也定期重送，避免被標成 stale（由輪詢迴圈呼叫）。
    /// 背景被擋期間也照送：間隔（45 秒）比探測間隔長，本身就是一次探測，
    /// 被套用就解除封鎖；不送的話長間奏時會被標成 stale、畫面變成「歌詞沒跟上」。
    func keepAlive() {
        guard isActive, let activity, let lastState,
              secondsSinceLastSend > keepAliveInterval else { return }
        send(lastState, to: activity)
    }

    /// 回到前景時把最新內容送出（只在背景被擋期間累積過內容時）
    func flush() {
        guard hasUnsentState, isActive, let activity, let lastState else { return }
        send(lastState, to: activity)
    }

    /// - Parameter reason: 寫進紀錄，事後看得出為什麼消失（閒置、下車、設定、登出…）
    func end(reason: String = "") {
        stateObserver?.cancel()
        stateObserver = nil
        verifyTask?.cancel()
        verifyTask = nil
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        let previous = chain
        chain = Task {
            await previous?.value
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let lived = startedAt.map { "，持續 \(Int(Date().timeIntervalSince($0) / 60)) 分鐘" } ?? ""
        debugLog("即時動態已結束（\(reason.isEmpty ? "未註明" : reason)\(lived)，套用 \(acceptedCount)／被擋 \(rejectedCount)／未驗證 \(verifySkipped)）")
    }

    // MARK: - 內部

    private func send(_ state: State, to activity: Activity<LyricsActivityAttributes>) {
        lastState = state
        hasUnsentState = false
        updateCount += 1
        lastUpdateAt = Date()
        // 送出當下是不是在背景：驗證要等 2 秒，期間可能剛好鎖了螢幕，
        // 前景送的更新不能因為驗證時已在背景就算成「背景被擋」
        let background = isInBackground
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            await activity.update(content)
            // 驗證不放進鏈裡：它要等一下才準，放進來會拖慢下一次更新
            self?.scheduleVerify(state, on: activity, background: background)
        }
    }

    /// ActivityKit 是非同步套用的：`activity.content` 不會在 `update()` 回來的當下就變新，
    /// 立刻比對會把正常的更新誤判成「被系統擋住」，進而關掉逐句更新（歌詞就不動了）。
    /// 所以延遲一下再比，不一致時再給一次機會；期間若已送出（或記住）更新的內容，
    /// 這次就不算，只記一筆「未驗證」。
    private func scheduleVerify(_ state: State, on activity: Activity<LyricsActivityAttributes>, background: Bool) {
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, self.lastState == state else { self?.verifySkipped += 1; return }
            if self.applied(state, on: activity) {
                self.record(mismatch: nil, background: background)
                return
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, self.lastState == state else { self.verifySkipped += 1; return }
            self.record(mismatch: activity.content.state.model.mismatchField(comparedTo: state.model),
                        background: background)
        }
    }

    private func applied(_ state: State, on activity: Activity<LyricsActivityAttributes>) -> Bool {
        activity.content.state.model.mismatchField(comparedTo: state.model) == nil
    }

    /// 比對結果 → 統計與「背景是否被擋」的判斷（只記錄次數，不記錄歌詞）
    /// - Parameter background: 送出當下是否在背景（不是驗證當下）
    private func record(mismatch: String?, background: Bool) {
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
                    debugLog("即時動態背景更新被系統擋住，改為只在換歌 / 暫停時嘗試（每 \(Int(policy.blockedProbeInterval)) 秒探測一次）")
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
                if state == .stale {
                    // 超過 staleDate 沒更新：鎖定畫面會顯示「歌詞沒跟上」
                    debugLog("即時動態變成 stale（\(self.lastUpdateAt.map { "上次更新 \(Int(Date().timeIntervalSince($0))) 秒前" } ?? "沒有更新紀錄")）")
                }
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
