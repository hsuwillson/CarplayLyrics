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
    /// 播放狀態與轉換規則（純邏輯，在 Core 測試）
    @ObservationIgnored private var playback = PlaybackState()
    @ObservationIgnored private var reducer = PlaybackReducer()

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
    /// 歌詞時間準不準（診斷用）：換句次數、晚超過 0.5 秒的次數、最晚多少
    @ObservationIgnored private var lineChangeCount = 0
    @ObservationIgnored private var lateLineCount = 0
    @ObservationIgnored private var maxLineLateness: TimeInterval = 0
    /// 輪詢修正位置的次數與最大差距
    @ObservationIgnored private var positionCorrections = 0
    @ObservationIgnored private var maxPositionDrift: TimeInterval = 0
    /// 最近一次排定的輪詢間隔（診斷用）
    @ObservationIgnored private(set) var lastPollDelay: TimeInterval = 0
    /// 上一次寫狀態快照的時間（定期快照用）
    @ObservationIgnored private var lastSnapshotAt = Date.distantPast
    /// 上一次記錄的輪詢模式（只在改變時記一行）
    @ObservationIgnored private var loggedSurface: PollPolicy.Surface?
    @ObservationIgnored private var memoryWarningObserver: NSObjectProtocol?
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
            if liveActivityEnabled {
                pushLiveActivity(placeholder: true, priority: .important)
            } else {
                liveActivity.end(reason: "設定關閉")
            }
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

    /// 設定頁的「鎖定畫面與 CarPlay 歌詞」三選一（存成 liveActivityEnabled + liveActivityOnlyInCar）
    var liveActivityMode: LiveActivityMode {
        get {
            guard liveActivityEnabled else { return .off }
            return liveActivityOnlyInCar ? .whileDriving : .always
        }
        set {
            if newValue == .off {
                liveActivityEnabled = false
            } else {
                // 先決定「只在車上」再打開，避免不在車上時先閃出一個即時動態
                liveActivityOnlyInCar = newValue == .whileDriving
                liveActivityEnabled = true
            }
        }
    }

    /// 只在連上 CarPlay 時啟動即時動態（平常不佔用動態島）
    var liveActivityOnlyInCar: Bool {
        didSet {
            preferences.liveActivityOnlyInCar = liveActivityOnlyInCar
            if liveActivityOnlyInCar, !isCarConnected {
                liveActivity.end(reason: "設定為開車時，目前沒連 CarPlay")
            } else {
                pushLiveActivity(placeholder: true, priority: .important)
            }
        }
    }

    /// 沒在播放時結束即時動態（不要一直佔用動態島）
    var endActivityWhenIdle: Bool {
        didSet {
            preferences.endActivityWhenIdle = endActivityWhenIdle
            if !endActivityWhenIdle { playback.activityEndedForIdle = false }
        }
    }

    /// Wi-Fi 時預先載入整個播放佇列的歌詞
    var prefetchQueueOnWiFi: Bool {
        didSet { preferences.prefetchQueueOnWiFi = prefetchQueueOnWiFi }
    }

    /// 已看過設定檢查（第一次啟動會自動顯示）
    var hasSeenSetup: Bool {
        didSet { preferences.hasSeenSetup = hasSeenSetup }
    }

    // MARK: 內部狀態

    @ObservationIgnored private var isForeground = true
    /// 這次上車已經自動進過專注模式（使用者離開後不要一直把他拉回去）
    @ObservationIgnored private var autoFocusedThisCarSession = false
    /// 這首歌的歌詞自動重試了幾次（換歌歸零）
    @ObservationIgnored private var lyricsAutoRetryCount = 0
    /// 專注模式開著時，螢幕不自動關閉
    @ObservationIgnored var focusModeActive = false {
        didSet { updateIdleTimer() }
    }
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var enablementTask: Task<Void, Never>?
    @ObservationIgnored private var lastHeartbeatWrite = Date.distantPast
    @ObservationIgnored private var openScreenObserver: NSObjectProtocol?

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
        endActivityWhenIdle = preferences.endActivityWhenIdle
        liveActivityOnlyInCar = preferences.liveActivityOnlyInCar
        prefetchQueueOnWiFi = preferences.prefetchQueueOnWiFi
        hasSeenSetup = preferences.hasSeenSetup
        isCarConnected = SilentAudioKeeper.detectCar()
        session = auth.isLoggedIn ? .connecting : .loggedOut

        checkPreviousHeartbeat()
        logSigningStatus()
        lyrics.onChange = { [weak self] in self?.lyricsChanged() }
        // 來電 / Siri 結束：閒置計時重新開始（通話期間 Spotify 是暫停的）
        audioKeeper.onInterruptionEnded = { [weak self] in
            // 通話期間 Spotify 是暫停的：閒置計時重新開始
            guard let self, self.playback.idleKind != nil else { return }
            self.playback.idleSince = Date()
        }
        audioKeeper.onCarConnectionChanged = { [weak self] connected in
            guard let self else { return }
            self.isCarConnected = connected
            // 上車：如果正在播歌，直接進專注模式（車架上看得比較清楚）
            if !connected { self.autoFocusedThisCarSession = false }
            if connected, self.autoFocusInCar, self.isPlaying, self.requestedScreen == nil,
               !self.autoFocusedThisCarSession {
                self.autoFocusedThisCarSession = true
                self.requestedScreen = .focus
            }
            // 「只在車上顯示即時動態」：上車開、下車收
            guard self.liveActivityOnlyInCar else { return }
            if connected {
                debugLog("連上車用音訊，開始即時動態")
                self.pushLiveActivity(placeholder: true, priority: .important)
            } else {
                self.liveActivity.end(reason: "離開 CarPlay")
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
                // 網路恢復：剛才沒載到的歌詞自動重載（開車時不用去按「重試」）
                if case .failed = self.lyrics.state {
                    debugLog("網路恢復，自動重新載入歌詞")
                    self.lyrics.retry()
                }
            } else {
                self.pollError = .offline
            }
        }
        reachability.start()
        UIDevice.current.isBatteryMonitoringEnabled = true
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            debugLog("系統記憶體不足警告")
        }
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
        playback.engine.position(at: AppClock.now()) ?? position
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
        debugLog("回到前景")
        // 在車上打開（例如捷徑自動化）：直接進專注模式，一次車程只自動進一次
        if isCarConnected, autoFocusInCar, !autoFocusedThisCarSession, requestedScreen == nil {
            autoFocusedThisCarSession = true
            requestedScreen = .focus
        }
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
        logSnapshot("進入背景")
        if backgroundEnabled && auth.isLoggedIn {
            audioKeeper.ensureRunning()
            debugLog("進入背景，持續執行")
        } else {
            // 使用者關閉背景執行：直接結束即時動態，避免之後顯示「暫停更新」像是故障
            if liveActivity.isActive { liveActivity.end(reason: "背景同步已關閉") }
            widget.publish(.idle(auth.isLoggedIn ? "背景執行已關閉，打開 CarLyrics 繼續" : "請先登入 Spotify"))
            stop()
        }
    }

    // MARK: - 生命週期

    func start() {
        if backgroundEnabled && auth.isLoggedIn { audioKeeper.start() }
        if !poller.isRunning {
            debugLog("開始輪詢（\(BuildInfo.summary)）")
            logSnapshot("開始")
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
                let delay = self?.tick() ?? 5
                try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(50))
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
                playback.session = .connecting
                start()
                pushLiveActivity(placeholder: true, priority: .important)
            } catch SpotifyAuthError.cancelled {
                debugLog("使用者取消登入")
            } catch SpotifyAuthError.invalidCallback(let reason) where reason == "access_denied" {
                // 在 Spotify 頁面按了「取消」
                debugLog("使用者在 Spotify 頁面取消授權")
            } catch {
                debugLog("登入失敗：\(error.localizedDescription)")
                pollError = UserFacingError(error)
            }
        }
    }

    func logout() {
        auth.logout()
        playback = PlaybackState(session: .loggedOut)
        liveActivity.end(reason: "登出")
        audioKeeper.stop()
        clearPlayback()
        session = .loggedOut
        pollError = nil
        widget.publish(.idle("請先登入 Spotify"))
        debugLog("已登出")
    }

    /// 一鍵重新登入（取得新的權限，例如「控制播放」）。
    /// 不先登出：登入成功才換掉舊的 token；取消或沒網路時維持原本的登入，不會把歌詞同步停掉
    func relogin() {
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
        let pos = playback.engine.position(at: AppClock.now()) ?? 0
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
                playback.markHot(at: Date())
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
        let pos = playback.engine.position(at: now) ?? np.progress
        let updated: NowPlaying
        switch command {
        case .seek(let ms): updated = np.with(progress: Double(ms) / 1000)
        case .restart: updated = np.with(progress: 0)
        case .pause: updated = np.with(progress: pos, isPlaying: false)
        case .play: updated = np.with(progress: pos, isPlaying: true)
        case .next, .previous: return
        }
        // 在這之前送出的輪詢回應都視為過期；接下來 2 秒內矛盾的回應也視為延遲
        playback.lastAcceptedSentAt = now
        playback.optimistic.arm(now: now)
        playback.nowPlaying = updated
        playback.session = updated.isPlaying ? .playing : .paused
        nowPlaying = updated
        session = playback.session
        playback.engine.update(PlaybackSnapshot(trackID: updated.trackID, progress: updated.progress,
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
        let delay = await pollOnceInner()
        lastPollDelay = delay
        logSurfaceChangeIfNeeded(delay: delay)
        // 播放 / 背景執行期間每 10 分鐘記一次完整狀態，事後看紀錄就知道當時的情況
        if Date().timeIntervalSince(lastSnapshotAt) > 600 { logSnapshot("定期") }
        return delay
    }

    private func pollOnceInner() async -> TimeInterval {
        recordHeartbeat()

        guard auth.isLoggedIn else {
            // 可能是在背景被自動登出（refresh token 失效）：停止一切，不要空轉耗電
            if liveActivity.isActive { liveActivity.end(reason: "登入失效") }
            if audioKeeper.wantsRunning { audioKeeper.stop() }
            session = .loggedOut
            playback.session = .loggedOut
            if !isForeground {
                stop()
                return 0
            }
            return reducer.pollPolicy.delay(for: .loggedOut)
        }
        // 離線：不要白白等逾時；恢復連線時 Reachability 會立刻觸發輪詢
        guard reachability.isOnline else {
            pollError = .offline
            return 30
        }
        if backgroundEnabled { audioKeeper.ensureRunning() }
        liveActivity.keepAlive()
        do {
            let full = playback.preferFullPlayerEndpoint
            playback.preferFullPlayerEndpoint = false
            let response = try await player.currentlyPlaying(fullPlayer: full)
            lastResponseBytes = response.bytes
            guard !Task.isCancelled else { return 0 }
            lastErrorDetail = nil
            if pollError != nil && pollError != .missingControlScope { pollError = nil }
            return handle(response.result)
        } catch {
            // 被 pollNow 取消的請求不算錯誤
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return 0 }
            let output = reducer.error(&playback, context: context())
            lastErrorDetail = error.localizedDescription
            debugLog("輪詢錯誤（\(Int(output.delay)) 秒後重試）：\(error.localizedDescription)")
            // 偶發一次逾時不打擾使用者；連續失敗才顯示
            if playback.errorStreak >= 2 || UserFacingError(error).needsAttention {
                pollError = UserFacingError(error)
            }
            for effect in output.effects { run(effect) }
            return output.delay
        }
    }

    /// 用 Core 的 reducer 算出新狀態與要做的事（對照表：docs/event-effects.md）
    private func handle(_ result: PlayerPollResult) -> TimeInterval {
        // 記下輪詢前推算的位置，看 Spotify 回來的位置差多少（同步準不準的線索）
        let trackBefore = playback.nowPlaying?.trackID
        let predicted = playback.engine.position(at: AppClock.now())
        let output = reducer.reduce(&playback, result: result, context: context())
        if let predicted, trackBefore == playback.nowPlaying?.trackID, playback.nowPlaying?.isPlaying == true,
           let actual = playback.engine.position(at: AppClock.now()) {
            let drift = actual - predicted
            positionCorrections += 1
            maxPositionDrift = max(maxPositionDrift, abs(drift))
            // 0.4 秒以上但不是拖動（拖動另外記）：可能是網路延遲或 Spotify 回報跳動
            if abs(drift) >= 0.4, abs(drift) < 2 {
                debugLog(String(format: "位置修正 %+.2f 秒", drift))
            }
        }
        syncPublishedState(result)
        for effect in output.effects { run(effect) }
        updateIdleTimer()
        // 每次輪詢都可能修正位置：從新的估計重新排下一次換句（tick 迴圈不再每秒醒來）
        if tickTask != nil { rescheduleTick() } else { tick() }
        return output.delay
    }

    private func context() -> PlaybackReducer.Context {
        PlaybackReducer.Context(now: Date(), monotonicNow: AppClock.now(), isForeground: isForeground,
                                carConnected: isCarConnected, activityIsActive: liveActivity.isActive,
                                endActivityWhenIdle: endActivityWhenIdle, surface: pollSurface)
    }

    /// 使用者現在看得到什麼：前景最即時；背景有正常更新的即時動態或在車上次之；其他情況問得最少
    private var pollSurface: PollPolicy.Surface {
        if isForeground { return .foreground }
        if isCarConnected || (liveActivity.isActive && !liveActivity.backgroundBlocked) { return .visible }
        return .hidden
    }

    /// reducer 的狀態 → 畫面用的 @Observable 屬性（只有真的改變才寫，避免整頁重繪）
    private func syncPublishedState(_ result: PlayerPollResult) {
        if session != playback.session { session = playback.session }
        if nowPlaying?.trackID != playback.nowPlaying?.trackID
            || nowPlaying?.isPlaying != playback.nowPlaying?.isPlaying {
            nowPlaying = playback.nowPlaying
        }
        if case .rateLimited(let retryAfter, let quotaExceeded) = result {
            pollError = quotaExceeded ? .quotaExceeded : .rateLimited(seconds: Int(retryAfter))
        }
    }

    private func run(_ effect: PlaybackEffect) {
        switch effect {
        case .log(let message):
            debugLog(message)
        case .newTrack(let np):
            artworkFile = nil
            lyricsAutoRetryCount = 0
            // 先套用這首歌的延遲，第一次寫給小工具的時間軸就是正確的
            trackOffset = trackOffsets.offset(for: np.trackID)
            if trackOffset != 0 { debugLog(String(format: "這首歌詞提前 %+.2f 秒（已記住的設定）", trackOffset)) }
            lyrics.load(for: np)
            loadArtwork(for: np)
        case .clearPlayback:
            clearPlayback()
        case .pushStopped:
            push(LiveActivityContentBuilder.stopped, priority: .important)
        case .pushNonMusic(let kind):
            push(LiveActivityContentBuilder.nonMusic(kind), priority: .important)
        case .pushCurrent(let important):
            pushLiveActivity(priority: important ? .important : .routine)
        case .endActivity:
            liveActivity.end(reason: idleEndReason)
        case .publishIdle(let message):
            widget.publish(.idle(message))
        case .publishTimeline(let debounce):
            publishWidgetTimeline(debounce: debounce)
        case .refreshTimelineFile:
            refreshWidgetFile()
        case .rescheduleTick:
            rescheduleTick()
        case .stopForIdle(let minutes):
            debugLog("閒置超過 \(minutes) 分鐘，停止背景執行以省電（下次打開 App 會自動恢復）")
            logSnapshot("閒置停止")
            audioKeeper.stop()
            stop()
        }
    }

    private func clearPlayback() {
        nowPlaying = nil
        playback.nowPlaying = nil
        playback.engine.reset()
        lyrics.reset()
        lyricsDisplay = .empty
        position = 0
        artworkFile = nil
        updateIdleTimer()
    }

    // MARK: - 歌詞

    /// 歌詞載入失敗（網路不穩）時自動重試：5、15、30 秒後各一次；換歌就停
    private func scheduleLyricsAutoRetryIfNeeded() {
        guard case .failed = lyrics.state, lyricsAutoRetryCount < 3, let trackID = nowPlaying?.trackID else { return }
        let delays: [UInt64] = [5, 15, 30]
        let delay = delays[lyricsAutoRetryCount]
        lyricsAutoRetryCount += 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, self.nowPlaying?.trackID == trackID, case .failed = self.lyrics.state,
                  self.isOnline else { return }
            debugLog("自動重新載入歌詞（第 \(self.lyricsAutoRetryCount) 次）")
            self.lyrics.retry()
        }
    }

    private func lyricsChanged() {
        if lyrics.state == .searching { lyricsDisplay = .empty }
        scheduleLyricsAutoRetryIfNeeded()
        // 先寫小工具（換歌前後的連續更新會合併），再 tick，避免緊接著又發一次逐句重新整理
        publishWidgetTimeline(debounce: true)
        tick()
        rescheduleTick()
        pushLiveActivity(priority: .important)
        if case .synced = lyrics.state, !power.isConstrained {
            let whole = prefetchQueueOnWiFi && reachability.isWiFi
            lyrics.prefetch(wholeQueue: whole) { [player] in await player.queue() }
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
    /// 回傳到下一次換句的秒數，讓 tick 迴圈剛好在換句時醒來；
    /// 位置被輪詢修正時 handle() 會重新排程，所以不需要固定每秒醒來檢查。
    @discardableResult
    private func tick() -> TimeInterval {
        // 沒有播放資訊時不用常常醒來（任何狀態改變都會 rescheduleTick）
        guard let pos = playback.engine.position(at: AppClock.now()) else { return 5 }
        if isForeground, abs(position - pos) >= 0.05 { position = pos }
        let effective = pos + totalOffset
        let d = LyricsDisplay(lines: syncedLines, position: effective)
        if d != lyricsDisplay {
            let lineChanged = d.current != lyricsDisplay.current || d.index != lyricsDisplay.index
            // 換句比歌詞時間晚了多少（背景計時器被延後時會變大）
            if lineChanged, let i = d.index, syncedLines.indices.contains(i), d.index != lyricsDisplay.index {
                let lateness = effective - syncedLines[i].time
                if lateness >= 0, lateness < 5 {
                    lineChangeCount += 1
                    maxLineLateness = max(maxLineLateness, lateness)
                    if lateness > 0.5 { lateLineCount += 1 }
                }
            }
            lyricsDisplay = d
            pushLiveActivity()
            if lineChanged { widget.lineChanged(isForeground: isForeground) }
        }
        guard playback.engine.snapshot?.isPlaying == true else { return 5 }
        guard let next = syncedLines.nextChangeTime(after: effective) else {
            // 沒有同步歌詞 / 最後一句之後：沒有要換的句子，等歌曲結束或下一次輪詢就好
            let remaining = (playback.nowPlaying?.duration ?? 0) - pos
            return min(60, max(5, remaining))
        }
        return min(60, max(0.02, next - effective + 0.01))
    }

    /// 歌曲 0 秒對應的真實時刻（不含延遲）
    private func songStartDate() -> Date? {
        guard let pos = playback.engine.position(at: AppClock.now()) else { return nil }
        return Date().addingTimeInterval(-pos)
    }

    // MARK: - 即時動態

    /// 所有即時動態的推送都走這裡（統一檢查開關與登入狀態）
    private func push(_ model: ActivityContentModel, priority: LiveActivityManager.Priority) {
        guard liveActivityEnabled, auth.isLoggedIn else { return }
        // 只在車上顯示：沒連車用音訊就不開（動態島留給其他 App）
        guard !liveActivityOnlyInCar || isCarConnected else { return }
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
        guard let pos = playback.engine.position(at: AppClock.now()),
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
        guard let np = nowPlaying, let pos = playback.engine.position(at: AppClock.now()) else { return nil }
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
        reducer.pollPolicy.constrained = constrained
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

    // MARK: - 診斷快照

    private var idleEndReason: String {
        switch playback.idleKind {
        case .paused: return "閒置（暫停）"
        case .nothing: return "閒置（沒在播放）"
        case .nonMusic: return "閒置（廣告 / Podcast）"
        case nil: return "閒置"
        }
    }

    /// 輪詢模式改變時記一行（前景 / 背景看得到 / 背景看不到），不用每次輪詢都記
    private func logSurfaceChangeIfNeeded(delay: TimeInterval) {
        let surface = pollSurface
        guard surface != loggedSurface else { return }
        loggedSurface = surface
        debugLog("輪詢模式：\(Self.surfaceLabel(surface))（目前間隔 \(String(format: "%.1f", delay)) 秒）")
    }

    private static func surfaceLabel(_ s: PollPolicy.Surface) -> String {
        switch s {
        case .foreground: return "前景"
        case .visible: return "背景・鎖定畫面 / CarPlay 有歌詞"
        case .hidden: return "背景・沒有畫面在顯示"
        }
    }

    /// 目前所有狀態整理成一份（不含 token / 帳號）
    func diagnosticsReport(reason: String) -> DiagnosticsReport {
        typealias R = DiagnosticsReport
        let now = Date()
        let info = ProcessInfo.processInfo
        let device = UIDevice.current
        var r = DiagnosticsReport(reason: reason)
        r.add("版本", [("build", BuildInfo.summary),
                      ("建置", BuildInfo.buildDate.map { $0.formatted(date: .numeric, time: .shortened) }),
                      ("iOS", device.systemVersion), ("機型", Self.deviceModel),
                      ("簽名剩", signingDaysRemaining.map { "\($0) 天" })])
        r.add("設定", [("鎖定畫面歌詞", liveActivityMode.label), ("背景同步", R.yesNo(backgroundEnabled)),
                      ("閒置收起", R.yesNo(endActivityWhenIdle)), ("上車專注", R.yesNo(autoFocusInCar)),
                      ("螢幕常亮", R.yesNo(keepScreenOn)), ("Wi-Fi 預載佇列", R.yesNo(prefetchQueueOnWiFi)),
                      ("歌詞提前", String(format: "全部 %+.2f / 這首 %+.2f", globalOffset, trackOffset))])
        r.add("播放", [("前景", R.yesNo(isForeground)), ("登入", R.yesNo(auth.isLoggedIn)),
                      ("狀態", session.label), ("歌詞", lyrics.state.label),
                      ("手動歌詞", lyrics.hasManualLyrics ? "是" : nil),
                      ("歌曲", nowPlaying.map { "\($0.title) – \($0.artist)" }),
                      ("位置", playback.engine.position(at: AppClock.now()).map {
                          "\(formatTime($0)) / \(formatTime(nowPlaying?.duration ?? 0))" })])
        r.add("輪詢", [("執行中", R.yesNo(poller.isRunning)), ("模式", Self.surfaceLabel(pollSurface)),
                      ("間隔", R.seconds(lastPollDelay)), ("最近", R.ago(lastPollAt, now: now)),
                      ("最長間隔", R.seconds(maxPollGap)), ("連續錯誤", playback.errorStreak > 0 ? "\(playback.errorStreak)" : nil),
                      ("配額模式", playback.quotaActive(now: now) ? "是" : nil),
                      ("最近錯誤", lastErrorDetail), ("回應", "\(lastResponseBytes) bytes")])
        r.add("歌詞時間", [("換句", "\(lineChangeCount) 次"), ("晚 >0.5 秒", "\(lateLineCount) 次"),
                          ("最晚", R.seconds(maxLineLateness)),
                          ("輪詢修正", "\(positionCorrections) 次，最大 \(String(format: "%.2f", maxPositionDrift)) 秒")])
        r.add("即時動態", [("系統允許", R.yesNo(activitiesEnabled)), ("狀態", liveActivity.stateDescription),
                          ("送出", "\(liveActivity.updateCount)"),
                          ("套用/被擋", "\(liveActivity.acceptedCount)/\(liveActivity.rejectedCount)"),
                          ("背景被擋", liveActivity.backgroundBlocked ? "是" : nil),
                          ("最近不同欄位", liveActivity.lastMismatchField),
                          ("最近被擋", R.ago(liveActivity.lastRejectedAt, now: now)),
                          ("開始", R.ago(liveActivity.startedAt, now: now)),
                          ("最近錯誤", liveActivity.lastError)])
        r.add("小工具", [("模式", widget.modeDescription),
                        ("要求/實際", "\(widget.requestCount)/\(widget.renderCount)"),
                        ("最後要求", R.ago(widget.lastRequestAt, now: now)),
                        ("系統最後重整", R.ago(widget.lastRenderAt, now: now))])
        r.add("背景音訊", [("執行中", R.yesNo(audioKeeper.isRunning)), ("應該執行", R.yesNo(audioKeeper.wantsRunning)),
                          ("重啟", "\(audioKeeper.restartCount) 次"),
                          ("最近重啟", audioKeeper.lastRestartReason.map { reason in
                              "\(reason)（\(R.ago(audioKeeper.lastRestartAt, now: now) ?? "?")）" }),
                          ("CarPlay", R.yesNo(isCarConnected))])
        r.add("系統", [("網路", reachability.isOnline ? (reachability.isWiFi ? "Wi-Fi" : "行動網路 / 計量") : "離線"),
                      ("低耗電", R.yesNo(info.isLowPowerModeEnabled)), ("溫度", Self.thermalLabel(info.thermalState)),
                      ("電量", R.percent(device.batteryLevel)), ("充電", Self.batteryLabel(device.batteryState))])
        return r
    }

    /// 把目前狀態寫進紀錄（啟動、進出背景、閒置停止、每 10 分鐘）
    func logSnapshot(_ reason: String) {
        lastSnapshotAt = Date()
        debugLog(diagnosticsReport(reason: reason).text)
    }

    /// 分享用：最上面是「現在」的狀態快照，下面是完整紀錄檔
    func writeDiagnosticsExport() -> URL {
        let header = diagnosticsReport(reason: "分享").text
        let body = (try? String(contentsOf: DebugLog.shared.fileURL, encoding: .utf8)) ?? "（紀錄檔讀取失敗）"
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CarLyrics-診斷-\(stamp).txt")
        let text = "CarLyrics 診斷紀錄\n\(header)\n\n──── 紀錄（舊 → 新）────\n\(body)"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func thermalLabel(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "正常"
        case .fair: return "略熱"
        case .serious: return "過熱"
        case .critical: return "嚴重過熱"
        @unknown default: return "未知"
        }
    }

    private static func batteryLabel(_ s: UIDevice.BatteryState) -> String? {
        switch s {
        case .charging: return "充電中"
        case .full: return "已充滿"
        case .unplugged: return "未充電"
        case .unknown: return nil
        @unknown default: return nil
        }
    }

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
        // 最長輪詢間隔 30 秒；讀取端門檻 60 秒，每 30 秒寫一次就夠
        guard now.timeIntervalSince(lastHeartbeatWrite) > 30 else { return }
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
