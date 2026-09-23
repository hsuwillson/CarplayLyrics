import SwiftUI

/// 專注模式（車架模式）：全黑背景、超大目前句、大按鈕。
/// - 可橫向：左邊封面、右邊歌詞
/// - 手勢：左右滑 = 下一首 / 上一首；點一下 = 顯示 / 隱藏控制列；點兩下 = 播放 / 暫停
/// - 字級可調（右上角 Aa）
struct FocusLyricsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
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
                        HStack(spacing: 28) {
                            ArtworkView(url: model.nowPlaying?.artworkURL, size: min(geo.size.height * 0.5, 220), cornerRadius: 20)
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
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { togglePlay() }
            .onTapGesture { withAnimation(.snappy) { showControls.toggle() } }
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

private struct FocusHeader: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @Binding var showFontSlider: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.nowPlaying?.title ?? "沒有正在播放的歌曲")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(model.nowPlaying?.artist ?? model.session.label)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                model.focusLandscapeLock.toggle()
            } label: {
                Image(systemName: model.focusLandscapeLock ? "lock.rotation" : "rectangle.landscape.rotate")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(model.focusLandscapeLock ? Color.orange : Color.white.opacity(0.7))
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.focusLandscapeLock ? "取消鎖定橫向" : "鎖定橫向")
            Button {
                withAnimation(.snappy) { showFontSlider.toggle() }
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("調整字級")
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("關閉專注模式")
        }
    }
}

private struct FontScaleSlider: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            Image(systemName: "textformat.size.smaller")
            Slider(value: $model.focusFontScale, in: 0.8...1.4, step: 0.1)
                .tint(Color.white)
                .accessibilityLabel("字級")
            Image(systemName: "textformat.size.larger")
        }
        .foregroundStyle(Color.white.opacity(0.7))
        .padding(.vertical, 8)
        .transition(.opacity)
    }
}

private struct FocusLyrics: View {
    @Environment(AppModel.self) private var model
    let landscape: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var baseSize: CGFloat = 46

    private var currentSize: CGFloat {
        baseSize * model.focusFontScale * (landscape ? 0.85 : 1)
    }

    var body: some View {
        Group {
            if case .nonMusic(let kind) = model.session {
                // 廣告 / Podcast：不要把上一首最後一句用大字留在畫面上
                VStack(spacing: 10) {
                    Text(kind.label)
                        .font(.title.weight(.semibold))
                    Text("結束後會自動接上歌詞")
                        .font(.title3)
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .foregroundStyle(Color.white)
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
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 16)
                }
            default:
                Text(model.nowPlaying == nil ? model.session.label : model.lyrics.state.label)
                    .font(.title)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var previousLine: String {
        guard let i = model.lyricsDisplay.index, i > 0, model.syncedLines.indices.contains(i - 1) else { return " " }
        return model.syncedLines[i - 1].text
    }

    private var synced: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            if !landscape {
                Text(previousLine)
                    .font(.title2)
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            AnimatedCurrentLine(
                text: model.lyricsDisplay.current.isEmpty ? "♪" : model.lyricsDisplay.current,
                index: model.lyricsDisplay.index,
                font: .system(size: currentSize, weight: .heavy, design: .rounded),
                color: .white,
                lineLimit: landscape ? 3 : 5,
                minHeight: landscape ? 100 : 160,
                minimumScale: 0.4)
            Text(model.lyricsDisplay.next.isEmpty ? " " : model.lyricsDisplay.next)
                .font(.title.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

private struct FocusControls: View {
    @Environment(AppModel.self) private var model
    let compact: Bool

    var body: some View {
        VStack(spacing: 14) {
            if let np = model.nowPlaying {
                TimelineView(.periodic(from: .now, by: np.isPlaying ? 0.5 : 60)) { _ in
                    ProgressView(value: min(model.livePosition(), np.duration), total: max(np.duration, 1))
                        .tint(Color.white)
                }
                HStack(spacing: 36) {
                    TransportButton(symbol: "backward.fill", size: 34, tint: .white) {
                        model.previousOrRestart()
                    }
                    .accessibilityLabel("上一首")
                    PlayPauseButton(isPlaying: np.isPlaying, diameter: compact ? 68 : 88, fill: .white, symbolColor: .black) {
                        model.control(np.isPlaying ? .pause : .play)
                    }
                    TransportButton(symbol: "forward.fill", size: 34, tint: .white) {
                        model.control(.next)
                    }
                    .accessibilityLabel("下一首")
                }
                .sensoryFeedback(.impact(weight: .medium), trigger: model.controlSuccessCount)
                .sensoryFeedback(.error, trigger: model.controlFailureCount)
                if !model.canControlPlayback {
                    Button("重新登入以使用播放按鈕") { model.relogin() }
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
