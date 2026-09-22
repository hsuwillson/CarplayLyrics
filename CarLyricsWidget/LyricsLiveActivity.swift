import ActivityKit
import SwiftUI
import WidgetKit

// 階段 1 佔位版本；階段 5 會調整 CarPlay 版面。
struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.currentLine)
                    .font(.title3.bold())
                    .lineLimit(2)
                Text(context.state.nextLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.currentLine)
                        .font(.headline)
                        .lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Text(context.state.trackName).lineLimit(1)
            } minimal: {
                Image(systemName: "music.note")
            }
        }
    }
}
