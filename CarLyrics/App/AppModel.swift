import ActivityKit
import Foundation
import SwiftUI
import UIKit

/// 協調者：串接 Spotify 輪詢、歌詞、同步引擎、背景執行、即時動態與小工具。
/// 決策邏輯在 Core/（PollPolicy、IdlePolicy、OptimisticGuard、WidgetReloadPolicy…），
/// 各項工作在 Services/（PlaybackPoller、LyricsController、WidgetTimelinePublisher…）。
@MainActor
@Observable
final class AppModel {
    // MARK: 服務

    @ObservationIgnored let auth: SpotifyAuth
    @ObservationIgnored private let player: PlayerClient
    let lyrics: LyricsController
    @ObservationIgnored let audioKeeper = SilentAudioKeeper()
    @ObservationIgnored let liveActivity = LiveActivityManager()
    @ObservationIgnored let widget = WidgetTimelinePublisher()
    @ObservationIgnored let power = PowerMonitor()
    @ObservationIgnored private let reachability = Reachability()
    @ObservationIgnored private let artwork = ArtworkStore()
    @ObservationIgnored private let poller = PlaybackPoller()
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let trackOffsets = SongOffsetStore()
    @ObservationIgnored private var engine = LyricsSyncEngine()
    @ObservationIgnored private var pollPolicy = PollPolicy()
    @ObservationIgnored private let idlePolicy = IdlePolicy()
    @ObservationIgnored private var optimistic = OptimisticGuard()

    // MARK: 畫面狀態

    private(set) var nowPlaying: NowPlaying?
    private(set) var session: SessionState = .connecting
    private(set) var lyricsDisplay = LyricsDisplay.empty
    /// 目前播放位置（秒，不含延遲）
    private(set) var position: TimeInterval = 0
    /// 輪詢 / 播放控制的錯誤（顯示成橫幅）
    private(set) var pollError: UserFacingError?
    private(set) var isOnline = true
    /// 系統設定是否允許即時動態
    private(set) var activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    /// 小工具、捷徑或網址要求開啟的畫面
    private(set) var requestedScreen: CarLyricsScreen?
    /// 播放控制的觸覺回饋觸發器（每次成功 / 失敗 +1）
    private(set) var controlSuccessCount = 0
    private(set) var controlFailureCount = 0
    /// 手動選擇 / 匯入歌詞成功
    private(set) var lyricsChosenCount = 0
    /// 接著車用音訊（CarPlay / 車用藍牙）
    private(set) var isCarConnected = false

    // MARK: 診斷（診斷頁每秒刷新，不需要觸發畫面更新）

    @ObservationIgnored private(set) var lastPollAt: Date?
    @ObservationIgnored private(set) var maxPollGap: TimeInterval = 0
    @ObservationIgnored private(set) var lastResponseBytes = 0
    @ObservationIgnored private(set) var lastErrorDetail: String?
    @ObservationIgnored private(set) var artworkFile: String?

    // MARK: 設定

    /// 全域歌詞延遲（秒）。正值 = 歌詞提前出現
    var globalOffset: TimeInterval {
        didSet {
            preferences.globalOffset = globalOffset
            offsetChanged()
        }
    }

    /// 這首歌額外的延遲（秒），會記住每首歌各自的設定
    var trackOffset: TimeInterval = 0 {
        didSet {
            if let id = nowPlaying?.trackID { trackOffsets.set(trackOffset, for: id) }
            offsetChanged()
        }
    }

    /// 背景持續執行（鎖定畫面、開車時也能更新歌詞）
    var backgroundEnabled: Bool {
        didSet {
            preferences.backgroundEnabled = backgroundEnabled
            if backgroundEnabled && auth.isLoggedIn { audioKeeper.start() } else { audioKeeper.stop() }
        }
    }

    /// 在鎖定畫面 / 動態島 / CarPlay 顯示即時動態
    var liveActivityEnabled: Bool {
        didSet {
            preferences.liveActivityEnabled = liveActivityEnabled
            if liveActivityEnabled { pushLiveActivity(placeholder: true, priority: .important) } else { liveActivity.end() }
        }
    }

