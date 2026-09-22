import SwiftUI
import WidgetKit

// 階段 1 佔位版本；階段 6 會改成讀取 App Group 裡的逐句 timeline。
struct LyricsEntry: TimelineEntry {
    let date: Date
    let line: String
}

struct LyricsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LyricsEntry {
        LyricsEntry(date: .now, line: "CarLyrics")
    }

    func getSnapshot(in context: Context, completion: @escaping (LyricsEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricsEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

struct LyricsWidgetView: View {
    let entry: LyricsEntry

    var body: some View {
        Text(entry.line)
            .font(.headline)
            .lineLimit(3)
            .minimumScaleFactor(0.6)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct LyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LyricsWidget", provider: LyricsProvider()) { entry in
            LyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("歌詞")
        .description("顯示目前播放的歌詞")
        .supportedFamilies([.systemSmall])
    }
}
