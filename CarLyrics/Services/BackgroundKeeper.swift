import AVFoundation
import Foundation

/// 讓 App 在背景持續執行：以 .mixWithOthers 循環播放「無聲」音訊，
/// 不會打斷 Spotify，也不會出現在「正在播放」。
@MainActor
final class BackgroundKeeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private(set) var isRunning = false
    private var observers: [NSObjectProtocol] = []

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                debugLog("音訊服務重置，重新啟動背景音訊")
                self?.restart()
            }
        })
    }

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let frames = AVAudioFrameCount(format.sampleRate)   // 1 秒
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            if let channels = buffer.floatChannelData {
                for c in 0..<Int(format.channelCount) {
                    channels[c].update(repeating: 0, count: Int(frames))
                }
            }

            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            isRunning = true
            debugLog("背景音訊已啟動")
        } catch {
            debugLog("背景音訊啟動失敗：\(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
        debugLog("背景音訊已停止")
    }

    private func restart() {
        player.stop()
        engine.stop()
        isRunning = false
        start()
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            debugLog("音訊被中斷（例如來電）")
            isRunning = false
        case .ended:
            debugLog("中斷結束，恢復背景音訊")
            restart()
        @unknown default:
            break
        }
    }
}
