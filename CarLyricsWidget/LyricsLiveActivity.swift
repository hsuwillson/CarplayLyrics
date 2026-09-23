import ActivityKit
import SwiftUI
import WidgetKit

/// 歌詞即時動態（只顯示歌詞：播放控制交給鎖定畫面上的 Spotify）
/// - 每次更新都帶接下來幾句的視窗（`upcoming`，各自有起訖時刻）：每句底下一條系統自己推進的細進度條，
///   App 的更新被擋時（鎖定後 iOS 擋掉背景更新）沒有任何更新也看得出唱到哪一句
/// - stale（超過 staleDate 沒更新）：依 `LiveActivityStalePolicy` 用視窗算出那一刻正在唱的句子並升成目前句
///   （只會重畫這一次），播完後改顯示「打開 CarLyrics」，不把舊歌詞當成正在唱的
/// - 鎖定畫面：一行小字歌名 + 目前句（大字、最多三行）+ 細的逐句進度條 + 接下來最多三句（各帶進度條）
/// - CarPlay / Apple Watch：`.small` activity family（iOS 26 CarPlay 使用這個尺寸），目前句 + 接下來最多兩句 + 細進度條
/// - 動態島：只放一個小圖示。即時動態進行中時系統一定會佔用動態島，無法關閉，
///   所以這裡刻意不放歌詞、不放按鈕，把佔用面積壓到最小；沒在播放時會自動收起（見 IdlePolicy）
struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsActivityView(state: context.state, isStale: context.isStale)
                .widgetURL(URL(string: "carlyrics://focus"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityArtwork(file: context.state.artworkFile, isPlaying: context.state.isPlaying, size: 36)
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
                // 刻意留白：動態島不顯示歌詞，佔用面積最小
                EmptyView()
            } minimal: {
                PlayingIcon(isPlaying: context.state.isPlaying)
            }
            .widgetURL(URL(string: "carlyrics://focus"))
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
            .foregroundStyle(isPlaying ? WidgetTheme.Color.playing : WidgetTheme.Color.paused)
            .accessibilityLabel(isPlaying ? "播放中" : "已暫停")
    }
}

/// 小張封面（App Group）；沒有時顯示播放圖示
private struct ActivityArtwork: View {
    let file: String?
    let isPlaying: Bool
    var size: CGFloat = 40

    var body: some View {
        if let image = SharedArtwork.image(named: file) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
                .accessibilityHidden(true)
        } else {
            PlayingIcon(isPlaying: isPlaying)
                .frame(width: size, height: size)
        }
    }
}

/// 系統自己推進的進度條（不需要 App 更新）
private struct ActivityProgress: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        if let interval = state.playbackInterval {
            TimerBar(interval: interval, tint: WidgetTheme.Color.playing)
        }
    }
}

/// 目前句的進度（鎖定畫面用）：從這句開始到下一句開始，系統自己推進。
/// 一眼就能分辨「還在動」與「停在滿格＝沒跟上」；沒有下一句（最後一句、間奏）時不顯示
private struct LineProgress: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        if let interval = state.lineProgressInterval {
            TimerBar(interval: interval, tint: .secondary)
        }
    }
}

private struct TimerBar: View {
    let interval: ClosedRange<Date>
    let tint: Color

    var body: some View {
        ProgressView(timerInterval: interval, countsDown: false) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .progressViewStyle(.linear)
        .tint(tint)
    }
}

/// 背景更新被系統暫停時的說明
private let staleMessage = "歌詞未更新 · 打開 CarLyrics"

/// 接下來的一句：文字 + 系統自己推進的進度條區間（沒有時刻的舊內容是 nil）
private struct ShownRow {
    let text: String
    let interval: ClosedRange<Date>?
}

/// 畫面實際要顯示的句子：正常時就是送出的內容；stale 時依 `LiveActivityStalePolicy` 決定
/// （用視窗算出 `now` 正在唱的句子並升成目前句；播完 → 「打開 CarLyrics」）。`now` 是這次重畫的時刻。
private struct ShownLyrics {
    let current: String
    let next: String
    /// 目前句之後的句子（視窗有的話帶進度條區間）
    let rows: [ShownRow]
    let isStale: Bool
    let staleKind: LiveActivityStalePolicy.Display.Kind?

