import SwiftUI

/// 專注模式（開車用）：全黑背景、超大目前句、大按鈕
struct FocusLyricsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                FocusHeader { dismiss() }
                FocusLyrics()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                FocusControls()
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }
}

private struct FocusHeader: View {
    @EnvironmentObject private var model: AppModel
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.nowPlaying?.title ?? "沒有正在播放的歌曲")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(model.nowPlaying?.artist ?? model.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer()
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

private struct FocusLyrics: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.hasSyncedLyrics {
                synced
            } else if let plain = model.plainLyrics {
                ScrollView {
                    Text(plain)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 16)
                }
            } else {
                Text(model.lyricsStatus)
                    .font(.title)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var synced: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Text(model.previousLineText.isEmpty ? " " : model.previousLineText)
                .font(.title2)
                .foregroundStyle(Color.white.opacity(0.35))
                .lineLimit(1)
            AnimatedCurrentLine(
                text: model.currentLineText,
                index: model.display.index,
                font: .system(size: 46, weight: .heavy, design: .rounded),
                color: .white,
                lineLimit: 5,
                minHeight: 160,
                minimumScale: 0.4)
            Text(model.nextLineText.isEmpty ? " " : model.nextLineText)
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
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            if let np = model.nowPlaying {
                ProgressView(value: min(model.position, np.duration), total: max(np.duration, 1))
                    .tint(Color.white)
                HStack(spacing: 36) {
                    TransportButton(symbol: "backward.fill", size: 34, tint: .white) {
                        model.previousOrRestart()
                    }
                    .accessibilityLabel("上一首")
                    PlayPauseButton(isPlaying: np.isPlaying, diameter: 88, fill: .white, symbolColor: .black) {
                        model.control(np.isPlaying ? .pause : .play)
                    }
                    TransportButton(symbol: "forward.fill", size: 34, tint: .white) {
                        model.control(.next)
                    }
                    .accessibilityLabel("下一首")
                }
                if !model.canControlPlayback {
                    Text("要使用播放按鈕，請先登出再重新登入 Spotify")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
