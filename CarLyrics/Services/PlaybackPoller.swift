import Foundation

/// 輪詢迴圈：只保留一個迴圈（用 generation 讓舊迴圈自行結束），
/// 每次執行 `body` 並依回傳的秒數等待；`pollNow()` 取消等待立刻再查一次。
@MainActor
final class PlaybackPoller {
    private var task: Task<Void, Never>?
    private var generation = 0
    private var body: (@MainActor () async -> TimeInterval)?

    var isRunning: Bool { task != nil }

    func start(_ body: @escaping @MainActor () async -> TimeInterval) {
        self.body = body
        guard task == nil else { return }
        run()
    }

    /// 取消目前的等待，立刻重新輪詢（播放控制、恢復連線後使用）
    func pollNow() {
        guard task != nil else { return }
        task?.cancel()
        run()
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
    }

    private func run() {
        generation += 1
        let current = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, current == self.generation, let body = self.body else { return }
                let delay = await body()
                guard current == self.generation else { return }
                try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(300))
            }
        }
    }
}