    init(state: LyricsActivityAttributes.ContentState, isStale: Bool, now: Date = Date()) {
        self.isStale = isStale
        if isStale {
            let d = LiveActivityStalePolicy().display(for: state.model, now: now)
            current = d.current
            next = d.next
            staleKind = d.kind
            switch d.kind {
            case .songOver, .expired:
                rows = []
            case .advanced, .unchanged:
                rows = d.upcoming.isEmpty ? Self.textRows(next: d.next, next2: nil) : d.upcoming.map(Self.row)
            }
        } else {
            current = state.currentLine
            next = state.nextLine
            staleKind = nil
            let window = state.upcoming ?? []
            rows = window.isEmpty ? Self.textRows(next: state.nextLine, next2: state.nextLine2) : window.map(Self.row)
        }
    }

    private static func row(_ line: ActivityUpcomingLine) -> ShownRow {
        ShownRow(text: line.text, interval: line.progressInterval)
    }

    /// 沒有視窗（舊內容、沒有同步歌詞）：只有文字
    private static func textRows(next: String, next2: String?) -> [ShownRow] {
        var rows: [ShownRow] = []
        if !next.isEmpty { rows.append(ShownRow(text: next, interval: nil)) }
        if let next2, !next2.isEmpty { rows.append(ShownRow(text: next2, interval: nil)) }
        return rows
    }

    /// stale 提示：播完時已經把「打開 CarLyrics」放在目前句，就不重複
    var staleHint: String? {
        guard isStale else { return nil }
        switch staleKind {
        case .songOver?: return "歌曲已播完"
        case .expired?, .advanced?, .unchanged?, nil: return staleMessage
        }
    }
}

/// 目前句（間奏時改成系統自己推進的倒數；stale 時顯示推進後的句子，不倒數）
private struct CurrentLineView: View {
    let state: LyricsActivityAttributes.ContentState
    let shown: ShownLyrics
    let font: Font
    var lineLimit: Int = 2

    var body: some View {
        Group {
            if !shown.isStale, let countdown = state.countdownInterval(from: Date()) {
                HStack(spacing: 4) {
                    Text("♪ 下一句")
                    Text(timerInterval: countdown, countsDown: true)
                        .monospacedDigit()
                }
                .lineLimit(1)
            } else {
                Text(shown.current)
                    .lineLimit(lineLimit)
                    .minimumScaleFactor(0.7)
                    .lineSpacing(WidgetTheme.lineSpacing)
            }
        }
        .font(font)
        .foregroundStyle(shown.isStale ? Color.secondary : Color.primary)
    }
}

/// 過時提示：橘色圖示 + 灰字，一行（清楚但不吵：駕駛只需要知道「這不是即時的」）
private struct StaleHintRow: View {
    let hint: String
    var font: Font = .caption.weight(.medium)

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(WidgetTheme.Color.stale)
                .accessibilityHidden(true)
            Text(hint)
                .foregroundStyle(.secondary)
        }
        .font(font)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// 動態島展開區：目前句 + 下一句