    /// 播放中螢幕不自動關閉（App 在前景時）
    var keepScreenOn: Bool {
        didSet {
            preferences.keepScreenOn = keepScreenOn
            updateIdleTimer()
        }
    }

    /// 專注模式字級倍率
    var focusFontScale: Double {
        didSet { preferences.focusFontScale = focusFontScale }
    }

    /// 專注模式鎖定橫向
    var focusLandscapeLock: Bool {
        didSet { preferences.focusLandscapeLock = focusLandscapeLock }
    }

    /// 連上車用音訊時自動進入專注模式
    var autoFocusInCar: Bool {
        didSet { preferences.autoFocusInCar = autoFocusInCar }
    }

    /// 已看過設定檢查（第一次啟動會自動顯示）
    var hasSeenSetup: Bool {
        didSet { preferences.hasSeenSetup = hasSeenSetup }
    }

    // MARK: 內部狀態

    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var idle: (since: Date, kind: IdlePolicy.Kind)?
    /// 專注模式開著時，螢幕不自動關閉
    @ObservationIgnored var focusModeActive = false {
        didSet { updateIdleTimer() }
    }
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var enablementTask: Task<Void, Never>?
    /// 最後一次採用的輪詢請求送出時間；更舊的回應直接丟掉
    @ObservationIgnored private var lastAcceptedSentAt = Date.distantPast
    /// 連續幾次「沒在播放」；要連續 2 次才清空畫面（避免偶發 204 造成閃爍）
    @ObservationIgnored private var emptyResponseStreak = 0
    @ObservationIgnored private var errorStreak = 0
    /// 配額用完後降低頻率，一小時後恢復
    @ObservationIgnored private var quotaModeUntil = Date.distantPast
    /// 偵測到過期資料時，下一次改用 /me/player
    @ObservationIgnored private var preferFullPlayerEndpoint = false
    @ObservationIgnored private var lastHeartbeatWrite = Date.distantPast
    @ObservationIgnored private var openScreenObserver: NSObjectProtocol?

    private var quotaActive: Bool { Date() < quotaModeUntil }

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        let auth = SpotifyAuth()
        self.auth = auth
        player = SpotifyAPI(auth: auth)
        lyrics = LyricsController(provider: LyricsService())
        globalOffset = preferences.globalOffset
        backgroundEnabled = preferences.backgroundEnabled
        liveActivityEnabled = preferences.liveActivityEnabled
        keepScreenOn = preferences.keepScreenOn
        focusFontScale = preferences.focusFontScale
        focusLandscapeLock = preferences.focusLandscapeLock
        autoFocusInCar = preferences.autoFocusInCar
        hasSeenSetup = preferences.hasSeenSetup
        isCarConnected = SilentAudioKeeper.detectCar()
        session = auth.isLoggedIn ? .connecting : .loggedOut

