import AVFoundation
import Foundation

/// 讓 App 在背景持續執行：以 .mixWithOthers 循環播放「無聲」音訊，
/// 不會打斷 Spotify，也不會出現在「正在播放」。
///
/// 省電：以「單聲道 + 硬體取樣率」建立圖，避免混音器整段時間都在做取樣率轉換。
///
/// 會自我修復：
/// - 接上 CarPlay / 藍牙 / AirPods 等路由或取樣率改變時，AVAudioEngine 會自己停止
///   （`AVAudioEngineConfigurationChange`）→ 延遲 0.5 秒合併同一波通知後，必要時才重新啟動
/// - 中斷（來電、Siri）結束通知不一定會送達 → 由 `ensureRunning()`（每次輪詢呼叫）補救
/// - media services reset → 重新建立 engine / player
@MainActor
final class SilentAudioKeeper {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    /// player → mainMixer 的格式：單聲道、硬體取樣率（`connectPlayer()` 會依硬體更新）
    private var format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private var silence: AVAudioPCMBuffer?

    /// 使用者希望背景執行（意圖）；實際狀態看 `isRunning`
    private(set) var wantsRunning = false
    private(set) var restartCount = 0
    private(set) var lastRestartReason: String?
    private(set) var lastRestartAt: Date?

    /// 目前被來電 / Siri 中斷中
    private(set) var interrupted = false
    /// 上次嘗試重啟的時間（節流用）
    private var lastAttemptAt: Date?
    private static let retryInterval: TimeInterval = 20
    /// 設定 / 路由改變通知常常一次來一串：延遲這麼久再檢查，合併成一次重啟
    private static let debounceNanoseconds: UInt64 = 500_000_000
    private static let configChangeReason = "設定改變"
    /// 等待中的延遲檢查（新的通知會取消並取代它）
    private var pendingCheck: Task<Void, Never>?
    private var pendingCheckReason: String?
    /// 中斷結束時通知 AppModel（重新計算閒置時間）
    var onInterruptionEnded: (() -> Void)?
    /// 接上 / 離開車用音訊（CarPlay、車用藍牙）
    var onCarConnectionChanged: ((Bool) -> Void)?

    /// 目前的輸出是不是車上的音響
    private(set) var isCarConnected = SilentAudioKeeper.detectCar()

