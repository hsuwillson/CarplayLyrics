import Foundation

/// 輪詢結果 → 狀態轉換 + 要執行的動作。
/// 這一層以前埋在 AppModel 裡（廣告、沒在播放、換歌的順序錯誤都出在這），
/// 抽成純函式後可以用「事件序列 → 動作序列」直接測試。
/// 對照表在 docs/event-effects.md。
struct PlaybackState: Equatable, Sendable {
    var session: SessionState = .connecting
    var nowPlaying: NowPlaying?
    var engine = LyricsSyncEngine()
    var optimistic = OptimisticGuard()
    /// 閒置起算時間與種類
    var idleSince: Date?
    var idleKind: IdlePolicy.Kind?
    /// 連續幾次「沒在播放」；要連續 2 次才清空畫面
    var emptyResponseStreak = 0
    var errorStreak = 0
    /// 配額用完後降低頻率，到這個時間為止
    var quotaModeUntil = Date.distantPast
    /// 下一次改用 /me/player（回傳過期資料時）
    var preferFullPlayerEndpoint = false
    /// 最後一次採用的輪詢請求送出時間
    var lastAcceptedSentAt = Date.distantPast
    /// 已經因為閒置結束過即時動態（避免重複送出結束）
    var activityEndedForIdle = false
    /// 這一輪（App 開始輪詢以來）是否播過歌；還沒播過就不因閒置收起即時動態
    var hasPlayed = false
    /// 這個時間之前維持最快的輪詢（剛換歌 / 拖動 / 暫停 / 使用者操作）
    var hotUntil = Date.distantPast
    /// 「沒在播放」清空畫面時記住的上一首與時刻：Spotify 暫停一陣子後會回 204（尤其在車上），
    /// 同一首在 `resumeSameTrackWithin` 內回來時不當成換歌（歌詞不重載、不重新搜尋）
    var parkedTrack: NowPlaying?
    var parkedAt: Date?

    func isHot(now: Date) -> Bool { now < hotUntil }

    /// 剛發生變化：接下來一小段時間問快一點，才接得住連續操作
    mutating func markHot(at now: Date, for seconds: TimeInterval = 10) {
        hotUntil = max(hotUntil, now.addingTimeInterval(seconds))
    }

    func idleDuration(now: Date) -> TimeInterval {
        idleSince.map { now.timeIntervalSince($0) } ?? 0
    }

    func quotaActive(now: Date) -> Bool { now < quotaModeUntil }

    mutating func markIdle(_ kind: IdlePolicy.Kind, at now: Date) {
        guard idleKind != kind else { return }
        idleKind = kind
        idleSince = now
    }

    mutating func clearIdle() {
        idleKind = nil
        idleSince = nil
        activityEndedForIdle = false
    }

    /// 閒置計時從現在重新起算（種類不變），並允許再收一次即時動態。
    /// 上車、即時動態開始、回到前景、閒置停止後重新輪詢時呼叫：這些時刻使用者顯然「回來了」，
    /// 不能把幾十分鐘前開始累積的閒置算在新開的即時動態頭上（build 45 實測：上車 1 秒後就被收掉）。
    /// - Returns: 原本已累積的閒置秒數；沒有在閒置時 nil
    @discardableResult
    mutating func restartIdleClock(at now: Date) -> TimeInterval? {
        activityEndedForIdle = false
        guard idleKind != nil, let since = idleSince else { return nil }
        idleSince = now
        return now.timeIntervalSince(since)
    }
}

/// AppModel 要執行的動作（畫面、即時動態、小工具、背景執行）
enum PlaybackEffect: Equatable, Sendable {
    case log(String)
    /// 換歌：套用這首歌的延遲、載入歌詞與封面
    case newTrack(NowPlaying)
    /// 「沒在播放」之後同一首回來了：套用延遲與封面，歌詞還在就沿用（不重載）
    case resumeTrack(NowPlaying)
    /// 沒在播放：清空畫面（歌詞先留著，同一首回來時沿用）
    case clearPlayback
    case pushStopped
    case pushNonMusic(NonMusicKind)
    /// 推送目前歌曲的內容
    case pushCurrent(important: Bool)
    case endActivity
    case publishIdle(String)
    case publishTimeline(debounce: Bool)
    /// 只有進度漂移：重寫檔案，不佔用重新整理額度
    case refreshTimelineFile
    case rescheduleTick
    /// 閒置太久：結束即時動態、停止背景執行（參數是門檻分鐘數，寫進紀錄）
    case stopForIdle(minutes: Int)
}

