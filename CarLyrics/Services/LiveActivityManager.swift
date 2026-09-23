import ActivityKit
import Foundation
import UIKit

/// 管理歌詞即時動態（鎖定畫面、動態島、CarPlay）
///
/// - iOS 只允許 App 在前景時「開始」即時動態；背景失敗後就不再重試，等回到前景
/// - 更新依序送出（串成一條鏈），避免較舊的內容最後才到
/// - 每次更新帶 staleDate = 下一句開始 + 寬限（見 LiveActivityStalePolicy）：背景更新被擋時，
///   畫面到時會自己把下一句升成目前句一次並標示「歌詞未更新」；播完後改顯示「打開 CarLyrics」
/// - iOS 會擋掉只播背景音訊的 App 在背景的更新（liveactivitiesd：「only playing background media … forbidden」）：
///   連續被擋 8 次後進入「被擋」，背景只在換歌 / 暫停時嘗試，另外依 `LiveActivityCadencePolicy` 的節奏
///   （15 → 30 → 60 → 120 秒，被套用就加快）放探測出去；每一級的套用 / 被擋都分開統計，
///   讓實測紀錄能分辨「一律禁止」還是「太密才被擋」。每次送出的內容都帶接下來幾句的視窗，
///   疏疏的探測被套用時畫面也是對的那一段
/// - 剛進背景時申請一段背景任務（約 25 秒）：測試「只有背景音訊」以外的執行理由是否讓系統放行更新
/// - 每次送出都記在當時的執行理由底下（前景 / 音訊 / 背景任務 / 定位保活，見 `LiveActivityReasonStats`）：
///   定位保活實驗的結論就看「定位」那一格有沒有被套用
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
    /// 背景被擋期間累積、還沒送出的最新內容（`lastState` 永遠是「真的送出去過」的內容，
    /// 探測送出後的驗證才不會被 store 蓋掉而永遠驗不到）
    private var pendingState: State?
    /// 背景更新被系統擋掉（回前景時清除）
    private(set) var backgroundBlocked = false
    private var backgroundRejectStreak = 0
    private var loggedRejectionStreak = false
    private var policy = LiveActivityUpdatePolicy()
    let stalePolicy = LiveActivityStalePolicy()
    /// 背景被擋期間的探測節奏與各級統計（診斷用 `cadence.summary`）
    private(set) var cadence = LiveActivityCadencePolicy()
    /// 目前的探測間隔（秒）
    var probeInterval: TimeInterval { policy.blockedProbeInterval }
    /// 由 AppModel 維護：現在接著車用音訊嗎（開始即時動態時記進紀錄，看得出是上車前還是上車後開始的）
    var carConnected = false
    /// 目前這個即時動態是在接著車用音訊時開始的嗎（nil = 沒有即時動態）
    private(set) var startedInCar: Bool?
    /// 由 AppModel 維護：定位保活執行中（送出時記成「定位」理由）
    private(set) var locationActive = false
    /// 各執行理由的送出 / 套用 / 被擋（診斷用 `reasons.summary`）
    private(set) var reasons = LiveActivityReasonStats()
    /// 進背景後的背景任務（實驗：有背景任務時系統是否放行更新）
    private var graceTask = UIBackgroundTaskIdentifier.invalid
    private var graceTimer: Task<Void, Never>?
    private var graceStartedAt: Date?
    private var graceCounts: (accepted: Int, rejected: Int) = (0, 0)
    /// 最近一次背景任務期間的結果（診斷用）
    private(set) var lastGraceResult: String?
    /// 背景任務最多撐這麼久就自己結束（系統給的多半是 30 秒左右）
    var graceSeconds: TimeInterval = 25
    /// 最近一次送出時選的 staleDate 距離當時幾秒（診斷用）
    private(set) var lastStaleInterval: TimeInterval?
    /// 系統把即時動態標成 stale 的次數；其中「下一句已開始 → 畫面自己推進」的次數
    private(set) var staleCount = 0
    private(set) var staleAdvanceCount = 0
    private var lastStaleLogAt: Date?
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
        case .active: return backgroundBlocked ? "進行中（背景更新被系統擋住，每 \(Int(probeInterval)) 秒探測）" : "進行中"
        case .stale:
            return backgroundBlocked ? "畫面停在上次套用的內容（背景更新被系統擋住）" : "暫停更新（等下一次更新）"
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
        endGrace(reason: "回到前景")
        startBlockedUntilForeground = false
        if backgroundBlocked { debugLog("回到前景，恢復即時動態更新（背景統計：\(cadence.summary)）") }
        backgroundBlocked = false
        backgroundRejectStreak = 0
        let existing = Activity<LyricsActivityAttributes>.activities
        if activity == nil,
           let first = existing.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
            activity = first
            // 不知道它是什麼時候開始的：保守當成現在，8 小時換新的時間從這裡起算
            startedAt = Date()
            observe(first)
            startedInCar = nil
            debugLog("接手既有的即時動態（狀態 \(first.activityState)，CarPlay \(carConnected ? "已連接" : "未連接")）")
        }
        for extra in existing where extra.id != activity?.id {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        if let startedAt, Date().timeIntervalSince(startedAt) > Self.renewAfter, let state = lastState {
            end(reason: "接近 8 小時上限，自動換新")
            start(state)
        }
    }

    /// 定位保活開始 / 停止：開始時解除「背景被擋」，讓逐句更新在新的執行理由下重新嘗試
    /// （否則要等探測慢慢加快才會恢復逐句，實驗結果會被拖慢好幾十秒）
    func locationKeepAliveChanged(active: Bool) {
        guard active != locationActive else { return }
        locationActive = active
        if active, backgroundBlocked {
            backgroundBlocked = false
            backgroundRejectStreak = 0
            debugLog("定位保活開始：解除背景被擋，重新嘗試逐句更新")
        }
    }

    /// App 進入背景：申請一段背景任務。iOS 擋掉的是「只有背景音訊」的程序（liveactivitiesd 的紀錄原文），
    /// 有背景任務撐著的這 25 秒若更新被套用，就證實是執行理由的問題、而不是頻率；
    /// 也順便讓鎖定後的前幾句還能更新。系統到期或時間到就結束，不會延長背景執行
    func appEnteredBackground() {
        guard isActive, graceTask == .invalid else { return }
        // expirationHandler 是 @MainActor @Sendable（系統在主執行緒同步呼叫）
        let id = UIApplication.shared.beginBackgroundTask(withName: "CarLyrics.LiveActivityGrace") { [weak self] in
            self?.endGrace(reason: "系統到期")
        }
        guard id != .invalid else {
            debugLog("背景任務：系統不給（即時動態更新只靠背景音訊）")
            return
        }
        graceTask = id
        graceStartedAt = Date()
        graceCounts = (acceptedCount, rejectedCount)
        debugLog("背景任務：開始（最多 \(Int(graceSeconds)) 秒，觀察這段時間的即時動態更新是否被套用）")
        graceTimer?.cancel()
        graceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.graceSeconds ?? 25))
            guard !Task.isCancelled else { return }
            self?.endGrace(reason: "時間到")
        }
    }

    private func endGrace(reason: String) {
        graceTimer?.cancel()
        graceTimer = nil
        guard graceTask != .invalid else { return }
        let id = graceTask
        graceTask = .invalid
        UIApplication.shared.endBackgroundTask(id)
        let seconds = graceStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let accepted = acceptedCount - graceCounts.accepted
        let rejected = rejectedCount - graceCounts.rejected
        lastGraceResult = "\(seconds) 秒：套用 \(accepted)／被擋 \(rejected)（\(reason)）"
        debugLog("背景任務：結束（\(lastGraceResult ?? "")）")
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
            pendingState = state
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
    /// 背景被擋期間也照送（送的是累積的最新內容），算成一次探測；
    /// 不送的話長間奏時會被標成 stale、畫面變成「歌詞沒跟上」。
    func keepAlive() {
        // 被擋期間照節奏政策的間隔來（放慢到 60 / 120 秒時，不要被 45 秒的 keep-alive 蓋掉）
        let interval = backgroundBlocked && isInBackground ? max(keepAliveInterval, probeInterval) : keepAliveInterval
        guard isActive, let activity, let state = pendingState ?? lastState,
              secondsSinceLastSend > interval else { return }
        send(state, to: activity)
    }

    /// 回到前景時把最新內容送出（只在背景被擋期間累積過內容時）
    func flush() {
        guard let pendingState, isActive, let activity else { return }
        send(pendingState, to: activity)
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
        pendingState = nil
        startedInCar = nil
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
        pendingState = nil
        updateCount += 1
        let now = Date()
        lastUpdateAt = now
        // 送出當下是不是在背景：驗證要等 2 秒，期間可能剛好鎖了螢幕，
        // 前景送的更新不能因為驗證時已在背景就算成「背景被擋」
        let background = isInBackground
        // 被擋期間送出的都是探測（換句探測、換歌、keep-alive）：算進目前這一級的統計
        let probe = background && backgroundBlocked
        if probe {
            cadence.recordProbeSent()
        } else if background {
            cadence.recordPerLineSent()
        }
        let reason = LiveActivityBackgroundReason.current(background: background, locationActive: locationActive,
                                                          backgroundTask: graceTask != .invalid)
        reasons.recordSent(reason)
        let content = ActivityContent(state: state, staleDate: staleDate(for: state, now: now))
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            await activity.update(content)
            // 驗證不放進鏈裡：它要等一下才準，放進來會拖慢下一次更新
            self?.scheduleVerify(state, on: activity, background: background, probe: probe, reason: reason)
        }
    }

    /// ActivityKit 是非同步套用的：`activity.content` 不會在 `update()` 回來的當下就變新，
    /// 立刻比對會把正常的更新誤判成「被系統擋住」，進而關掉逐句更新（歌詞就不動了）。
    /// 所以延遲一下再比，不一致時再給一次機會；期間若已送出（或記住）更新的內容，
    /// 這次就不算，只記一筆「未驗證」。
    private func scheduleVerify(_ state: State, on activity: Activity<LyricsActivityAttributes>, background: Bool,
                                probe: Bool, reason: LiveActivityBackgroundReason) {
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, self.lastState == state else { self?.verifySkipped += 1; return }
            if self.applied(state, on: activity) {
                self.record(mismatch: nil, background: background, probe: probe, reason: reason, latency: 0.8)
                return
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, self.lastState == state else { self.verifySkipped += 1; return }
            self.record(mismatch: activity.content.state.model.mismatchField(comparedTo: state.model),
                        background: background, probe: probe, reason: reason, latency: 2.0)
        }
    }

    /// 這次內容的 staleDate（下一句開始 + 寬限；沒有下一句時 120 秒）
    private func staleDate(for state: State, now: Date) -> Date {
        let date = stalePolicy.staleDate(for: state.model, now: now)
        lastStaleInterval = date.timeIntervalSince(now)
        return date
    }

    private func applied(_ state: State, on activity: Activity<LyricsActivityAttributes>) -> Bool {
        activity.content.state.model.mismatchField(comparedTo: state.model) == nil
    }

    /// 比對結果 → 統計與「背景是否被擋」的判斷（只記錄次數，不記錄歌詞）
    /// - Parameters:
    ///   - background: 送出當下是否在背景（不是驗證當下）
    ///   - probe: 送出當下是被擋期間的探測（算進節奏統計）
    ///   - reason: 送出當下 App 的執行理由（前景 / 音訊 / 背景任務 / 定位）
    ///   - latency: 送出後幾秒驗證到結果
    private func record(mismatch: String?, background: Bool, probe: Bool, reason: LiveActivityBackgroundReason,
                        latency: TimeInterval) {
        let accepted = mismatch == nil
        reasons.record(reason, accepted: accepted)
        if accepted {
            acceptedCount += 1
            backgroundRejectStreak = 0
            if loggedRejectionStreak {
                loggedRejectionStreak = false
                debugLog("即時動態更新恢復正常（\(reason.label)）")
            }
        } else {
            rejectedCount += 1
            lastRejectedAt = Date()
            lastMismatchField = mismatch
            if !loggedRejectionStreak {
                loggedRejectionStreak = true
                debugLog("即時動態更新沒有被系統套用（\(reason.label)）")
            }
        }
        if probe {
            recordProbe(accepted: accepted, latency: latency)
        } else if background {
            cadence.recordPerLine(accepted: accepted, latency: latency)
            if !accepted {
                backgroundRejectStreak += 1
                if policy.shouldEnterBlocked(backgroundRejectStreak: backgroundRejectStreak), !backgroundBlocked {
                    backgroundBlocked = true
                    cadence.enterBlocked()
                    policy.blockedProbeInterval = cadence.interval
                    debugLog("即時動態背景更新被系統擋住，改為只在換歌 / 暫停時嘗試，每 \(Int(cadence.interval)) 秒探測一次（每次都帶接下來幾句的視窗）")
                }
            }
        }
        if (acceptedCount + rejectedCount) % 50 == 0 {
            debugLog("即時動態統計：套用 \(acceptedCount)、被擋 \(rejectedCount)；理由：\(reasons.summary)；背景節奏：\(cadence.summary)")
        }
    }

    /// 被擋期間的探測結果：依節奏政策放慢 / 加快，最快一級也穩定被套用才恢復逐句
    private func recordProbe(accepted: Bool, latency: TimeInterval) {
        // 驗證期間可能已回到前景並解除封鎖：那就只記統計，不再調節奏
        let change = cadence.record(accepted: accepted, latency: latency)
        guard backgroundBlocked else { return }
        switch change {
        case .none:
            break
        case .slower(let interval):
            policy.blockedProbeInterval = interval
            debugLog("即時動態背景探測仍被擋，放慢到每 \(Int(interval)) 秒（\(cadence.summary)）")
        case .faster(let interval):
            policy.blockedProbeInterval = interval
            debugLog("即時動態背景探測被套用，加快到每 \(Int(interval)) 秒（\(cadence.summary)）")
        case .resumePerLine:
            backgroundBlocked = false
            backgroundRejectStreak = 0
            debugLog("即時動態背景更新恢復逐句（\(cadence.summary)）")
        }
    }

    private func start(_ state: State) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "系統設定已關閉即時動態"
            return
        }
        do {
            let now = Date()
            let new = try Activity.request(
                attributes: LyricsActivityAttributes(sessionID: UUID().uuidString),
                content: ActivityContent(state: state, staleDate: staleDate(for: state, now: now)),
                pushType: nil
            )
            activity = new
            lastState = state
            pendingState = nil
            startedAt = now
            lastUpdateAt = now
            lastError = nil
            startedInCar = carConnected
            observe(new)
            let carText = carConnected ? "已連接" : "未連接"
            let phaseText = isInBackground ? "背景" : "前景"
            debugLog("即時動態已開始（staleDate \(Int(lastStaleInterval ?? 0)) 秒後；CarPlay \(carText)；\(phaseText)）")
        } catch {
            startBlockedUntilForeground = true
            lastError = error.localizedDescription
            debugLog("即時動態無法開始（回到前景會再試）：\(error.localizedDescription)")
        }
    }

    /// 超過 staleDate 沒更新（背景被擋時每句都會發生一次；前景時只有系統套用慢於寬限才會）。
    /// 畫面那邊會依 `LiveActivityStalePolicy.display` 自己推進一次；這裡只記次數，
    /// 紀錄檔最多每 60 秒一行，免得被擋期間每 3 秒洗一行
    private func recordStale() {
        staleCount += 1
        let now = Date()
        let display = lastState.map { stalePolicy.display(for: $0.model, now: now) }
        if display?.kind == .advanced { staleAdvanceCount += 1 }
        if let last = lastStaleLogAt, now.timeIntervalSince(last) < 60 { return }
        lastStaleLogAt = now
        let kind: String
        switch display?.kind {
        case .advanced?: kind = "畫面自己推進到下一句"
        case .songOver?: kind = "歌曲已播完，改顯示打開 CarLyrics"
        case .expired?: kind = "推進時間窗已過，改顯示提示"
        case .unchanged?, nil: kind = "維持原內容"
        }
        let since = lastUpdateAt.map { "上次送出 \(Int(now.timeIntervalSince($0))) 秒前" } ?? "沒有送出紀錄"
        debugLog("即時動態 stale（\(kind)；\(since)；\(isInBackground ? "背景" : "前景")；累計 \(staleCount) 次）")
    }

    /// 使用者滑掉、或 8 小時上限到期 → 清掉參考，回前景時會重新開始
    private func observe(_ a: Activity<LyricsActivityAttributes>) {
        stateObserver?.cancel()
        stateObserver = Task { [weak self] in
            for await state in a.activityStateUpdates {
                guard let self else { return }
                if state == .stale { self.recordStale() }
                if state == .dismissed || state == .ended {
                    debugLog("即時動態被關閉（\(state)）")
                    if self.activity?.id == a.id {
                        self.activity = nil
                        self.lastState = nil
                        self.pendingState = nil
                        self.startedInCar = nil
                        // 背景時無法重新開始，等回到前景；前景則可以立刻換新
                        self.startBlockedUntilForeground = self.isInBackground
                    }
                }
            }
        }
    }
}
