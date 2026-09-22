import Foundation
import SwiftUI
import UIKit

/// 串接 Spotify 輪詢、歌詞查詢、同步引擎、背景執行與 Live Activity
@MainActor
final class AppModel: ObservableObject {
    let auth = SpotifyAuth()
    private lazy var api = SpotifyAPI(auth: auth)
    private let lyricsService = LyricsService()
    let backgroundKeeper = BackgroundKeeper()
    let liveActivity = LiveActivityManager()
    private var engine = LyricsSyncEngine()
    private let songOffsets = SongOffsetStore()

    // MARK: 畫面狀態

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plainLyrics: String?
    @Published private(set) var lyricsStatus = "尚未開始"
    @Published private(set) var display = LyricsDisplay.empty
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var statusMessage = ""
    @Published private(set) var hasManualLyrics = false

    // MARK: 除錯資訊

    @Published private(set) var lastPollAt: Date?
    @Published private(set) var maxPollGap: TimeInterval = 0
    @Published private(set) var lastResponseBytes = 0
    @Published private(set) var lastErrorMessage: String?

    // MARK: 設定

    /// 全域歌詞延遲調整（秒）。正值 = 歌詞提前出現
    @Published var offset: TimeInterval {
        didSet {
            UserDefaults.standard.set(offset, forKey: "lyricsOffset")
            tick()
        }
    }

    /// 這首歌額外的延遲（秒），會記住每首歌各自的設定
    @Published var songOffset: TimeInterval = 0 {
        didSet {
            if let id = nowPlaying?.trackID { songOffsets.set(songOffset, for: id) }
            tick()
        }
    }

