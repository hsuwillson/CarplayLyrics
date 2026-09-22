import ActivityKit
import SwiftUI
import WidgetKit

/// 歌詞 Live Activity
/// - 鎖定畫面：歌名列 + 目前句（大字、最多兩行）+ 下一句
/// - CarPlay / Apple Watch：`.small` activity family（iOS 26 CarPlay 使用這個尺寸），只放目前句 + 下一句
/// - 靈動島：compact 顯示目前句，expanded 顯示目前句 + 下一句
struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsActivityView(state: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PlayingIcon(isPlaying: context.state.isPlaying)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.trackName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedLyrics(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                PlayingIcon(isPlaying: context.state.isPlaying)
            } compactTrailing: {
                Text(context.state.currentLine)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 110)
            } minimal: {
                PlayingIcon(isPlaying: context.state.isPlaying)
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - 共用小元件

/// 播放中：綠色音符；暫停：灰色暫停符號
private struct PlayingIcon: View {
    let isPlaying: Bool

    var body: some View {
        Image(systemName: isPlaying ? "music.note" : "pause.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isPlaying ? Color.green : Color.secondary)
    }
}

/// 靈動島展開區：目前句 + 下一句
private struct ExpandedLyrics: View {
    let state: LyricsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(state.currentLine)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .foregroundStyle(isStale ? Color.secondary : Color.primary)
            if isStale {
                Text("歌詞未更新，請打開 CarLyrics")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if !state.nextLine.isEmpty {
                Text(state.nextLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 鎖定畫面 / CarPlay

private struct LyricsActivityView: View {
    @Environment(\.activityFamily) private var activityFamily
    let state: LyricsActivityAttributes.ContentState
    /// App 超過 staleDate 沒有更新（可能被系統終止）
    let isStale: Bool

    var body: some View {
        switch activityFamily {
        case .small:
            SmallActivityView(state: state, isStale: isStale)
        default:
            LockScreenActivityView(state: state, isStale: isStale)
        }
    }
}

/// CarPlay 儀表板 / Apple Watch：字要大，只放目前句 + 下一句
private struct SmallActivityView: View {
    let state: LyricsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(state.currentLine)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.65)
                .foregroundStyle(isStale ? Color.secondary : Color.primary)
            Spacer(minLength: 0)
            if isStale {
                Text("歌詞未更新，請打開 CarLyrics")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if !state.nextLine.isEmpty {
                HStack(spacing: 5) {
                    if !state.isPlaying {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 11))
                    }
                    Text(state.nextLine)
                        .font(.system(size: 14))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
    }
}

/// 鎖定畫面
private struct LockScreenActivityView: View {
    let state: LyricsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(state.currentLine)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isStale ? Color.secondary : Color.primary)
            if isStale {
                Text("歌詞未更新，請打開 CarLyrics")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            } else if !state.nextLine.isEmpty {
                Text(state.nextLine)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 6) {
            PlayingIcon(isPlaying: state.isPlaying)
            Text(state.trackName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if !state.artistName.isEmpty {
                Text("· \(state.artistName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
