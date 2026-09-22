import ActivityKit
import Foundation

/// 管理歌詞 Live Activity（鎖定畫面、靈動島、CarPlay）
@MainActor
final class LiveActivityManager {
    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: LyricsActivityAttributes.ContentState?

    var isActive: Bool {
        activity?.activityState == .active
    }

    /// App 啟動時接手之前留下來的 Live Activity，多的就結束
    func adoptExisting() {
        let existing = Activity<LyricsActivityAttributes>.activities
        if activity == nil, let first = existing.first(where: { $0.activityState == .active }) {
            activity = first
            debugLog("接手既有的 Live Activity")
        }
        for extra in existing where extra.id != activity?.id {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func update(_ state: LyricsActivityAttributes.ContentState) {
        if !isActive {
            activity = nil
            lastState = nil
            start(state)
            return
        }
        guard state != lastState, let activity else { return }
        lastState = state
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.update(content) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        debugLog("Live Activity 已結束")
    }

    private func start(_ state: LyricsActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: LyricsActivityAttributes(sessionID: UUID().uuidString),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastState = state
            debugLog("Live Activity 已開始")
        } catch {
            // iOS 只允許 App 在前景時開始 Live Activity；背景失敗時，下次回到前景會再試
            debugLog("Live Activity 無法開始：\(error.localizedDescription)")
        }
    }
}
