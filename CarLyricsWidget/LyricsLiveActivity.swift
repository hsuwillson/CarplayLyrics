import ActivityKit
import SwiftUI
import WidgetKit

/// 歌詞即時動態（只顯示歌詞：播放控制交給鎖定畫面上的 Spotify）
/// - stale（App 在背景時 iOS 擋掉更新、或 App 被終止）：依 `LiveActivityStalePolicy` 自己推進到下一句一次，
///   播完後改顯示「打開 CarLyrics」，不把舊歌詞當成正在唱的
/// - 鎖定畫面：一行小字歌名 + 目前句（大字、最多三行）+ 細的逐句進度條（系統自己推進，
///   在動就代表即時動態還活著）+ 下一句 + 再下一句
/// - CarPlay / Apple Watch：`.small` activity family（iOS 26 CarPlay 使用這個尺寸），目前句 + 下一句 + 細進度條
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
            .foregroundStyle(isPlaying ? Color.green : Color.secondary)
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
            TimerBar(interval: interval, tint: .green)
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

/// 畫面實際要顯示的句子：正常時就是送出的內容；stale 時依 `LiveActivityStalePolicy` 決定
/// （下一句已開始 → 升成目前句；播完 → 「打開 CarLyrics」）。`now` 是這次重畫的時刻。
private struct ShownLyrics {
    let current: String
    let next: String
    let next2: String?
    let isStale: Bool
    let staleKind: LiveActivityStalePolicy.Display.Kind?

    init(state: LyricsActivityAttributes.ContentState, isStale: Bool, now: Date = Date()) {
        self.isStale = isStale
        if isStale {
            let d = LiveActivityStalePolicy().display(for: state.model, now: now)
            current = d.current
            next = d.next
            next2 = nil
            staleKind = d.kind
        } else {
            current = state.currentLine
            next = state.nextLine
            next2 = state.nextLine2
            staleKind = nil
        }
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
            }
        }
        .font(font)
        .foregroundStyle(shown.isStale ? Color.secondary : Color.primary)
    }
}

/// 動態島展開區：目前句 + 下一句
private struct ExpandedLyrics: View {
    let state: LyricsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let shown = ShownLyrics(state: state, isStale: isStale)
        VStack(spacing: 4) {
            CurrentLineView(state: state, shown: shown, font: .system(.title3, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
            if let hint = shown.staleHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
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

/// CarPlay 儀表板 / Apple Watch：字要大，只放目前句 + 下一句
private struct SmallActivityView: View {
    let state: LyricsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let shown = ShownLyrics(state: state, isStale: isStale)
        VStack(alignment: .leading, spacing: 3) {
            ActivityProgress(state: state)
                .frame(height: 4)
            CurrentLineView(state: state, shown: shown, font: .system(size: 22, weight: .bold, design: .rounded))
            Spacer(minLength: 0)
            if let hint = shown.staleHint {
                // 只放一行橘色提示（高度和平常一樣），讓駕駛一眼看出這不是即時的
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if !shown.next.isEmpty {
                HStack(spacing: 5) {
                    if !state.isPlaying {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 11))
                    }
                    Text(shown.next)
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

/// 鎖定畫面：只放歌詞（封面、歌曲進度條、播放按鈕 Spotify 自己的卡片都有了）
private struct LockScreenActivityView: View {
    let state: LyricsActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let shown = ShownLyrics(state: state, isStale: isStale)
        VStack(alignment: .leading, spacing: 6) {
            header
            CurrentLineView(state: state, shown: shown, font: .system(.title, design: .rounded, weight: .heavy),
                            lineLimit: 3)
            if !isStale {
                // 細的逐句進度條：更新沒跟上時它會停在滿格，比文字更容易一眼看出
                LineProgress(state: state)
                    .frame(height: 3)
            }
            if !shown.next.isEmpty {
                Text(shown.next)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let next2 = shown.next2, !next2.isEmpty {
                    Text(next2)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if let hint = shown.staleHint {
                Text(hint)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    /// 一行小字：哪一首（暫停時顯示暫停符號）
    private var header: some View {
        HStack(spacing: 6) {
            PlayingIcon(isPlaying: state.isPlaying)
            Text(state.trackName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