    /// 背景持續執行（鎖定畫面、開車時也能更新歌詞）
    @Published var backgroundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(backgroundEnabled, forKey: "backgroundEnabled")
            if backgroundEnabled { backgroundKeeper.start() } else { backgroundKeeper.stop() }
        }
    }

    /// 在鎖定畫面 / 靈動島 / CarPlay 顯示 Live Activity
    @Published var liveActivityEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled, forKey: "liveActivityEnabled")
            if liveActivityEnabled { pushLiveActivity(allowPlaceholder: true) } else { liveActivity.end() }
        }
    }

    /// 播放中螢幕不自動關閉（App 在前景時）
    @Published var keepScreenOn: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenOn, forKey: "keepScreenOn")
            updateIdleTimer()
        }
    }

    // MARK: 內部狀態

    private var isForeground = true
    /// 沒在播放（停止或暫停）超過這個秒數：結束 Live Activity；在背景時也停止背景執行以省電
    static let idleEndInterval: TimeInterval = 600
    private var idleSince: Date?

    private var pollTask: Task<Void, Never>?
    private var pollGeneration = 0
    private var tickTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedTrackID: String?

    /// 最後一次採用的輪詢請求送出時間；更舊的回應直接丟掉
    private var lastAcceptedSentAt = Date.distantPast
    /// 連續幾次「沒在播放」；要連續 2 次才清空畫面（避免偶發 204 造成閃爍）
    private var nothingStreak = 0
    private var errorStreak = 0
    private var quotaMode = false
    /// 偵測到過期資料時，下一次改用 /me/player
    private var useFullPlayer = false

    private static let heartbeatKey = "lastHeartbeat"
    private static let heartbeatBackgroundKey = "lastHeartbeatInBackground"

    init() {
        offset = UserDefaults.standard.double(forKey: "lyricsOffset")
        backgroundEnabled = UserDefaults.standard.object(forKey: "backgroundEnabled") as? Bool ?? true
        liveActivityEnabled = UserDefaults.standard.object(forKey: "liveActivityEnabled") as? Bool ?? true
        keepScreenOn = UserDefaults.standard.bool(forKey: "keepScreenOn")
        checkPreviousHeartbeat()
    }

    // MARK: - 前景 / 背景

    func appBecameActive() {
        isForeground = true
        auth.reloadIfNeeded()
        updateIdleTimer()
        liveActivity.appBecameActive()
        start()
        // 不等第一次輪詢：先開一個 Live Activity，避免使用者開 App 後馬上鎖定就沒有
        pushLiveActivity(allowPlaceholder: true)
    }

    func appEnteredBackground() {
        isForeground = false
        updateIdleTimer()
        if backgroundEnabled && auth.isLoggedIn {
            backgroundKeeper.ensureRunning()
            debugLog("進入背景，持續執行")
        } else {
            stop()
        }
    }

    // MARK: - 生命週期

    func start() {
        if backgroundEnabled && auth.isLoggedIn { backgroundKeeper.start() }
        if pollTask == nil {
            debugLog("開始輪詢（\(BuildInfo.summary)）")
            startPollLoop()
        }
        if tickTask == nil {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    let delay = self?.tick() ?? 1
                    try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(15))
                }
            }
        }
    }

    func stop() {
        guard pollTask != nil || tickTask != nil else { return }
        debugLog("停止輪詢")
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
        tickTask?.cancel()
        tickTask = nil
    }

    /// 只保留一個輪詢迴圈：用 generation 讓舊迴圈自行結束
    private func startPollLoop() {
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == self.pollGeneration else { return }
                let delay = await self.pollOnce()
                guard generation == self.pollGeneration else { return }
                try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(300))
            }
        }
    }

    /// 取消目前的等待，立刻重新輪詢（播放控制後使用）
    private func requestImmediatePoll() {
        guard pollTask != nil else { return }
        pollTask?.cancel()
        startPollLoop()
    }

    // MARK: - 登入

    func login() {
        Task {
            do {
                try await auth.login()
                debugLog("登入成功")
                setStatus("登入成功")
                start()
                pushLiveActivity(allowPlaceholder: true)
            } catch SpotifyAuthError.cancelled {
                debugLog("使用者取消登入")
            } catch {
                debugLog("登入失敗：\(error.localizedDescription)")
                setStatus("登入失敗：\(error.localizedDescription)")
            }
        }
    }

    func logout() {
        auth.logout()
        liveActivity.end()
        backgroundKeeper.stop()
        clearPlayback()
        setStatus("")
        debugLog("已登出")
    }

    // MARK: - 播放控制

    var canControlPlayback: Bool {
        auth.hasScope(AppConfig.controlScope)
    }

    /// 超過這個秒數按 ⏮ 會從頭播放，否則跳到上一首（和一般音樂 App 一樣）
    static let restartThreshold: TimeInterval = 3

    func previousOrRestart() {
        let pos = engine.position(at: Date()) ?? 0
        control(pos > Self.restartThreshold ? .restart : .previous)
    }

    func control(_ command: PlayerCommand) {
        guard canControlPlayback else {
            setStatus("請先登出再登入，授權「控制播放」")
            debugLog("缺少 \(AppConfig.controlScope) 權限，需要重新登入")
            return
        }
        Task {
            do {
                try await api.send(command)
                debugLog("播放控制：\(command.name)")
                applyOptimistic(command)
                // 讓 Spotify 有時間切換，再重新輪詢（取代原本的等待，不會同時有兩個請求）
                try? await Task.sleep(for: .milliseconds(400))
                requestImmediatePoll()
            } catch {
                setStatus(error.localizedDescription)
                debugLog("播放控制失敗：\(error.localizedDescription)")
            }
        }
    }

    /// 播放控制成功後立刻更新畫面，不用等下一次輪詢
    private func applyOptimistic(_ command: PlayerCommand) {
        guard let np = nowPlaying else { return }
        let pos = engine.position(at: Date()) ?? np.progress
        let updated: NowPlaying
        switch command {
        case .seek(let ms): updated = np.with(progress: Double(ms) / 1000)
        case .restart: updated = np.with(progress: 0)
        case .pause: updated = np.with(progress: pos, isPlaying: false)
        case .play: updated = np.with(progress: pos, isPlaying: true)
        case .next, .previous: return
        }
        // 在這之前送出的輪詢回應都視為過期
        lastAcceptedSentAt = Date()
        nowPlaying = updated
        engine.update(PlaybackSnapshot(trackID: updated.trackID, progress: updated.progress,
                                       duration: updated.duration, isPlaying: updated.isPlaying,
                                       timestamp: Date()))
        updateIdleTimer()
        tick()
        pushLiveActivity()
    }

    // MARK: - 輪詢

    /// 執行一次輪詢，回傳下一次輪詢前要等待的秒數
    private func pollOnce() async -> TimeInterval {
        recordHeartbeat()
        if backgroundEnabled && auth.isLoggedIn { backgroundKeeper.ensureRunning() }
        liveActivity.keepAlive()

        guard auth.isLoggedIn else {
            setStatus("請先登入 Spotify")
            return 10
        }
        do {
            let full = useFullPlayer
            useFullPlayer = false
            let result = try await api.currentlyPlaying(fullPlayer: full)
            lastResponseBytes = api.lastResponseBytes
            guard !Task.isCancelled else { return 0 }
            errorStreak = 0
            lastErrorMessage = nil

            switch result {
            case .playing(let np, let measuredAt, let sentAt):
                // 比較舊的請求比較晚回來 → 丟掉，避免歌詞跳回舊位置
                guard sentAt > lastAcceptedSentAt else {
                    debugLog("丟棄過期的輪詢回應")
                    return 1
                }
                lastAcceptedSentAt = sentAt
                nothingStreak = 0
                handle(np, measuredAt: measuredAt)
                setStatus(np.isPlaying ? "播放中" : "已暫停")
                if np.isPlaying { idleSince = nil } else if idleSince == nil { idleSince = Date() }
                if checkIdle() { return 30 }
                if quotaMode { return 6 }
                if useFullPlayer { return 1 }   // 過期資料 → 盡快用另一個端點確認
                return np.isPlaying ? 2.5 : 5

            case .nothing:
                nothingStreak += 1
                // 偶發的 204（切歌、切換裝置）不要立刻清空
                guard nothingStreak >= 2 else { return 3 }
                if nowPlaying != nil {
                    debugLog("Spotify 沒有在播放")
                    clearPlayback()
                    pushStoppedLiveActivity()
                }
                if idleSince == nil { idleSince = Date() }
                setStatus("Spotify 沒有在播放")
                if checkIdle() { return 30 }
                return 10

            case .rateLimited(let retryAfter, let quotaExceeded):
                debugLog("HTTP 429，Retry-After \(Int(retryAfter)) 秒\(quotaExceeded ? "（配額用完）" : "")")
                if quotaExceeded {
                    quotaMode = true
                    setStatus("Spotify API 配額用完，已降低查詢頻率")
                    return max(retryAfter, 30)
                }
                setStatus("請求太頻繁，\(Int(retryAfter)) 秒後重試")
                return max(retryAfter, 1)
            }
        } catch {
            // 被 requestImmediatePoll 取消的請求不算錯誤
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return 0 }
            errorStreak += 1
            let delay = PollBackoff.delay(forErrorStreak: errorStreak)
            lastErrorMessage = error.localizedDescription
            debugLog("輪詢錯誤（\(Int(delay)) 秒後重試）：\(error.localizedDescription)")
            setStatus("錯誤：\(error.localizedDescription)")
            return delay
        }
    }

    /// 閒置太久：結束 Live Activity；在背景時停止一切以省電。回傳 true 代表已停止。
    private func checkIdle() -> Bool {
        guard let since = idleSince, Date().timeIntervalSince(since) > Self.idleEndInterval else { return false }
        if liveActivity.isActive {
            debugLog("閒置超過 \(Int(Self.idleEndInterval / 60)) 分鐘，結束 Live Activity")
            liveActivity.end()
        }
        guard !isForeground else { return false }
        debugLog("閒置中，停止背景執行以省電（下次打開 App 會自動恢復）")
        backgroundKeeper.stop()
        stop()
        return true
    }

    private func handle(_ np: NowPlaying, measuredAt: Date) {
        let snapshot = PlaybackSnapshot(trackID: np.trackID, progress: np.progress, duration: np.duration,
                                        isPlaying: np.isPlaying, timestamp: measuredAt)
        let change = engine.update(snapshot)

        // 只有在歌曲或播放狀態改變時才更新 nowPlaying（避免每次輪詢整頁重繪）
        if nowPlaying?.trackID != np.trackID || nowPlaying?.isPlaying != np.isPlaying {
            nowPlaying = np
        }

        switch change {
        case .newTrack:
            debugLog("換歌：\(np.title) – \(np.artist)")
            prefetchTask?.cancel()
            // 先清空舊歌詞再套用這首歌的延遲，避免推送「舊歌詞 + 新歌名」
            loadLyrics(for: np)
            songOffset = songOffsets.offset(for: np.trackID)
        case .seeked:
            debugLog("偵測到拖動進度 → \(formatTime(np.progress))")
        case .playStateChanged:
            debugLog(np.isPlaying ? "繼續播放" : "暫停")
            pushLiveActivity()
        case .stale:
            debugLog("Spotify 進度沒有前進（\(formatTime(np.progress))），忽略並改用 /me/player 重試")
            useFullPlayer = true
        case .none:
            break
        }
        updateIdleTimer()
        tick()
    }

    private func clearPlayback() {
        nowPlaying = nil
        engine.reset()
        lyricsTask?.cancel()
        prefetchTask?.cancel()
        lines = []
        plainLyrics = nil
        hasManualLyrics = false
        display = .empty
        position = 0
        lyricsStatus = "沒有播放中的歌曲"
        updateIdleTimer()
    }

    private func setStatus(_ message: String) {
        if statusMessage != message { statusMessage = message }
    }

    // MARK: - 歌詞

    private func query(for np: NowPlaying) -> TrackQuery {
        TrackQuery(trackID: np.trackID, title: np.title, artist: np.primaryArtist,
                   album: np.album, duration: np.duration)
    }

    private func loadLyrics(for np: NowPlaying) {
        lyricsTask?.cancel()
        lines = []
        plainLyrics = nil
        display = .empty
        lyricsStatus = "搜尋歌詞中…"
        hasManualLyrics = lyricsService.hasOverride(np.trackID)
        pushLiveActivity()

        let q = query(for: np)
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.lyricsService.lyrics(for: q)
            guard !Task.isCancelled, self.nowPlaying?.trackID == np.trackID else { return }
            self.apply(result)
            self.prefetchNext()
        }
    }

    private func apply(_ result: LyricsResult) {
        lines = []
        plainLyrics = nil
        display = .empty
        switch result {
        case .synced(let lrc):
            lines = LRCParser.parse(lrc)
            lyricsStatus = "同步歌詞（\(lines.count) 行）"
        case .plain(let text):
            plainLyrics = text
            lyricsStatus = "只有未同步歌詞"
        case .instrumental:
            lyricsStatus = "純音樂"
        case .notFound:
            lyricsStatus = "找不到歌詞"
        case .failed(let message):
            lyricsStatus = "歌詞載入失敗：\(message)"
        }
        debugLog("歌詞：\(lyricsStatus)")
        tick()
        pushLiveActivity()
    }

    func clearLyricsCache() {
        lyricsService.clearCache()
        debugLog("已清除歌詞快取（手動指定的歌詞保留）")
        if let np = nowPlaying { loadLyrics(for: np) }
    }

    // MARK: 手動選擇 / 匯入歌詞

    func lyricsCandidates() async -> [LRCLIBTrack] {
        guard let np = nowPlaying else { return [] }
        return await lyricsService.candidates(for: query(for: np))
    }

    func searchLyrics(_ text: String) async -> [LRCLIBTrack] {
        await lyricsService.search(text: text, duration: nowPlaying?.duration ?? 0)
    }

    func useCandidate(_ track: LRCLIBTrack) {
        guard let np = nowPlaying, let result = lyricsService.result(from: track) else { return }
        // 停止進行中的自動搜尋，避免之後覆蓋使用者的選擇
        lyricsTask?.cancel()
        lyricsService.setOverride(result, trackID: np.trackID)
        hasManualLyrics = true
        debugLog("手動選擇 LRCLIB #\(track.id)")
        apply(result)
    }

    /// 匯入 LRC（或純文字）檔，綁定到目前這首歌
    func importLyrics(_ text: String) {
        guard let np = nowPlaying else { return }
        lyricsTask?.cancel()
        let result: LyricsResult = LRCParser.parse(text).isEmpty ? .plain(text) : .synced(text)
        lyricsService.setOverride(result, trackID: np.trackID)
        hasManualLyrics = true
        debugLog("已匯入歌詞檔（\(result.shortDescription)）")
        apply(result)
    }

    /// 取消手動指定，改回自動搜尋
    func resetManualLyrics() {
        guard let np = nowPlaying else { return }
        lyricsService.removeOverride(np.trackID)
        debugLog("已取消手動指定的歌詞")
        loadLyrics(for: np)
    }

    /// 點完整歌詞的某一句 → Spotify 跳到那個時間點
    func seek(toLine index: Int) {
        guard lines.indices.contains(index) else { return }
        let target = max(0, lines[index].time - offset - songOffset)
        control(.seek(ms: Int(target * 1000)))
    }

    private func updateIdleTimer() {
        let disable = keepScreenOn && isForeground && (nowPlaying?.isPlaying ?? false)
        if UIApplication.shared.isIdleTimerDisabled != disable {
            UIApplication.shared.isIdleTimerDisabled = disable
        }
    }

    /// 以本地時鐘推算目前位置，更新畫面上的目前句 / 下一句。
    /// 回傳到下一次換句的秒數（最多 1 秒），讓 tick 迴圈剛好在換句時醒來。
    @discardableResult
    private func tick() -> TimeInterval {
        guard let pos = engine.position(at: Date()) else { return 1 }
        if abs(position - pos) >= 0.05 { position = pos }
        let effective = pos + offset + songOffset
        let d = LyricsDisplay(lines: lines, position: effective)
        if d != display {
            display = d
            pushLiveActivity()
        }
        guard engine.snapshot?.isPlaying == true, let next = lines.nextChangeTime(after: effective) else { return 1 }
        return min(1, max(0.02, next - effective + 0.01))
    }

    // MARK: - Live Activity

    /// - Parameter allowPlaceholder: 還沒有播放資訊時，也先開一個「連接中」的 Live Activity
    private func pushLiveActivity(allowPlaceholder: Bool = false) {
        guard liveActivityEnabled, auth.isLoggedIn else { return }
        guard let np = nowPlaying else {
            if allowPlaceholder {
                liveActivity.update(LyricsActivityAttributes.ContentState(
                    currentLine: "連接 Spotify 中…", nextLine: "", trackName: "CarLyrics",
                    artistName: "", isPlaying: false))
            }
            return
        }
        let current: String
        let next: String
        if !lines.isEmpty {
            current = display.current.isEmpty ? "♪" : display.current
            next = display.next
        } else {
            // 沒有同步歌詞時顯示歌名 / 歌手，比狀態文字有用
            current = np.title
            next = lyricsStatus == "搜尋歌詞中…" ? "搜尋歌詞中…" : np.artist
        }
        liveActivity.update(LyricsActivityAttributes.ContentState(
            currentLine: current,
            nextLine: next,
            trackName: np.title,
            artistName: np.artist,
            isPlaying: np.isPlaying
        ))
    }

    private func pushStoppedLiveActivity() {
        guard liveActivityEnabled, liveActivity.isActive else { return }
        liveActivity.update(LyricsActivityAttributes.ContentState(
            currentLine: "Spotify 沒有在播放", nextLine: "", trackName: "CarLyrics",
            artistName: "", isPlaying: false))
    }

    // MARK: - 預先載入下一首歌詞

    private func prefetchNext() {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self, let next = await self.api.nextInQueue(), !Task.isCancelled,
                  next.trackID != self.nowPlaying?.trackID,
                  next.trackID != self.prefetchedTrackID else { return }
            self.prefetchedTrackID = next.trackID
            let result = await self.lyricsService.lyrics(for: self.query(for: next))
            guard !Task.isCancelled else { return }
            debugLog("預先載入下一首：\(next.title)（\(result.shortDescription)）")
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
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.heartbeatKey)
        UserDefaults.standard.set(!isForeground, forKey: Self.heartbeatBackgroundKey)
    }

    func resetPollStats() {
        maxPollGap = 0
    }

    /// 啟動時檢查上次的心跳：若當時在背景執行且很久沒更新，記一筆
    private func checkPreviousHeartbeat() {
        let t = UserDefaults.standard.double(forKey: Self.heartbeatKey)
        guard t > 0, UserDefaults.standard.bool(forKey: Self.heartbeatBackgroundKey) else { return }
        let last = Date(timeIntervalSince1970: t)
        if Date().timeIntervalSince(last) > 60 {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm:ss"
            debugLog("上次背景執行最後一次輪詢在 \(f.string(from: last))，之後疑似被系統終止")
        }
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return String(format: "%ld:%02ld", s / 60, s % 60)
}