private struct ExpandedLyrics: View {
    let state: LyricsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let shown = ShownLyrics(state: state, isStale: isStale)
        VStack(spacing: 4) {
            CurrentLineView(state: state, shown: shown, font: WidgetTheme.Font.islandCurrent)
                .multilineTextAlignment(.center)
            if let hint = shown.staleHint {
                StaleHintRow(hint: hint, font: .caption)
            } else if !shown.next.isEmpty {
                Text(shown.next)
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

/// 接下來的一句 + 底下一條系統自己推進的細進度條（區間過了就是滿格、還沒到就是空的：
/// 沒有任何更新也看得出唱到哪一句）
private struct UpcomingRow: View {
    let row: ShownRow
    let font: Font
    var color: Color = WidgetTheme.Color.upcoming
    var barHeight: CGFloat = WidgetTheme.Bar.upcoming

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
            if let interval = row.interval {
                TimerBar(interval: interval, tint: .secondary)
                    .frame(height: barHeight)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("接下來：\(row.text)")
    }
}

/// CarPlay 儀表板 / Apple Watch：字要大，目前句 + 接下來最多兩句（放不下就少列，不要被截掉）
private struct SmallActivityView: View {
    let state: LyricsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let shown = ShownLyrics(state: state, isStale: isStale)
        ViewThatFits(in: .vertical) {
            layout(shown, rows: 2)
            layout(shown, rows: 1)
            layout(shown, rows: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(WidgetTheme.Spacing.carPadding)
    }

    private func layout(_ shown: ShownLyrics, rows: Int) -> some View {
        VStack(alignment: .leading, spacing: WidgetTheme.Spacing.tight) {
            ActivityProgress(state: state)
                .frame(height: WidgetTheme.Bar.song)
                .accessibilityHidden(true)
            CurrentLineView(state: state, shown: shown, font: WidgetTheme.Font.carCurrent)
            if let hint = shown.staleHint {
                // 一行提示，讓駕駛一眼看出這不是即時的
                StaleHintRow(hint: hint, font: WidgetTheme.Font.carHint)
            }
            ForEach(Array(shown.rows.prefix(rows).enumerated()), id: \.offset) { i, row in
                HStack(alignment: .top, spacing: 5) {
                    if i == 0, !state.isPlaying {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("已暫停")
                    }
                    UpcomingRow(row: row,
                                font: i == 0 ? WidgetTheme.Font.carUpcoming : WidgetTheme.Font.carUpcomingFaded,
                                color: i == 0 ? WidgetTheme.Color.upcoming : WidgetTheme.Color.upcomingFaded)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// 鎖定畫面：只放歌詞（封面、歌曲進度條、播放按鈕 Spotify 自己的卡片都有了）
private struct LockScreenActivityView: View {
    let state: LyricsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let shown = ShownLyrics(state: state, isStale: isStale)
        // 鎖定畫面的即時動態高度有限（目前句最多三行時放不下三句預告）：放不下就少列幾句，不要被截掉
        ViewThatFits(in: .vertical) {
            layout(shown, rows: 3)
            layout(shown, rows: 2)
            layout(shown, rows: 1)
            layout(shown, rows: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WidgetTheme.Spacing.lockPadding)
        // 卡片高度有限：字級跟隨系統到「特大」為止
        .dynamicTypeSize(...WidgetTheme.maxDynamicType)
    }

    private func layout(_ shown: ShownLyrics, rows: Int) -> some View {
        VStack(alignment: .leading, spacing: WidgetTheme.Spacing.row) {
            header
            CurrentLineView(state: state, shown: shown, font: WidgetTheme.Font.lockCurrent, lineLimit: 3)
            if !isStale {
                // 細的逐句進度條：更新沒跟上時它會停在滿格，比文字更容易一眼看出
                LineProgress(state: state)
                    .frame(height: WidgetTheme.Bar.line)
                    .accessibilityHidden(true)
            }
            // 接下來最多三句，各帶一條系統推進的細進度條：鎖定後更新被擋，也看得出唱到哪一句
            ForEach(Array(shown.rows.prefix(rows).enumerated()), id: \.offset) { i, row in
                UpcomingRow(row: row,
                            font: i == 0 ? WidgetTheme.Font.lockUpcoming : WidgetTheme.Font.lockUpcomingFaded,
                            color: i == 0 ? WidgetTheme.Color.upcoming : WidgetTheme.Color.upcomingFaded)
            }
            if let hint = shown.staleHint {
                StaleHintRow(hint: hint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一行小字：小張封面（有的話）+ 哪一首（暫停時顯示暫停符號）
    private var header: some View {
        HStack(spacing: 6) {
            if let image = SharedArtwork.image(named: state.artworkFile) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .accessibilityHidden(true)
            }
            PlayingIcon(isPlaying: state.isPlaying)
            Text(state.trackName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(WidgetTheme.Color.stale)
                    .accessibilityLabel("歌詞未更新")
            }
        }
    }
}
