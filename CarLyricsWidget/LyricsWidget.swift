import SwiftUI
import WidgetKit

/// 歌詞小工具（CarPlay 小工具頁、主畫面、鎖定畫面）。
/// App 換歌 / 拖動 / 暫停時寫入整首歌的時間軸；換句時再請系統重新整理（被節流時改用段落模式）。
struct LyricsEntry: TimelineEntry {
    let date: Date
    let frame: LyricsTimelineFrame
    let title: String
    let isPlaying: Bool
    let mode: LyricsTimelineMode
    let playbackInterval: ClosedRange<Date>?
    let artworkFile: String?

    static func sample(date: Date = .now) -> LyricsEntry {
        LyricsEntry(date: date,
                    frame: LyricsTimelineFrame(date: date, index: 0, current: "示範歌詞第一句",
                                               upcoming: ["示範歌詞第二句", "示範歌詞第三句"]),
                    title: "示範歌曲", isPlaying: true, mode: .paragraph,
                    playbackInterval: date.addingTimeInterval(-60)...date.addingTimeInterval(120),
                    artworkFile: nil)
    }
}

struct LyricsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LyricsEntry {
        .sample()
    }

    func getSnapshot(in context: Context, completion: @escaping (LyricsEntry) -> Void) {
        // 小工具庫預覽：用自編示範句，比讀 App Group 好看
        if context.isPreview {
            completion(.sample())
            return
        }
        completion(entries(now: .now).first ?? .sample())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricsEntry>) -> Void) {
        LyricsTimelineStore.recordRender()
        let list = entries(now: .now)
        // App 在狀態改變時會主動重新整理，所以時間軸播完就停
        completion(Timeline(entries: list.isEmpty ? [.sample()] : list, policy: .never))
    }

    private func entries(now: Date) -> [LyricsEntry] {
        let snapshot = LyricsTimelineStore.load() ?? .idle("打開 CarLyrics 開始同步歌詞", at: now)
        return snapshot.frames(from: now).map {
            LyricsEntry(date: $0.date, frame: $0, title: snapshot.title, isPlaying: snapshot.isPlaying,
                        mode: snapshot.mode, playbackInterval: snapshot.playbackInterval,
                        artworkFile: snapshot.artworkFile)
        }
    }
}

struct LyricsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LyricsEntry

    var body: some View {
        content
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: "carlyrics://focus"))
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular:
            // 鎖定畫面
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.frame.current)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if !entry.frame.next.isEmpty {
                    Text(entry.frame.next)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            // CarPlay 小工具頁 / 主畫面：大字、最多三行
            VStack(alignment: .leading, spacing: 5) {
                header
                Text(entry.frame.current)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .lineLimit(entry.mode == .paragraph ? 2 : 3)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                ForEach(Array(entry.frame.upcoming.enumerated()), id: \.offset) { i, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(i == 0 ? Color.secondary : Color.secondary.opacity(0.6))
                        .lineLimit(entry.mode == .paragraph ? 1 : 2)
                }
                progress
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            if let image = SharedArtwork.image(named: entry.artworkFile) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: entry.isPlaying ? "music.note" : "pause.fill")
                    .foregroundStyle(.green)
            }
            Text(entry.title)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
    }

    /// 由系統自己推進的進度條：就算 App 的更新被節流，也看得出還在播放
    @ViewBuilder
    private var progress: some View {
        if let interval = entry.playbackInterval {
            ProgressView(timerInterval: interval, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(.green)
        }
    }
}

struct LyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LyricsTimelineStore.widgetKind, provider: LyricsProvider()) { entry in
            LyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("歌詞")
        .description("逐句顯示 Spotify 正在播放的歌詞（CarPlay 小工具頁、主畫面、鎖定畫面）")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

/// 控制中心 / 鎖定畫面 / 動作按鈕：一鍵開啟 CarLyrics
struct LyricsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.willsonhsu.CarLyrics.open") {
            ControlWidgetButton(action: OpenCarLyricsIntent(target: .lyrics)) {
                Label("CarLyrics", systemImage: "music.note.list")
            }
        }
        .displayName("開啟 CarLyrics")
        .description("打開 CarLyrics 開始同步歌詞")
    }
}
