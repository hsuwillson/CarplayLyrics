import ActivityKit
import SwiftUI
import WidgetKit

/// 歌詞 Live Activity
/// - 鎖定畫面：目前句（大字、最多兩行）+ 下一句
/// - CarPlay / Apple Watch：`.small` activity family（iOS 26 CarPlay 使用這個尺寸）
/// - 靈動島：compact 顯示目前句，expanded 顯示目前句 + 下一句
struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsActivityView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPlaying ? "music.note" : "pause.fill")
                        .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.trackName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        Text(context.state.currentLine)
                            .font(.title3.bold())
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        if !context.state.nextLine.isEmpty {
                            Text(context.state.nextLine)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundStyle(.green)
            } compactTrailing: {
                Text(context.state.currentLine)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 110)
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundStyle(.green)
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct LyricsActivityView: View {
    @Environment(\.activityFamily) private var activityFamily
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        switch activityFamily {
        case .small:
            // CarPlay 儀表板 / Apple Watch：字要大，只放目前句 + 下一句
            VStack(alignment: .leading, spacing: 4) {
                Text(state.currentLine)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if !state.nextLine.isEmpty {
                    Text(state.nextLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(8)
        default:
            // 鎖定畫面
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: state.isPlaying ? "music.note" : "pause.fill")
                        .foregroundStyle(.green)
                    Text("\(state.trackName) · \(state.artistName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(state.currentLine)
                    .font(.title2.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if !state.nextLine.isEmpty {
                    Text(state.nextLine)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
