import AVFoundation
import Foundation

/// 讓 App 在背景持續執行：以 .mixWithOthers 循環播放「無聲」音訊，
/// 不會打斷 Spotify，也不會出現在「正在播放」。
///
/// 會自我修復：
/// - 接上 CarPlay / 藍牙 / AirPods 等路由或取樣率改變時，AVAudioEngine 會自己停止
///   （`AVAudioEngineConfigurationChange`）→ 重新啟動
/// - 中斷（來電、Siri）結束通知不一定會送達 → 由 `ensureRunning()`（每次輪詢呼叫）補救
/// - media services reset → 重新建立 engine / player
@MainActor
final class SilentAudioKeeper {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private lazy var silence: AVAudioPCMBuffer? = makeSilence()

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
    /// 中斷結束時通知 AppModel（重新計算閒置時間）
    var onInterruptionEnded: (() -> Void)?
    /// 接上 / 離開車用音訊（CarPlay、車用藍牙）
    var onCarConnectionChanged: ((Bool) -> Void)?

    /// 目前的輸出是不是車上的音響
    private(set) var isCarConnected = SilentAudioKeeper.detectCar()

    static func detectCar() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    private func updateCarConnection() {
        let car = Self.detectCar()
        guard car != isCarConnected else { return }
        isCarConnected = car
        debugLog(car ? "車用音訊：已連接" : "車用音訊：已離開")
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
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
                debugLog("音訊路由改變（reason \(reason)）")
                self?.updateCarConnection()
                self?.ensureRunning()
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
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart(reason: "音訊引擎設定改變（路由 / 取樣率）") }
        }
    }

    private func startInternal() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let engineWasStopped = !engine.isRunning
            if engineWasStopped { try engine.start() }
            // 引擎曾停止時，player 的狀態不可靠 → 一律重新排程
            if engineWasStopped || !player.isPlaying, let silence {
                player.stop()
                player.scheduleBuffer(silence, at: nil, options: .loops)
                player.play()
            }
            lastAttemptAt = nil
            interrupted = false
            debugLog("背景音訊執行中")
        } catch {
            debugLog("背景音訊啟動失敗：\(error.localizedDescription)")
        }
    }

    private func restart(reason: String, recreate: Bool = false) {
        guard wantsRunning else { return }
        lastAttemptAt = Date()
        restartCount += 1
        lastRestartReason = reason
        lastRestartAt = Date()
        debugLog("背景音訊重啟：\(reason)")
        player.stop()
        engine.stop()
        if recreate {
            buildGraph()
            silence = makeSilence()
        }
        startInternal()
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
