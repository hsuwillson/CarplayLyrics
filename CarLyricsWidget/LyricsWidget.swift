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
                                               upcoming: ["示範歌詞第二句", "示範歌詞第三句", "示範歌詞第四句"]),
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
        let now = Date()
        let snapshot = LyricsTimelineStore.load()
        let list = entries(now: now, snapshot: snapshot)
        // 診斷：系統多晚才執行 App 的重新整理要求（now − App 寫入時刻）、這次交出幾格、從第幾句開始
        LyricsTimelineStore.recordRender(snapshotUpdatedAt: snapshot?.updatedAt, entryCount: list.count,
                                         firstIndex: list.first?.frame.index, now: now)
        // App 在狀態改變時會主動重新整理，所以時間軸播完就停
        completion(Timeline(entries: list.isEmpty ? [.sample()] : list, policy: .never))
    }

    private func entries(now: Date, snapshot: LyricsTimelineSnapshot? = nil) -> [LyricsEntry] {
        let snapshot = snapshot ?? LyricsTimelineStore.load() ?? .idle("打開 CarLyrics 開始同步歌詞", at: now)
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
            // 鎖定畫面：只有三行的高度，段落模式也只列下一句（目前句 2 行 + 下一句 1 行）
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
            // CarPlay 小工具頁 / 主畫面（systemSmall）
            Group {
                if entry.mode == .paragraph {
                    // 段落模式：一格涵蓋一個時間窗，接下來最多 4 句；放不下就少列幾句，不要截掉
                    ViewThatFits(in: .vertical) {
                        paragraphLayout(upcomingCap: LyricsTimelineSnapshot.paragraphMaxUpcoming)
                        paragraphLayout(upcomingCap: 3)
                        paragraphLayout(upcomingCap: LyricsTimelineSnapshot.paragraphMinUpcoming)
                        paragraphLayout(upcomingCap: 1)
                    }
                } else {
                    perLineLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// 逐句模式：大字、目前句最多三行、下一句一行
    private var perLineLayout: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            currentLine(lineLimit: 3, minimumScale: 0.6)
            Spacer(minLength: 0)
            ForEach(Array(entry.frame.upcoming.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(i == 0 ? Color.secondary : Color.secondary.opacity(0.6))
                    .lineLimit(2)
            }
            progress
        }
    }

    /// 段落模式：目前句最多兩行，接下來的句子各一行、越後面越淡
    private func paragraphLayout(upcomingCap: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            currentLine(lineLimit: 2, minimumScale: 0.7)
            ForEach(Array(entry.frame.upcoming.prefix(upcomingCap).enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(Color.secondary.opacity(i == 0 ? 1 : max(0.45, 0.85 - Double(i) * 0.15)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            progress
        }
    }

    /// 目前句；間奏時改成由系統自己倒數到下一句（不需要任何更新）
    @ViewBuilder
    private func currentLine(lineLimit: Int, minimumScale: CGFloat) -> some View {
        if let countdown = entry.frame.countdownInterval(from: entry.date) {
            HStack(spacing: 4) {
                Text("♪ 下一句")
                Text(timerInterval: countdown, countsDown: true)
                    .monospacedDigit()
            }
            .font(.system(.title3, design: .rounded, weight: .bold))
            .lineLimit(1)
        } else {
            Text(entry.frame.current)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .lineLimit(lineLimit)
                .minimumScaleFactor(minimumScale)
                .contentTransition(.opacity)
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
