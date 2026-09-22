import SwiftUI
import WidgetKit

/// 歌詞小工具（CarPlay 小工具頁、主畫面、鎖定畫面）。
/// App 換歌 / 拖動 / 暫停時寫入整首歌的時間軸並呼叫 reloadTimelines，
/// 之後每一句由系統依時間自動切換，不需要 App 在背景更新。
struct LyricsEntry: TimelineEntry {
    let date: Date
    let current: String
    let next: String
    let title: String
    let isPlaying: Bool
}

struct LyricsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LyricsEntry {
        LyricsEntry(date: .now, current: "CarLyrics", next: "同步歌詞", title: "CarLyrics", isPlaying: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (LyricsEntry) -> Void) {
        completion(entries(now: .now).first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricsEntry>) -> Void) {
        let list = entries(now: .now)
        // App 在狀態改變時會主動 reload，所以時間軸播完就停
        completion(Timeline(entries: list.isEmpty ? [placeholder(in: context)] : list, policy: .never))
    }

    private func entries(now: Date) -> [LyricsEntry] {
        let snapshot = LyricsTimelineStore.load() ?? .idle("打開 CarLyrics 開始同步歌詞", at: now)
        return snapshot.frames(from: now).map {
            LyricsEntry(date: $0.date, current: $0.current, next: $0.next,
                        title: snapshot.title, isPlaying: snapshot.isPlaying)
        }
    }
}

struct LyricsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricsEntry

    var body: some View {
        content
            .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular:
            // 鎖定畫面
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.current)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if !entry.next.isEmpty {
                    Text(entry.next)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            // CarPlay 小工具頁 / 主畫面：大字、最多兩行
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: entry.isPlaying ? "music.note" : "pause.fill")
                        .foregroundStyle(.green)
                    Text(entry.title)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                Text(entry.current)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                if !entry.next.isEmpty {
                    Text(entry.next)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct LyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LyricsTimelineStore.widgetKind, provider: LyricsProvider()) { entry in
            LyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("CarLyrics 歌詞")
        .description("逐句顯示 Spotify 正在播放的歌詞（CarPlay 小工具頁、鎖定畫面）")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}