    /// 只認 CarPlay / 車用音訊（`.carAudio`）。一般藍牙（`.bluetoothA2DP`）耳機和喇叭也會用，
    /// 不能當成在車上；車機只回報一般藍牙時，由設定頁的「現在顯示鎖定畫面歌詞」手動開
    static func detectCar() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    /// 目前音訊輸出的名稱（診斷用，例如「CarPlay」「揚聲器」或車機的藍牙名稱）
    static func outputDescription() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.isEmpty ? "（無）" : outputs.map(\.portName).joined(separator: ", ")
    }

    /// 重新確認是不是接著車用音訊；有改變才回呼。
    /// 路由改變通知只在 App 活著時送達：閒置停止後被暫停、早上才接上 CarPlay 的情況會漏掉，
    /// 所以回到前景與音訊 session 啟用成功後都要主動查一次。
    func refreshCarConnection() {
        let car = Self.detectCar()
        guard car != isCarConnected else { return }
        isCarConnected = car
        debugLog(car ? "車用音訊：已連接（\(Self.outputDescription())）" : "車用音訊：已離開（\(Self.outputDescription())）")
        onCarConnectionChanged?(car)
    }

    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?

    var isRunning: Bool {
        engine.isRunning && player.isPlaying
    }

    init() {
        buildGraph()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart(reason: "音訊服務重置", recreate: true) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
                let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
                // 只記錄裝置接上 / 移除；其他（類別改變、route config 改變…）安靜處理
                if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
                    debugLog("音訊路由改變（reason \(raw)）")
                }
                self?.refreshCarConnection()
                self?.scheduleCheck(reason: "路由改變")
            }
        })
    }

    func start() {
        wantsRunning = true
        guard !isRunning else { return }
        startInternal()
    }

    func stop() {
        wantsRunning = false
        cancelPendingCheck()
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        debugLog("背景音訊已停止")
    }

    /// 由輪詢迴圈呼叫：應該在跑卻沒在跑就重啟。
    /// 節流 20 秒，避免通話中每次輪詢都重啟失敗、洗掉除錯紀錄；
    /// 中斷中也會定期重試，以免 `.ended` 通知沒送達時永遠不恢復。
    func ensureRunning() {
        guard wantsRunning, !isRunning else { return }
        if let t = lastAttemptAt, Date().timeIntervalSince(t) < Self.retryInterval { return }
        restart(reason: interrupted ? "中斷中，定期重試" : "檢查時發現未執行")
    }

    // MARK: - 內部

    private func buildGraph() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        engine.attach(player)
        connectPlayer()
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck(reason: Self.configChangeReason) }
        }
    }

    /// 目前硬體輸出的取樣率（拿不到時退回 session 的，再不行就 48 kHz）
    private func hardwareSampleRate() -> Double {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if rate > 0 { return rate }
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        return sessionRate > 0 ? sessionRate : 48_000
    }

    /// 依硬體取樣率重建格式（單聲道）與無聲緩衝，並重新接上 player → mainMixer。
    /// 只能在 engine 停止時呼叫。
    private func connectPlayer() {
        let rate = hardwareSampleRate()
        if let newFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) {
            format = newFormat
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        silence = makeSilence()
    }

    /// 設定 / 路由改變：延遲一下再檢查，把同一波通知合併成（最多）一次重啟
    private func scheduleCheck(reason: String) {
        guard wantsRunning else { return }
        pendingCheck?.cancel()
        // 同一波裡有「設定改變」就以它為準（比較能說明重啟原因）
        if pendingCheckReason != Self.configChangeReason { pendingCheckReason = reason }
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.runPendingCheck()
        }
    }

    private func cancelPendingCheck() {
        pendingCheck?.cancel()
        pendingCheck = nil
        pendingCheckReason = nil
    }

    private func runPendingCheck() {
        let reason = pendingCheckReason ?? Self.configChangeReason
        pendingCheck = nil
        pendingCheckReason = nil
        guard wantsRunning else { return }
        let rateChanged = hardwareSampleRate() != format.sampleRate
        // 還在跑、格式也沒變 → 不用動（例如 Spotify 自己改 session 造成的通知）
        guard !isRunning || rateChanged else { return }
        // 通話中重啟一定失敗：交給有節流的 ensureRunning，避免每個通知都重試
        if interrupted && !rateChanged {
            ensureRunning()
            return
        }
        restart(reason: reason)
    }

    private func startInternal(quiet: Bool = false) {
        do {
            let session = AVAudioSession.sharedInstance()
            // 類別已經正確就不要再設（重設會再觸發路由改變通知）
            if session.category != .playback || session.mode != .default
                || !session.categoryOptions.contains(.mixWithOthers) {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            let engineWasStopped = !engine.isRunning
            if engineWasStopped {
                // 啟用 session 後硬體取樣率可能才確定 → 格式不符就重新接線，避免取樣率轉換
                if hardwareSampleRate() != format.sampleRate { connectPlayer() }
                try engine.start()
            }
            // 引擎曾停止時，player 的狀態不可靠 → 一律重新排程
            if engineWasStopped || !player.isPlaying, let silence {
                player.stop()
                player.scheduleBuffer(silence, at: nil, options: .loops)
                player.play()
            }
            lastAttemptAt = nil
            interrupted = false
            if !quiet { debugLog("背景音訊執行中（\(Int(format.sampleRate)) Hz）") }
            // session 啟用後路由才確定：補抓被暫停期間漏掉的車用音訊連接 / 離開
            refreshCarConnection()
        } catch {
            debugLog("背景音訊啟動失敗：\(error.localizedDescription)")
        }
    }

    private func restart(reason: String, recreate: Bool = false) {
        guard wantsRunning else { return }
        cancelPendingCheck()
        lastAttemptAt = Date()
        player.stop()
        engine.stop()
        let oldRate = format.sampleRate
        if recreate {
            buildGraph()
        } else if hardwareSampleRate() != oldRate {
            connectPlayer()
        }
        let newRate = format.sampleRate
        let rates = oldRate == newRate ? "\(Int(newRate)) Hz" : "\(Int(oldRate))→\(Int(newRate)) Hz"
        let detail = "\(reason)（\(rates)）"
        restartCount += 1
        lastRestartReason = detail
        lastRestartAt = Date()
        debugLog("背景音訊重啟：\(detail)")
        startInternal(quiet: true)
    }

    private func makeSilence() -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate)   // 1 秒
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        if let channels = buffer.floatChannelData {
            for c in 0..<Int(format.channelCount) {
                channels[c].update(repeating: 0, count: Int(frames))
            }
        }
        return buffer
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            interrupted = true
            debugLog("音訊被中斷（例如來電、Siri）")
        case .ended:
            interrupted = false
            lastAttemptAt = nil
            // 我們是無聲 keep-alive，不論 shouldResume 都重啟（不會干擾其他 App）
            restart(reason: "中斷結束")
            onInterruptionEnded?()
        @unknown default:
            break
        }
    }
}
