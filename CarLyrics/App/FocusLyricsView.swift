import SwiftUI

/// 專注模式（車架模式）：純黑背景（OLED 不發光）、超大目前句、下一句變淡、極少的介面。
/// - 可橫向：左邊封面、右邊歌詞
/// - 手勢：左右滑 = 下一首 / 上一首；點一下 = 顯示 / 隱藏控制列；點兩下 = 播放 / 暫停
/// - 字級可調（右上角 Aa）
/// - 所有按鈕點擊範圍 ≥ 56 pt（開車時的手指不準）
struct FocusLyricsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showControls = true
    @State private var showFontSlider = false
    @State private var gestureCount = 0

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    FocusHeader(close: { dismiss() }, showFontSlider: $showFontSlider)
                    if showFontSlider { FontScaleSlider() }
                    if landscape {
                        HStack(spacing: Theme.Spacing.xxl) {
                            ArtworkView(url: model.nowPlaying?.artworkURL,
                                        size: min(geo.size.height * 0.5, 220), cornerRadius: 20)
                            FocusLyrics(landscape: true)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        FocusLyrics(landscape: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if showControls {
                        FocusControls(compact: landscape)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let hint = model.drivingHint {
                        // 開車模式：讓使用者知道為什麼要把手機留在這個畫面
                        Label(hint, systemImage: model.isDrivingModeActive ? "car.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(model.isDrivingModeActive
                                             ? Theme.Ink.adjustedTertiary(highContrast: contrast == .increased)
                                             : Theme.Semantic.attention)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .padding(.top, Theme.Spacing.s)
                            .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl + Theme.Spacing.xs)
                .padding(.top, Theme.Spacing.m)
                .padding(.bottom, Theme.Spacing.l)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { togglePlay() }
            .onTapGesture { withAnimation(Theme.Motion.snappy) { showControls.toggle() } }
            .gesture(DragGesture(minimumDistance: 40).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                gestureCount += 1
                if value.translation.width < 0 {
                    model.control(.next)
                } else {
                    model.previousOrRestart()
                }
            })
        }
        // 只影響這個畫面，不會殘留到關閉後的主畫面
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sensoryFeedback(.impact(weight: .light), trigger: gestureCount)
        // 專注模式是放在車架上看的：螢幕不自動關閉、允許橫向
        .onAppear {
            model.focusModeActive = true
            AppDelegate.orientation = model.focusLandscapeLock ? .landscapeOnly : .any
        }
        .onDisappear {
            model.focusModeActive = false
            AppDelegate.orientation = .portrait
        }
        .onChange(of: model.focusLandscapeLock) { _, locked in
            AppDelegate.orientation = locked ? .landscapeOnly : .any
        }
    }

    private func togglePlay() {
        gestureCount += 1
        model.control(model.isPlaying ? .pause : .play)
    }
}

// MARK: - 標題列

private struct FocusHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    let close: () -> Void
    @Binding var showFontSlider: Bool

    private var secondary: Color { Theme.Ink.adjustedSecondary(highContrast: contrast == .increased) }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.nowPlaying?.title ?? "沒有正在播放的歌曲")
                    .font(.headline)
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if model.nowPlaying != nil, !model.isPlaying {
                        Image(systemName: "pause.fill")
                            .font(.caption2.weight(.bold))
                            .accessibilityHidden(true)
                    }
                    Text(model.nowPlaying?.artist ?? model.session.label)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                .foregroundStyle(secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Theme.Spacing.s)
            FocusIconButton(symbol: model.focusLandscapeLock ? "lock.rotation" : "rectangle.landscape.rotate",
                            tint: model.focusLandscapeLock ? Theme.Semantic.attention : secondary,
                            label: model.focusLandscapeLock ? "取消鎖定橫向" : "鎖定橫向") {
                model.focusLandscapeLock.toggle()
            }
            FocusIconButton(symbol: "textformat.size", tint: secondary, label: "調整字級") {
                withAnimation(Theme.Motion.snappy) { showFontSlider.toggle() }
            }
            FocusIconButton(symbol: "xmark", tint: secondary, label: "關閉專注模式", filled: true, action: close)
        }
    }
}

/// 標題列的圓形圖示按鈕（56 pt 點擊範圍；`filled` 給關閉鈕一個淡淡的底）
private struct FocusIconButton: View {
    let symbol: String
    let tint: Color
    let label: String
    var filled: Bool = false
    let action: () -> Void

