import SwiftUI

/// 完整歌詞（卡拉 OK 式）：目前句放大、唱過的變淡；自動捲動到目前句，點某一句 → Spotify 跳到那個時間點。
/// 上下各有一段漸層遮罩，讓歌詞像從畫面外流進來，目前句永遠停在中間。
struct FullLyricsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 使用者最近一次手動捲動的時間；5 秒內不自動捲回目前句
    @State private var lastUserScroll = Date.distantPast
    @State private var tapCount = 0

    var body: some View {
        ZStack {
            AppBackground(isPlaying: model.isPlaying)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(model.syncedLines.indices, id: \.self) { i in
                            LyricRow(text: model.syncedLines[i].text, phase: rowPhase(i)) {
                                tapCount += 1
                                model.seek(toLine: i)
                            }
                            .id(i)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, 200)
                    .animation(Theme.Motion.lineChange(reduceMotion: reduceMotion), value: model.lyricsDisplay.index)
                }
                .scrollIndicators(.hidden)
                .mask {
                    // 上下淡出：目前句在中間最清楚
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .onScrollPhaseChange { _, newPhase in
                    if newPhase == .interacting || newPhase == .decelerating {
                        lastUserScroll = Date()
                    }
                }
                .onChange(of: model.lyricsDisplay.index) { _, newIndex in
                    guard let newIndex, Date().timeIntervalSince(lastUserScroll) > 5 else { return }
                    withAnimation(Theme.Motion.lineChange(reduceMotion: reduceMotion)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onAppear {
                    if let i = model.lyricsDisplay.index { proxy.scrollTo(i, anchor: .center) }
                }
                .safeAreaInset(edge: .bottom) {
                    FullLyricsBar {
                        guard let i = model.lyricsDisplay.index else { return }
                        lastUserScroll = .distantPast
                        withAnimation(Theme.Motion.standard) {
                            proxy.scrollTo(i, anchor: .center)
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: tapCount)
        .navigationTitle(model.nowPlaying?.title ?? "歌詞")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .overlay {
            if model.syncedLines.isEmpty {
                ContentUnavailableView(model.lyrics.state.label, systemImage: "text.quote")
            }
        }
    }

    private func rowPhase(_ i: Int) -> LyricRow.Phase {
        guard let current = model.lyricsDisplay.index else { return .future }
        if i == current { return .current }
        return i < current ? .past : .future
    }
}

private struct LyricRow: View {
    enum Phase { case past, current, future }

    let text: String
    let phase: Phase
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCurrent: Bool { phase == .current }

    private var opacity: Double {
        switch phase {
        case .past: return 0.38
        case .current: return 1
        case .future: return 0.62
        }
    }

    var body: some View {
        Button(action: action) {
            Text(text.isEmpty ? "♪" : text)
                .font(isCurrent ? Theme.Font.lyricRowCurrent : Theme.Font.lyricRow)
                .lineSpacing(4)
                .foregroundStyle(Color.primary)
                .opacity(opacity)
                .scaleEffect(isCurrent || reduceMotion ? 1 : 0.96, anchor: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Spacing.m)
                .padding(.horizontal, Theme.Spacing.m)
                .background {
                    if isCurrent {
                        Theme.cardShape(Theme.Radius.row)
                            .fill(Theme.brand.opacity(0.14))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.lineChange(reduceMotion: reduceMotion), value: phase)
        .accessibilityHint("跳到這一句")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// 完整歌詞底部：回到目前句 + 播放/暫停 + 提示
private struct FullLyricsBar: View {
    @Environment(AppModel.self) private var model
    let scrollToCurrent: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button(action: scrollToCurrent) {
                Label("回到目前句", systemImage: "arrow.down.to.line")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(minHeight: Theme.Size.tapTarget)
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.lyricsDisplay.index == nil)
            Text("點一句可跳到那段")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let np = model.nowPlaying {
                PlayPauseButton(isPlaying: np.isPlaying, diameter: 48) {
                    model.control(np.isPlaying ? .pause : .play)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