        checkPreviousHeartbeat()
        logSigningStatus()
        lyrics.onChange = { [weak self] in self?.lyricsChanged() }
        // 來電 / Siri 結束：閒置計時重新開始（通話期間 Spotify 是暫停的）
        audioKeeper.onInterruptionEnded = { [weak self] in
            guard let self, let current = self.idle else { return }
            self.idle = (since: Date(), kind: current.kind)
        }
        audioKeeper.onCarConnectionChanged = { [weak self] connected in
            guard let self else { return }
            self.isCarConnected = connected
            // 上車：如果正在播歌，直接進專注模式（車架上看得比較清楚）
            if connected, self.autoFocusInCar, self.isPlaying, self.requestedScreen == nil {
                self.requestedScreen = .focus
            }
        }
        // 冷啟動時由控制中心 / 捷徑要求的畫面（通知可能比畫面早到）
        if let pending = preferences.pendingScreen {
            requestedScreen = CarLyricsScreen(rawValue: pending)
            preferences.pendingScreen = nil
        }
        reachability.onChange = { [weak self] online in
            guard let self else { return }
            self.isOnline = online
            if online {
                if self.pollError == .offline { self.pollError = nil }
                self.poller.pollNow()
            } else {
                self.pollError = .offline
            }
        }
        reachability.start()
        power.onChange = { [weak self] constrained in self?.applyPowerState(constrained) }
        applyPowerState(power.isConstrained)
        openScreenObserver = NotificationCenter.default.addObserver(forName: .carLyricsOpenScreen, object: nil,
                                                                    queue: .main) { [weak self] note in
            let raw = note.userInfo?["screen"] as? String
            MainActor.assumeIsolated {
                self?.request(screen: raw.flatMap(CarLyricsScreen.init(rawValue:)) ?? .lyrics)
            }
        }
        enablementTask = Task { [weak self] in
            for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
                self?.activitiesEnabled = enabled
            }
        }
    }

    /// 由深連結 / 捷徑 / 控制中心要求開啟某個畫面
    func request(screen: CarLyricsScreen) {
        requestedScreen = screen
    }

    /// 畫面已經處理完這個要求
    func consumeRequestedScreen() {
        requestedScreen = nil
        preferences.pendingScreen = nil
    }

    // MARK: - 衍生狀態（畫面用）

    var syncedLines: [LyricLine] { lyrics.state.lines }
    var hasSyncedLyrics: Bool { !syncedLines.isEmpty }
    var totalOffset: TimeInterval { globalOffset + trackOffset }
    var isPlaying: Bool { nowPlaying?.isPlaying ?? false }

    /// 即時推算的播放位置（進度條平滑更新用，不觸發畫面重繪）
    func livePosition() -> TimeInterval {
        engine.position(at: AppClock.now()) ?? position
    }

    var canControlPlayback: Bool {
        auth.hasScope(AppConfig.controlScope)
    }

    var signingDaysRemaining: Int? {
        AppGroup.profile?.daysRemaining()
    }

    var signingExpiration: Date? {
        AppGroup.profile?.expirationDate
    }

    /// 目前最重要的一則提示（主畫面橫幅）
    var notice: AppNotice? {
        if !auth.isLoggedIn { return nil }
        if let pollError { return AppNotice(error: pollError) }
        if !canControlPlayback { return AppNotice(error: .missingControlScope) }
        if liveActivityEnabled && !activitiesEnabled { return .liveActivitiesDisabled }
        if let days = signingDaysRemaining, days <= 2 { return .signingExpiring(days: days) }
        return nil
    }

    /// 設定檢查清單有沒有需要處理的項目
    var setupNeedsAttention: Bool {
        !auth.isLoggedIn || !canControlPlayback || (liveActivityEnabled && !activitiesEnabled)
            || !backgroundEnabled || (signingDaysRemaining ?? 99) <= 2
    }

    // MARK: - 前景 / 背景

    func appBecameActive() {
        isForeground = true
        auth.reloadIfNeeded()
        updateIdleTimer()
        liveActivity.appBecameActive()
        widget.appBecameActive()
        start()
        // 不等第一次輪詢：先開一個即時動態，避免使用者開 App 後馬上鎖定就沒有
        pushLiveActivity(placeholder: true, priority: .important)
        liveActivity.flush()
    }

    func appEnteredBackground() {
        isForeground = false
        updateIdleTimer()
        if backgroundEnabled && auth.isLoggedIn {
            audioKeeper.ensureRunning()
            debugLog("進入背景，持續執行")
        } else {
            // 使用者關閉背景執行：直接結束即時動態，避免之後顯示「暫停更新」像是故障
            if liveActivity.isActive { liveActivity.end() }
            widget.publish(.idle(auth.isLoggedIn ? "背景執行已關閉，打開 CarLyrics 繼續" : "請先登入 Spotify"))
            stop()
        }
    }

    // MARK: - 生命週期

    func start() {
        if backgroundEnabled && auth.isLoggedIn { audioKeeper.start() }
        if !poller.isRunning {
            debugLog("開始輪詢（\(BuildInfo.summary)）")
            poller.start { [weak self] in await self?.pollOnce() ?? 10 }
        }
        if tickTask == nil { startTickLoop() }
    }

    func stop() {
        guard poller.isRunning || tickTask != nil else { return }
        debugLog("停止輪詢")
        poller.stop()
        tickTask?.cancel()
        tickTask = nil
    }

    private func startTickLoop() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                let delay = self?.tick() ?? 1
                try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(15))
            }
        }
    }

    /// 狀態改變（換歌、拖動、歌詞載入、調整延遲）後重新排程，讓下一次換句準時
    private func rescheduleTick() {
        guard tickTask != nil else { return }
        tickTask?.cancel()
        startTickLoop()
    }

    // MARK: - 登入

    func login() {
        Task {
            do {
                try await auth.login()
                debugLog("登入成功")
                pollError = nil
                session = .connecting
                start()
                pushLiveActivity(placeholder: true, priority: .important)
            } catch SpotifyAuthError.cancelled {
                debugLog("使用者取消登入")
            } catch {
                debugLog("登入失敗：\(error.localizedDescription)")
                pollError = UserFacingError(error)
            }
        }
    }

    func logout() {
        auth.logout()
        liveActivity.end()
        audioKeeper.stop()
        clearPlayback()
        session = .loggedOut
        pollError = nil
        widget.publish(.idle("請先登入 Spotify"))
        debugLog("已登出")
    }

    /// 一鍵重新登入（取得新的權限，例如「控制播放」）
    func relogin() {
        logout()
        login()
    }

    /// 橫幅上的動作
    func perform(_ action: AppNotice.Action) {
        switch action {
        case .relogin: relogin()
        case .retry:
            pollError = nil
            poller.pollNow()
            if case .failed = lyrics.state { lyrics.retry() }
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }

    // MARK: - 播放控制

    /// 超過這個秒數按 ⏮ 會從頭播放，否則跳到上一首（和一般音樂 App 一樣）
    static let restartThreshold: TimeInterval = 3

    func previousOrRestart() {
        let pos = engine.position(at: AppClock.now()) ?? 0
        control(pos > Self.restartThreshold ? .restart : .previous)
    }

    func control(_ command: PlayerCommand) {
        guard canControlPlayback else {
            pollError = .missingControlScope
            controlFailureCount += 1
            debugLog("缺少 \(AppConfig.controlScope) 權限，需要重新登入")
            return
        }
        Task {
            do {
                try await player.send(command)
                debugLog("播放控制：\(command.name)")
                controlSuccessCount += 1
                applyOptimistic(command)
                // 讓 Spotify 有時間切換，再重新輪詢（取代原本的等待，不會同時有兩個請求）
                try? await Task.sleep(for: .milliseconds(400))
                poller.pollNow()
            } catch {
                controlFailureCount += 1
                pollError = UserFacingError(error)
                debugLog("播放控制失敗：\(error.localizedDescription)")
            }
        }
    }

    /// 播放控制成功後立刻更新畫面，不用等下一次輪詢
    private func applyOptimistic(_ command: PlayerCommand) {
        guard let np = nowPlaying else { return }
        let now = AppClock.now()
        let pos = engine.position(at: now) ?? np.progress
        let updated: NowPlaying
        switch command {
        case .seek(let ms): updated = np.with(progress: Double(ms) / 1000)
        case .restart: updated = np.with(progress: 0)
        case .pause: updated = np.with(progress: pos, isPlaying: false)
        case .play: updated = np.with(progress: pos, isPlaying: true)
        case .next, .previous: return
        }
        // 在這之前送出的輪詢回應都視為過期；接下來 2 秒內矛盾的回應也視為延遲
        lastAcceptedSentAt = now
        optimistic.arm(now: now)
        nowPlaying = updated
        session = updated.isPlaying ? .playing : .paused
        engine.update(PlaybackSnapshot(trackID: updated.trackID, progress: updated.progress,
                                       duration: updated.duration, isPlaying: updated.isPlaying,
                                       timestamp: now))
        updateIdleTimer()
        tick()
        rescheduleTick()
        pushLiveActivity(priority: .important)
        publishWidgetTimeline()
    }

    /// 點完整歌詞的某一句 → Spotify 跳到那個時間點
    func seek(toLine index: Int) {
        guard syncedLines.indices.contains(index) else { return }
        let target = max(0, syncedLines[index].time - totalOffset)
        control(.seek(ms: Int(target * 1000)))
    }

    // MARK: - 輪詢

    /// 執行一次輪詢，回傳下一次輪詢前要等待的秒數
    private func pollOnce() async -> TimeInterval {
        recordHeartbeat()

        guard auth.isLoggedIn else {
            // 可能是在背景被自動登出（refresh token 失效）：停止一切，不要空轉耗電
            if liveActivity.isActive { liveActivity.end() }
            if audioKeeper.wantsRunning { audioKeeper.stop() }
            session = .loggedOut
            if !isForeground {
                stop()
                return 0
            }
            return pollPolicy.delay(for: .loggedOut)
        }
        // 離線：不要白白等逾時；恢復連線時 Reachability 會立刻觸發輪詢
        guard reachability.isOnline else {
            pollError = .offline
            return 30
        }
        if backgroundEnabled { audioKeeper.ensureRunning() }
        liveActivity.keepAlive()
        do {
            let full = preferFullPlayerEndpoint
            preferFullPlayerEndpoint = false
            let response = try await player.currentlyPlaying(fullPlayer: full)
            lastResponseBytes = response.bytes
            guard !Task.isCancelled else { return 0 }
            errorStreak = 0
            lastErrorDetail = nil
            if pollError != nil && pollError != .missingControlScope { pollError = nil }
            return handle(response.result)
        } catch {
            // 被 pollNow 取消的請求不算錯誤
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return 0 }
            errorStreak += 1
            let delay = pollPolicy.delay(for: .error(streak: errorStreak))
            lastErrorDetail = error.localizedDescription
            debugLog("輪詢錯誤（\(Int(delay)) 秒後重試）：\(error.localizedDescription)")
            // 偶發一次逾時不打擾使用者；連續失敗才顯示
            if errorStreak >= 2 || UserFacingError(error).needsAttention { pollError = UserFacingError(error) }
            _ = checkIdle()
            return delay
        }
    }

    private func handle(_ result: PlayerPollResult) -> TimeInterval {
        switch result {
        case .playing(let np, let measuredAt, let sentAt):
            // 比較舊的請求比較晚回來 → 丟掉，避免歌詞跳回舊位置
            guard sentAt > lastAcceptedSentAt else {
                debugLog("丟棄過期的輪詢回應")
                return 1
            }
            lastAcceptedSentAt = sentAt
            emptyResponseStreak = 0
            // session 要先更新：廣告結束接回音樂時，推送不能被 .nonMusic 擋掉
            let leavingNonMusic = session.isNonMusic
            session = np.isPlaying ? .playing : .paused
            applyPlayback(np, measuredAt: measuredAt, force: leavingNonMusic)
            if np.isPlaying {
                idle = nil
            } else if idle?.kind != .paused {
                idle = (since: Date(), kind: .paused)
            }
            if checkIdle() { return pollPolicy.delay(for: .idleStopped) }
            let remaining: TimeInterval? = {
                guard let pos = engine.position(at: AppClock.now()), np.duration > 0 else { return nil }
                return np.duration - pos
            }()
            return pollPolicy.delay(for: .playing(isPlaying: np.isPlaying, remaining: remaining),
                                    quotaActive: quotaActive, preferFullPlayer: preferFullPlayerEndpoint)

        case .nonMusic(let kind, let playing):
            // 廣告 / Podcast：保留上一首的歌詞，廣告後的下一首會自然接手
            emptyResponseStreak = 0
            if session != .nonMusic(kind) {
                debugLog(kind.label)
                session = .nonMusic(kind)
                push(LiveActivityContentBuilder.nonMusic(kind), priority: .important)
                widget.publish(.idle(kind.label))
            }
            // 播放中的廣告 / Podcast 用 60 分鐘門檻；暫停後回到 30 分鐘
            let wanted: IdlePolicy.Kind = playing ? .nonMusic : .paused
            if idle?.kind != wanted { idle = (since: Date(), kind: wanted) }
            if checkIdle() { return pollPolicy.delay(for: .idleStopped) }
            return pollPolicy.delay(for: .nonMusic, quotaActive: quotaActive)

        case .nothing:
            emptyResponseStreak += 1
            // 偶發的 204（切歌、切換裝置）不要立刻清空
            guard emptyResponseStreak >= 2 else { return pollPolicy.delay(for: .nothing(streak: emptyResponseStreak)) }
            if nowPlaying != nil {
                debugLog("Spotify 沒有在播放")
                clearPlayback()
            }
            // 只在狀態改變時寫小工具，否則每 10 秒就會重新整理一次、白白用掉額度
            if session != .notPlaying {
                session = .notPlaying
                // 佔位的「連接 Spotify 中…」也要換成正確狀態（update 會去重）
                if liveActivity.isActive { push(LiveActivityContentBuilder.stopped, priority: .important) }
                widget.publish(.idle("Spotify 沒有在播放"))
            }
            if idle?.kind != .nothing { idle = (since: Date(), kind: .nothing) }
            if checkIdle() { return pollPolicy.delay(for: .idleStopped) }
            return pollPolicy.delay(for: .nothing(streak: emptyResponseStreak))

        case .rateLimited(let retryAfter, let quotaExceeded):
            debugLog("HTTP 429，Retry-After \(Int(retryAfter)) 秒\(quotaExceeded ? "（配額用完）" : "")")
            if quotaExceeded {
                quotaModeUntil = Date().addingTimeInterval(3600)
                pollError = .quotaExceeded
            } else {
                pollError = .rateLimited(seconds: Int(retryAfter))
            }
            return pollPolicy.delay(for: .rateLimited(retryAfter: retryAfter, quotaExceeded: quotaExceeded))
        }
    }

    /// 閒置太久：結束即時動態；在背景時停止一切以省電。回傳 true 代表已停止。
    private func checkIdle() -> Bool {
        guard let idle,
              idlePolicy.shouldStop(kind: idle.kind, since: idle.since, now: Date(),
                                    isForeground: isForeground, carConnected: isCarConnected)
        else { return false }
        let minutes = Int(idlePolicy.limit(for: idle.kind, carConnected: isCarConnected) / 60)
        if liveActivity.isActive {
            debugLog("閒置超過 \(minutes) 分鐘，結束即時動態")
            liveActivity.end()
        }
        debugLog("閒置中，停止背景執行以省電（下次打開 App 會自動恢復）")
        widget.publish(.idle("打開 CarLyrics 繼續同步歌詞"))
        audioKeeper.stop()
        stop()
        return true
    }

    private func applyPlayback(_ np: NowPlaying, measuredAt: Date, force: Bool = false) {
        let snapshot = PlaybackSnapshot(trackID: np.trackID, progress: np.progress, duration: np.duration,
                                        isPlaying: np.isPlaying, timestamp: measuredAt)
        // 樂觀更新保護窗內，與目前狀態矛盾的回應視為 Spotify 還沒套用（Spotify Connect 常有 1–2 秒延遲）
        if optimistic.shouldIgnore(current: engine.snapshot, incoming: snapshot, now: AppClock.now()) {
            debugLog("樂觀更新保護：忽略延遲的回應")
            preferFullPlayerEndpoint = true
            return
        }
        let change = engine.update(snapshot)

        // 只有在歌曲或播放狀態改變時才更新 nowPlaying（避免每次輪詢整頁重繪）
        if nowPlaying?.trackID != np.trackID || nowPlaying?.isPlaying != np.isPlaying {
            nowPlaying = np
        }

        switch change {
        case .newTrack:
            debugLog("換歌：\(np.title) – \(np.artist)")
            artworkFile = nil
            // 先套用這首歌的延遲，第一次寫給小工具的時間軸就是正確的
            trackOffset = trackOffsets.offset(for: np.trackID)
            lyrics.load(for: np)
            loadArtwork(for: np)
        case .seeked:
            debugLog("偵測到拖動進度 → \(formatTime(np.progress))")
            pushLiveActivity(priority: .important)
            rescheduleTick()
        case .playStateChanged:
            debugLog(np.isPlaying ? "繼續播放" : "暫停")
            pushLiveActivity(priority: .important)
            rescheduleTick()
        case .stale:
            debugLog("Spotify 進度沒有前進（\(formatTime(np.progress))），忽略並改用 /me/player 重試")
            preferFullPlayerEndpoint = true
        case .none:
            break
        }
        updateIdleTimer()
        tick()
        if force, change == .none || change == .stale {
            // 廣告結束後回到同一首歌：立刻把正確內容推回去
            pushLiveActivity(priority: .important)
        }
        switch change {
        case .newTrack, .playStateChanged:
            publishWidgetTimeline(debounce: true)
        case .seeked:
            publishWidgetTimeline()
        case .none, .stale:
            // 只是進度微調（Spotify 回報有 ±1 秒抖動）→ 重寫檔案讓小工具對齊，不佔重新整理額度
            refreshWidgetFile()
        }
    }

    private func clearPlayback() {
        nowPlaying = nil
        engine.reset()
        lyrics.reset()
        lyricsDisplay = .empty
        position = 0
        artworkFile = nil
        updateIdleTimer()
    }

    // MARK: - 歌詞

    private func lyricsChanged() {
        if lyrics.state == .searching { lyricsDisplay = .empty }
        // 先寫小工具（換歌前後的連續更新會合併），再 tick，避免緊接著又發一次逐句重新整理
        publishWidgetTimeline(debounce: true)
        tick()
        rescheduleTick()
        pushLiveActivity(priority: .important)
        if case .synced = lyrics.state, !power.isConstrained {
            lyrics.prefetch { [player] in await player.nextInQueue() }
        }
    }

    // MARK: 手動選擇 / 匯入（畫面呼叫）

    func useCandidate(_ track: LRCLIBTrack) {
        lyrics.use(track)
        lyricsChosenCount += 1
    }

    func importLyrics(_ text: String) {
        lyrics.importText(text)
        lyricsChosenCount += 1
    }

    // MARK: - 延遲

    private func offsetChanged() {
        tick()
        rescheduleTick()
        publishWidgetTimeline()
    }

    // MARK: - 每次換句

    /// 以本地時鐘推算目前位置，更新畫面上的目前句 / 下一句。
    /// 回傳到下一次換句的秒數（最多 1 秒），讓 tick 迴圈剛好在換句時醒來。
    @discardableResult
    private func tick() -> TimeInterval {
        // 沒有播放資訊時不用每秒醒來（任何狀態改變都會 rescheduleTick）
        guard let pos = engine.position(at: AppClock.now()) else { return 5 }
        if abs(position - pos) >= 0.05 { position = pos }
        let effective = pos + totalOffset
        let d = LyricsDisplay(lines: syncedLines, position: effective)
        if d != lyricsDisplay {
            let lineChanged = d.current != lyricsDisplay.current || d.index != lyricsDisplay.index
            lyricsDisplay = d
            pushLiveActivity()
            if lineChanged { widget.lineChanged(isForeground: isForeground) }
        }
        guard engine.snapshot?.isPlaying == true else { return 5 }
        guard let next = syncedLines.nextChangeTime(after: effective) else { return 1 }
        return min(1, max(0.02, next - effective + 0.01))
    }

    /// 歌曲 0 秒對應的真實時刻（不含延遲）
    private func songStartDate() -> Date? {
        guard let pos = engine.position(at: AppClock.now()) else { return nil }
        return Date().addingTimeInterval(-pos)
    }

    // MARK: - 即時動態

    /// 所有即時動態的推送都走這裡（統一檢查開關與登入狀態）
    private func push(_ model: ActivityContentModel, priority: LiveActivityManager.Priority) {
        guard liveActivityEnabled, auth.isLoggedIn else { return }
        liveActivity.update(model, priority: priority)
    }

    /// - Parameter placeholder: 還沒有播放資訊時，也先開一個「連接中」的即時動態
    private func pushLiveActivity(placeholder: Bool = false, priority: LiveActivityManager.Priority = .routine) {
        guard let np = nowPlaying else {
            if placeholder {
                push(session == .notPlaying ? LiveActivityContentBuilder.stopped
                                            : LiveActivityContentBuilder.connecting, priority: priority)
            }
            return
        }
        if case .nonMusic = session { return }
        let model = LiveActivityContentBuilder.build(nowPlaying: np, lyrics: lyrics.state, display: lyricsDisplay,
                                                     songStart: songStartDate(), artworkFile: artworkFile,
                                                     nextLineAt: nextLineDate())
        push(model, priority: priority)
    }

    /// 下一句開始的真實時刻（間奏倒數用）
    private func nextLineDate() -> Date? {
        guard let pos = engine.position(at: AppClock.now()),
              let next = syncedLines.nextChangeTime(after: pos + totalOffset) else { return nil }
        return Date().addingTimeInterval(next - (pos + totalOffset))
    }

    // MARK: - 小工具

    /// 把整首歌的時間軸交給小工具。只在換歌、拖動、暫停/播放、歌詞載入、調整延遲時呼叫。
    private func publishWidgetTimeline(debounce: Bool = false) {
        guard let snapshot = widgetSnapshot() else { return }
        widget.publish(snapshot, debounce: debounce)
    }

    /// 只有進度漂移：重寫檔案，不請系統重新整理
    private func refreshWidgetFile() {
        guard let snapshot = widgetSnapshot() else { return }
        widget.refreshFile(snapshot)
    }

    private func widgetSnapshot() -> LyricsTimelineSnapshot? {
        guard let np = nowPlaying, let pos = engine.position(at: AppClock.now()) else { return nil }
        let now = Date()
        let effective = pos + totalOffset
        var message: String?
        switch lyrics.state {
        case .searching: message = "搜尋歌詞中…"
        case .synced: break
        default: message = nil
        }
        if !np.isPlaying {
            let line = lyricsDisplay.current.isEmpty ? np.title : lyricsDisplay.current
            message = "⏸ \(line)"
        }
        return LyricsTimelineSnapshot(
            trackID: np.trackID, title: np.title, artist: np.artist, lines: syncedLines,
            songStart: now.addingTimeInterval(-effective), isPlaying: np.isPlaying, message: message,
            updatedAt: now, appliedOffset: totalOffset, duration: np.duration, artworkFile: artworkFile)
    }

    // MARK: - 封面

    private func loadArtwork(for np: NowPlaying) {
        guard np.smallArtworkURL != nil else { return }
        Task { [weak self, artwork] in
            let file = await artwork.prepare(trackID: np.trackID, url: np.smallArtworkURL)
            guard let self, let file, self.nowPlaying?.trackID == np.trackID else { return }
            self.artworkFile = file
            self.pushLiveActivity(priority: .important)
            self.publishWidgetTimeline(debounce: true)
        }
    }

    // MARK: - 耗電

    private func applyPowerState(_ constrained: Bool) {
        pollPolicy.constrained = constrained
        widget.lineReloadsEnabled = !constrained
        liveActivity.keepAliveInterval = constrained ? 80 : 45
    }

    // MARK: - 螢幕

    private func updateIdleTimer() {
        let disable = isForeground && (focusModeActive || (keepScreenOn && isPlaying))
        if UIApplication.shared.isIdleTimerDisabled != disable {
            UIApplication.shared.isIdleTimerDisabled = disable
        }
    }

    // MARK: - 心跳（偵測背景執行是否被中斷）

    private func recordHeartbeat() {
        let now = Date()
        if let last = lastPollAt {
            let gap = now.timeIntervalSince(last)
            if gap > maxPollGap { maxPollGap = gap }
            if gap > 60 {
                debugLog("輪詢間隔 \(Int(gap)) 秒（背景執行可能曾被暫停）")
            }
        }
        lastPollAt = now
        guard now.timeIntervalSince(lastHeartbeatWrite) > 15 else { return }
        lastHeartbeatWrite = now
        preferences.lastHeartbeat = (now, !isForeground)
    }

    func resetDiagnostics() {
        maxPollGap = 0
    }

    /// 啟動時檢查上次的心跳：若當時在背景執行且很久沒更新，記一筆
    private func checkPreviousHeartbeat() {
        guard let last = preferences.lastHeartbeat, last.inBackground,
              Date().timeIntervalSince(last.date) > 60 else { return }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        debugLog("上次背景執行最後一次輪詢在 \(f.string(from: last.date))，之後疑似被系統終止")
    }

    private func logSigningStatus() {
        guard let days = signingDaysRemaining else { return }
        debugLog("簽名剩 \(days) 天到期")
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return String(format: "%ld:%02ld", s / 60, s % 60)
}
