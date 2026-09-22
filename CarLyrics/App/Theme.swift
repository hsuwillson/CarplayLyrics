import SwiftUI
import UIKit

// 主畫面、完整歌詞、專注模式共用的小元件（只有 SwiftUI，沒有邏輯）

/// 全畫面漸層背景：只用系統顏色，深淺色模式都可用
struct AppBackground: View {
    var isPlaying: Bool = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            LinearGradient(
                colors: [
                    Color.indigo.opacity(isPlaying ? 0.45 : 0.25),
                    Color.purple.opacity(0.12),
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

/// 顯示狀態的小圓點
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
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

/// ⏯：實心圓形，高對比
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

/// 目前句：index 改變時由下往上滑入、淡出舊句
struct AnimatedCurrentLine: View {
    let text: String
    let index: Int?
    let font: Font
    var color: Color = .primary
    var lineLimit: Int = 4
    var minHeight: CGFloat = 120
    var minimumScale: CGFloat = 0.5

    var body: some View {
        ZStack {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .lineLimit(lineLimit)
                .minimumScaleFactor(minimumScale)
                .id(index)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .clipped()
        .animation(.easeInOut(duration: 0.3), value: index)
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
