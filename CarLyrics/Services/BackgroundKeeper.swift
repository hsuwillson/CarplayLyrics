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
final class BackgroundKeeper {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private lazy var silence: AVAudioPCMBuffer? = makeSilence()

    /// 使用者希望背景執行（意圖）；實際狀態看 `isRunning`
    private(set) var wantsRunning = false
    private(set) var restartCount = 0
    private(set) var lastRestartReason: String?
    private(set) var lastRestartAt: Date?

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

    /// 由輪詢迴圈呼叫：應該在跑卻沒在跑就重啟
    func ensureRunning() {
        guard wantsRunning, !isRunning else { return }
        restart(reason: "檢查時發現未執行")
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
            if !engine.isRunning { try engine.start() }
            if !player.isPlaying, let silence {
                player.stop()
                player.scheduleBuffer(silence, at: nil, options: .loops)
                player.play()
            }
            debugLog("背景音訊執行中")
        } catch {
            debugLog("背景音訊啟動失敗：\(error.localizedDescription)")
        }
    }

    private func restart(reason: String, recreate: Bool = false) {
        guard wantsRunning else { return }
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
            debugLog("音訊被中斷（例如來電、Siri）")
        case .ended:
            // 我們是無聲 keep-alive，不論 shouldResume 都重啟（不會干擾其他 App）
            restart(reason: "中斷結束")
        @unknown default:
            break
        }
    }
}
