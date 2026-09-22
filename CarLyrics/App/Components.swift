import SwiftUI
import UIKit

// 主畫面、完整歌詞、專注模式共用的小元件（只有 SwiftUI，沒有邏輯）

/// 全畫面漸層背景：品牌色，深淺色模式各自調整透明度（淺色模式保持文字對比）
struct AppBackground: View {
    var isPlaying: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    init(isPlaying: Bool = false) {
        self.isPlaying = isPlaying
    }

    private var strength: (Double, Double) {
        colorScheme == .dark ? (isPlaying ? 0.45 : 0.28, 0.12) : (isPlaying ? 0.18 : 0.10, 0.06)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            LinearGradient(
                colors: [
                    Theme.brand.opacity(strength.0),
                    Color.purple.opacity(strength.1),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: isPlaying)
    }
}

/// 顯示狀態的小圓點（裝飾）
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

/// ⏮ / ⏭ 這類大按鈕：至少 64pt 的點擊範圍
struct TransportButton: View {
    let symbol: String
    var size: CGFloat = 28
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// ⏯：實心圓形，高對比；圖示切換有動畫
struct PlayPauseButton: View {
    let isPlaying: Bool
    var diameter: CGFloat = 72
    var fill: Color = .primary
    var symbolColor: Color = Color(uiColor: .systemBackground)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: diameter * 0.42, weight: .bold))
                    .foregroundStyle(symbolColor)
                    .contentTransition(.symbolEffect(.replace))
                    // play 圖示視覺上偏左，往右推一點
                    .offset(x: isPlaying ? 0 : diameter * 0.04)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "暫停" : "播放")
    }
}

/// 目前句：index 改變時由下往上滑入、淡出舊句（開啟「減少動態效果」時只淡入淡出）
struct AnimatedCurrentLine: View {
    let text: String
    let index: Int?
    let font: Font
    var color: Color = .primary
    var lineLimit: Int = 4
    var minHeight: CGFloat = 120
    var minimumScale: CGFloat = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(text: String, index: Int?, font: Font, color: Color = .primary, lineLimit: Int = 4,
         minHeight: CGFloat = 120, minimumScale: CGFloat = 0.5) {
        self.text = text
        self.index = index
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
        self.minHeight = minHeight
        self.minimumScale = minimumScale
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity))
    }

    var body: some View {
        ZStack {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .lineLimit(lineLimit)
                .minimumScaleFactor(minimumScale)
                .id(index)
                .transition(transition)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .clipped()
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.3), value: index)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(text)
    }
}

/// 主畫面底部的動作按鈕外觀（完整歌詞 / 專注模式 / 換歌詞）
struct ActionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(Color.primary)
        .frame(maxWidth: .infinity, minHeight: 56)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

/// 專輯封面（網路圖；載入中 / 失敗時顯示音符）
struct ArtworkView: View {
    let url: URL?
    var size: CGFloat = 96
    var cornerRadius: CGFloat = 14

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.3))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.35, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .accessibilityHidden(true)
    }
}