struct PlaybackReducer: Sendable {
    var idlePolicy = IdlePolicy()
    var pollPolicy = PollPolicy()
    /// 「沒在播放」之後多久內同一首回來算「繼續播放」而不是換歌（與暫停的閒置門檻相同）
    var resumeSameTrackWithin: TimeInterval = 1800

    struct Output: Equatable, Sendable {
        var effects: [PlaybackEffect] = []
        /// 下一次輪詢前要等待的秒數
        var delay: TimeInterval = 2.5
    }

    struct Context: Sendable {
        var now: Date
        /// 同步引擎用的單調時鐘（測試時與 now 相同）
        var monotonicNow: Date
        var isForeground: Bool
        var carConnected: Bool
        var activityIsActive: Bool
        /// 沒在播放時結束即時動態，不要一直佔用動態島
        var endActivityWhenIdle: Bool
        /// 使用者看得到什麼（決定輪詢頻率）
        var surface: PollPolicy.Surface
        /// 音訊被中斷中（電話、Siri）：Spotify 只是被迫暫停，講完會自動續播，
        /// 這段時間不算閒置（不收即時動態、不停止背景執行）
        var interrupted: Bool

        init(now: Date, monotonicNow: Date? = nil, isForeground: Bool = false,
             carConnected: Bool = false, activityIsActive: Bool = true,
             endActivityWhenIdle: Bool = false, surface: PollPolicy.Surface = .foreground,
             interrupted: Bool = false) {
            self.now = now
            self.monotonicNow = monotonicNow ?? now
            self.isForeground = isForeground
            self.carConnected = carConnected
            self.activityIsActive = activityIsActive
            self.endActivityWhenIdle = endActivityWhenIdle
            self.surface = surface
            self.interrupted = interrupted
        }
    }

    func reduce(_ state: inout PlaybackState, result: PlayerPollResult, context: Context) -> Output {
        switch result {
        case .playing(let np, let measuredAt, let sentAt):
            return playing(&state, np: np, measuredAt: measuredAt, sentAt: sentAt, context: context)
        case .nonMusic(let kind, let playing):
            return nonMusic(&state, kind: kind, playing: playing, context: context)
        case .nothing:
            return nothing(&state, context: context)
        case .rateLimited(let retryAfter, let quotaExceeded):
            var output = Output()
            output.effects.append(.log("HTTP 429，Retry-After \(Int(retryAfter)) 秒\(quotaExceeded ? "（配額用完）" : "")"))
            if quotaExceeded { state.quotaModeUntil = context.now.addingTimeInterval(3600) }
            output.delay = pollPolicy.delay(for: .rateLimited(retryAfter: retryAfter, quotaExceeded: quotaExceeded))
            return output
        }
    }

    /// 輪詢錯誤：回傳等待秒數，必要時停止背景執行
    func error(_ state: inout PlaybackState, context: Context) -> Output {
        var output = Output()
        state.errorStreak += 1
        output.delay = pollPolicy.delay(for: .error(streak: state.errorStreak))
        appendIdleStop(&output, &state, context: context)
        return output
    }

    // MARK: - 播放中