    init(symbol: String, tint: Color, label: String, filled: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.tint = tint
        self.label = label
        self.filled = filled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(filled ? Theme.Ink.hairline : Color.clear, in: Circle())
                .frame(width: Theme.Size.carTapTarget, height: Theme.Size.carTapTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct FontScaleSlider: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "textformat.size.smaller")
            Slider(value: $model.focusFontScale, in: 0.8...1.4, step: 0.1)
                .tint(Theme.Ink.primary)
                .accessibilityLabel("字級")
            Image(systemName: "textformat.size.larger")
        }
        .foregroundStyle(Theme.Ink.secondary)
        .padding(.vertical, Theme.Spacing.s)
        .transition(.opacity)
    }
}

// MARK: - 歌詞

private struct FocusLyrics: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    let landscape: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var baseSize: CGFloat = Theme.Font.focusBase

    private var currentSize: CGFloat {
        baseSize * model.focusFontScale * (landscape ? 0.85 : 1)
    }

    private var secondary: Color { Theme.Ink.adjustedSecondary(highContrast: contrast == .increased) }
    private var tertiary: Color { Theme.Ink.adjustedTertiary(highContrast: contrast == .increased) }

    var body: some View {
        Group {
            if case .nonMusic(let kind) = model.session {
                // 廣告 / Podcast：不要把上一首最後一句用大字留在畫面上
                VStack(spacing: Theme.Spacing.m) {
                    Text(kind.label)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(Theme.Ink.primary)
                    Text("結束後會自動接上歌詞")
                        .font(.title3)
                        .foregroundStyle(secondary)
                }
                .multilineTextAlignment(.center)
            } else {
                lyricsBody
            }
        }
    }

    @ViewBuilder
    private var lyricsBody: some View {
        Group {
            switch model.lyrics.state {
            case .synced:
                synced
            case .plain(let text):
                ScrollView {
                    Text(text)
                        .font(.title2.weight(.semibold))
                        .lineSpacing(6)
                        .foregroundStyle(Theme.Ink.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Spacing.l)
                }
                .scrollIndicators(.hidden)
            default:
                Text(model.nowPlaying == nil ? model.session.label : model.lyrics.state.label)
                    .font(.title)
                    .foregroundStyle(secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var previousLine: String {
        guard let i = model.lyricsDisplay.index, i > 0, model.syncedLines.indices.contains(i - 1) else { return " " }
        return model.syncedLines[i - 1].text
    }

    private var synced: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer(minLength: 0)
            if !landscape {
                Text(previousLine)
                    .font(.title2)
                    .foregroundStyle(tertiary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            AnimatedCurrentLine(
                text: model.lyricsDisplay.current.isEmpty ? "♪" : model.lyricsDisplay.current,
                index: model.lyricsDisplay.index,
                font: .system(size: currentSize, weight: .heavy, design: .rounded),
                color: Theme.Ink.primary,
                lineLimit: landscape ? 3 : 5,
                minHeight: landscape ? 100 : 160,
                minimumScale: 0.4,
                lineSpacing: Theme.Font.focusLineSpacing)
            Text(model.lyricsDisplay.next.isEmpty ? " " : model.lyricsDisplay.next)
                .font(.title.weight(.medium))
                .foregroundStyle(secondary)
                .lineLimit(2)
                .accessibilityLabel("下一句：\(model.lyricsDisplay.next)")
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 控制列

private struct FocusControls: View {
    @Environment(AppModel.self) private var model
    let compact: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            if let np = model.nowPlaying {
                TimelineView(.periodic(from: .now, by: np.isPlaying ? 0.5 : 60)) { _ in
                    ProgressView(value: min(model.livePosition(), np.duration), total: max(np.duration, 1))
                        .tint(Theme.Ink.secondary)
                }
                .accessibilityHidden(true)
                HStack(spacing: 36) {
                    TransportButton(symbol: "backward.fill", size: 34, tint: Theme.Ink.primary,
                                    hitSize: Theme.Size.carTapTarget + 8) {
                        model.previousOrRestart()
                    }
                    .accessibilityLabel("上一首")
                    PlayPauseButton(isPlaying: np.isPlaying,
                                    diameter: compact ? 68 : Theme.Size.focusPlayButton,
                                    fill: Theme.Ink.primary, symbolColor: .black) {
                        model.control(np.isPlaying ? .pause : .play)
                    }
                    TransportButton(symbol: "forward.fill", size: 34, tint: Theme.Ink.primary,
                                    hitSize: Theme.Size.carTapTarget + 8) {
                        model.control(.next)
                    }
                    .accessibilityLabel("下一首")
                }
                .sensoryFeedback(.impact(weight: .medium), trigger: model.controlSuccessCount)
                .sensoryFeedback(.error, trigger: model.controlFailureCount)
                if !model.canControlPlayback {
                    Button("重新登入以使用播放按鈕") { model.relogin() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Semantic.attention)
                        .frame(minHeight: Theme.Size.tapTarget)
                }
            }
        }
    }
}