    private func playing(_ state: inout PlaybackState, np: NowPlaying, measuredAt: Date, sentAt: Date,
                         context: Context) -> Output {
        var output = Output()
        // 比較舊的請求比較晚回來 → 丟掉，避免歌詞跳回舊位置
        guard sentAt > state.lastAcceptedSentAt else {
            output.effects.append(.log("丟棄過期的輪詢回應"))
            output.delay = 1
            return output
        }
        state.lastAcceptedSentAt = sentAt
        state.errorStreak = 0
        state.emptyResponseStreak = 0
        let leavingNonMusic = state.session.isNonMusic

        let snapshot = PlaybackSnapshot(trackID: np.trackID, progress: np.progress, duration: np.duration,
                                        isPlaying: np.isPlaying, timestamp: measuredAt)
        // 樂觀更新保護窗內，與目前狀態矛盾的回應視為 Spotify 還沒套用（session 也不能跟著翻，
        // 否則按了暫停之後狀態列會先閃一下「播放中」）
        if state.optimistic.shouldIgnore(current: state.engine.snapshot, incoming: snapshot, now: context.monotonicNow) {
            output.effects.append(.log("樂觀更新保護：忽略延遲的回應"))
            state.preferFullPlayerEndpoint = true
            output.delay = pollPolicy.delay(for: .playing(isPlaying: np.isPlaying, remaining: nil),
                                            quotaActive: state.quotaActive(now: context.now),
                                            preferFullPlayer: true)
            return output
        }
        // session 要在動作之前更新：廣告結束接回音樂時，推送不能被 .nonMusic 擋掉
        state.session = np.isPlaying ? .playing : .paused

        let change = state.engine.update(snapshot)
        state.nowPlaying = np
        if np.isPlaying { state.hasPlayed = true }
        if change != .none && change != .stale { state.markHot(at: context.now) }
        // 「沒在播放」（連續 204）之後同一首回來：Spotify 暫停久一點就會回 204，這不是換歌
        let parkedFor: TimeInterval? = {
            guard change == .newTrack, state.parkedTrack?.trackID == np.trackID, let at = state.parkedAt else { return nil }
            let gap = context.now.timeIntervalSince(at)
            return gap <= resumeSameTrackWithin ? gap : nil
        }()
        state.parkedTrack = nil
        state.parkedAt = nil

        switch change {
        case .newTrack:
            if let parkedFor {
                let seconds = Int(parkedFor)
                let phase = np.isPlaying ? "播放中" : "暫停中"
                output.effects.append(.log("同一首回來了（\(phase)；Spotify 回報沒在播放 \(seconds) 秒），沿用歌詞"))
                output.effects.append(.resumeTrack(np))
                output.effects.append(.pushCurrent(important: true))
                output.effects.append(.rescheduleTick)
                output.effects.append(.publishTimeline(debounce: false))
            } else {
                output.effects.append(.log("換歌：\(np.title) – \(np.artist)"))
                output.effects.append(.newTrack(np))
                output.effects.append(.publishTimeline(debounce: true))
            }
        case .seeked:
            output.effects.append(.log("偵測到拖動進度 → \(formatTime(np.progress))"))
            output.effects.append(.pushCurrent(important: true))
            output.effects.append(.rescheduleTick)
            output.effects.append(.publishTimeline(debounce: false))
        case .playStateChanged:
            output.effects.append(.log(np.isPlaying ? "繼續播放" : "暫停"))
            output.effects.append(.pushCurrent(important: true))
            output.effects.append(.rescheduleTick)
            output.effects.append(.publishTimeline(debounce: true))
        case .stale:
            output.effects.append(.log("Spotify 進度沒有前進（\(formatTime(np.progress))），忽略並改用 /me/player 重試"))
            state.preferFullPlayerEndpoint = true
            output.effects.append(.refreshTimelineFile)
        case .none:
            // 只是進度微調 → 重寫檔案讓小工具對齊，不佔重新整理額度
            output.effects.append(.refreshTimelineFile)
        }
        if leavingNonMusic, change == .none || change == .stale {
            // 廣告結束後回到同一首歌：立刻把正確內容推回去
            output.effects.append(.pushCurrent(important: true))
            output.effects.append(.publishTimeline(debounce: false))
        }

        if np.isPlaying {
            state.clearIdle()
        } else {
            state.markIdle(.paused, at: context.now)
        }
        if appendIdleStop(&output, &state, context: context) { return output }
        appendActivityEndForIdle(&output, &state, context: context)

        let remaining: TimeInterval? = {
            guard let pos = state.engine.position(at: context.monotonicNow), np.duration > 0 else { return nil }
            return np.duration - pos
        }()
        output.delay = pollPolicy.delay(for: .playing(isPlaying: np.isPlaying, remaining: remaining),
                                        quotaActive: state.quotaActive(now: context.now),
                                        preferFullPlayer: state.preferFullPlayerEndpoint,
                                        surface: context.surface, hot: state.isHot(now: context.now),
                                        idleFor: state.idleDuration(now: context.now))
        return output
    }

    // MARK: - 廣告 / Podcast

    private func nonMusic(_ state: inout PlaybackState, kind: NonMusicKind, playing: Bool,
                          context: Context) -> Output {
        var output = Output()
        state.errorStreak = 0
        state.emptyResponseStreak = 0
        // 保留上一首的歌詞，廣告後的下一首會自然接手
        if state.session != .nonMusic(kind) {
            state.session = .nonMusic(kind)
            output.effects.append(.log(kind.label))
            output.effects.append(.pushNonMusic(kind))
            output.effects.append(.publishIdle(kind.label))
        }
        // 播放中的廣告 / Podcast 用 60 分鐘門檻；暫停後回到 30 分鐘
        state.markIdle(playing ? .nonMusic : .paused, at: context.now)
        if appendIdleStop(&output, &state, context: context) { return output }
        output.delay = pollPolicy.delay(for: .nonMusic, quotaActive: state.quotaActive(now: context.now),
                                        idleFor: state.idleDuration(now: context.now))
        return output
    }

    // MARK: - 沒有在播放

    private func nothing(_ state: inout PlaybackState, context: Context) -> Output {
        var output = Output()
        state.errorStreak = 0
        state.emptyResponseStreak += 1
        // 偶發的 204（切歌、切換裝置）不要立刻清空
        guard state.emptyResponseStreak >= 2 else {
            output.delay = pollPolicy.delay(for: .nothing(streak: state.emptyResponseStreak))
            return output
        }
        if let np = state.nowPlaying {
            output.effects.append(.log("Spotify 沒有在播放"))
            output.effects.append(.clearPlayback)
            // 記住這首：暫停久了 Spotify 會回 204，同一首回來時不當成換歌
            state.parkedTrack = np
            state.parkedAt = context.now
            state.nowPlaying = nil
            state.engine.reset()
        }
        // 只在狀態改變時推送，否則每 10 秒就會重新整理一次小工具、白白用掉額度
        if state.session != .notPlaying {
            state.session = .notPlaying
            if context.activityIsActive { output.effects.append(.pushStopped) }
            output.effects.append(.publishIdle("Spotify 沒有在播放"))
        }
        state.markIdle(.nothing, at: context.now)
        if appendIdleStop(&output, &state, context: context) { return output }
        appendActivityEndForIdle(&output, &state, context: context)
        // 車上：暫停後 Spotify 回 204 很常見，而且多半很快就續播 → 問得勤一點（手機多半在充電）
        output.delay = pollPolicy.delay(for: .nothing(streak: state.emptyResponseStreak),
                                        idleFor: state.idleDuration(now: context.now), inCar: context.carConnected)
        return output
    }

    // MARK: - 閒置

    /// 閒置一段時間 → 結束即時動態（動態島不要一直被佔用）。
    /// 與 appendIdleStop 不同：前景也會做，而且不停止背景執行，
    /// 下次 Spotify 開始播放時 App 會重新開一個即時動態。
    /// 音訊中斷中（講電話）不算閒置：講完 Spotify 會自動續播，收掉的話背景開不回來。
    @discardableResult
    private func appendActivityEndForIdle(_ output: inout Output, _ state: inout PlaybackState,
                                          context: Context) -> Bool {
        guard !context.interrupted else { return false }
        guard context.endActivityWhenIdle, context.activityIsActive, !state.activityEndedForIdle,
              let kind = state.idleKind, let since = state.idleSince,
              idlePolicy.shouldEndActivity(kind: kind, since: since, now: context.now,
                                           carConnected: context.carConnected, hasPlayed: state.hasPlayed)
        else { return false }
        state.activityEndedForIdle = true
        output.effects.append(.endActivity)
        return true
    }

    /// 閒置太久 → 加上停止的動作，回傳 true（音訊中斷中不算閒置）
    @discardableResult
    private func appendIdleStop(_ output: inout Output, _ state: inout PlaybackState, context: Context) -> Bool {
        guard !context.interrupted else { return false }
        guard let kind = state.idleKind, let since = state.idleSince,
              idlePolicy.shouldStop(kind: kind, since: since, now: context.now,
                                    isForeground: context.isForeground, carConnected: context.carConnected)
        else { return false }
        let minutes = Int(idlePolicy.limit(for: kind, carConnected: context.carConnected) / 60)
        if context.activityIsActive { output.effects.append(.endActivity) }
        output.effects.append(.publishIdle("打開 CarLyrics 繼續同步歌詞"))
        output.effects.append(.stopForIdle(minutes: minutes))
        output.delay = pollPolicy.delay(for: .idleStopped)
        return true
    }
}

/// 秒數 → m:ss（畫面與紀錄共用）
func formatTime(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return String(format: "%ld:%02ld", s / 60, s % 60)
}
