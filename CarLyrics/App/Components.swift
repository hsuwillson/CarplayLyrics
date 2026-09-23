import SwiftUI
import UIKit

// 主畫面、完整歌詞、專注模式、設定共用的小元件（只有 SwiftUI，沒有邏輯）

/// 全畫面背景：系統底色 + 左上角一團品牌色光暈。播放中稍亮、靜止時收斂；
/// 淺色模式壓得很淡，文字對比不受影響。開啟「減少透明度」時直接用純色。
struct AppBackground: View {
    var isPlaying: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(isPlaying: Bool = false) {
        self.isPlaying = isPlaying
    }

    private var glow: Double {
        colorScheme == .dark ? (isPlaying ? 0.42 : 0.26) : (isPlaying ? 0.16 : 0.09)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if !reduceTransparency {
                RadialGradient(
                    colors: [Theme.brand.opacity(glow), Theme.brand.opacity(glow * 0.35), .clear],
                    center: UnitPoint(x: 0.15, y: 0.05),
                    startRadius: 0,
                    endRadius: 520)
                LinearGradient(
                    colors: [.clear, Color(uiColor: .systemBackground).opacity(colorScheme == .dark ? 0.6 : 0.3)],
                    startPoint: .center,
                    endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .animation(Theme.Motion.gentle, value: isPlaying)
        .accessibilityHidden(true)
    }
}

/// 顯示狀態的小圓點（裝飾）
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 一顆膠囊狀態籤：圓點 + 短文字（主畫面最上面的連線狀態）
struct StatusChip: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color, size: 7)
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.fill.tertiary, in: Capsule())
    }
}

/// 一列提示：圖示 + 文字 + 可選的按鈕，淡淡的底色（不是玻璃：玻璃留給按鈕）
struct InlineHint<Action: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    var lineLimit: Int = 3
    @ViewBuilder let action: () -> Action

    init(symbol: String, tint: Color = .secondary, text: String, lineLimit: Int = 3,
         @ViewBuilder action: @escaping () -> Action) {
        self.symbol = symbol
        self.tint = tint
        self.text = text
        self.lineLimit = lineLimit
        self.action = action
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            action()
                .buttonStyle(.glass)
                .controlSize(.small)
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(.fill.quaternary, in: Theme.cardShape(Theme.Radius.row))
        .accessibilityElement(children: .contain)
    }
}

extension InlineHint where Action == EmptyView {
    init(symbol: String, tint: Color = .secondary, text: String, lineLimit: Int = 3) {
        self.init(symbol: symbol, tint: tint, text: text, lineLimit: lineLimit) { EmptyView() }
    }
}

/// 空狀態：淡淡的大圖示 + 一句標題 + 一句說明（+ 可選按鈕）
struct EmptyStateView<Action: View>: View {
    let symbol: String
    let title: String
    var message: String?
    @ViewBuilder let action: () -> Action

    init(symbol: String, title: String, message: String? = nil, @ViewBuilder action: @escaping () -> Action) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Font.emptyTitle)
                    .foregroundStyle(.primary)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            action()
                .padding(.top, Theme.Spacing.xs)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(symbol: String, title: String, message: String? = nil) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// ⏮ / ⏭ 這類大按鈕：至少 56 pt 的點擊範圍（開車時也按得到）
struct TransportButton: View {
    let symbol: String
    var size: CGFloat = 28
    var tint: Color = .primary
    var hitSize: CGFloat = 64
    let action: () -> Void

    init(symbol: String, size: CGFloat = 28, tint: Color = .primary, hitSize: CGFloat = 64,
         action: @escaping () -> Void) {
        self.symbol = symbol
        self.size = size
        self.tint = tint
        self.hitSize = hitSize
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: hitSize, height: hitSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// ⏯：實心圓形，高對比；圖示切換有動畫
struct PlayPauseButton: View {
    let isPlaying: Bool
    var diameter: CGFloat = Theme.Size.playButton
    var fill: Color = .primary
    var symbolColor: Color = Color(uiColor: .systemBackground)
    let action: () -> Void

    init(isPlaying: Bool, diameter: CGFloat = Theme.Size.playButton, fill: Color = .primary,
         symbolColor: Color = Color(uiColor: .systemBackground), action: @escaping () -> Void) {
        self.isPlaying = isPlaying
        self.diameter = diameter
        self.fill = fill
        self.symbolColor = symbolColor
        self.action = action
    }

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
    var lineSpacing: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(text: String, index: Int?, font: Font, color: Color = .primary, lineLimit: Int = 4,
         minHeight: CGFloat = 120, minimumScale: CGFloat = 0.5, lineSpacing: CGFloat = 6) {
        self.text = text
        self.index = index
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
        self.minHeight = minHeight
        self.minimumScale = minimumScale
        self.lineSpacing = lineSpacing
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
                .lineSpacing(lineSpacing)
                .lineLimit(lineLimit)
                .minimumScaleFactor(minimumScale)
                .id(index)
                .transition(transition)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .clipped()
        .animation(Theme.Motion.lineChange(reduceMotion: reduceMotion), value: index)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(text)
    }
}

/// 主畫面底部的動作按鈕外觀（完整歌詞 / 專注模式 / 選擇歌詞）
struct ActionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(Color.primary)
        .frame(maxWidth: .infinity, minHeight: 58)
        .glassEffect(.regular.interactive(), in: Theme.cardShape(Theme.Radius.control))
        .contentShape(Theme.cardShape(Theme.Radius.control))
    }
}

/// 專輯封面（網路圖；載入中 / 失敗時顯示音符）
struct ArtworkView: View {
    let url: URL?
    var size: CGFloat = 96
    var cornerRadius: CGFloat = Theme.Radius.artwork

    init(url: URL?, size: CGFloat = 96, cornerRadius: CGFloat = Theme.Radius.artwork) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: Theme.Motion.standard)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Rectangle().fill(.fill.tertiary)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.35, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Theme.cardShape(cornerRadius))
        .overlay {
            // 一條極細的內框：淺色專輯封面在淺色背景上才有邊
            Theme.cardShape(cornerRadius)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
        .accessibilityHidden(true)
    }
}

/// 設定列左邊的彩色小方塊圖示（iOS 設定 App 的樣式）
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Theme.Size.settingsIcon, height: Theme.Size.settingsIcon)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 設定列：彩色方塊圖示 + 文字（+ 可選的副標）
struct SettingsLabel: View {
    let title: String
    var subtitle: String?
    let symbol: String
    let color: Color

    init(_ title: String, subtitle: String? = nil, symbol: String, color: Color) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            SettingsIcon(symbol: symbol, color: color)
        }
    }
}

/// 數字步驟列（1. 2. 3.）：圓圈數字 + 說明
struct NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.brand)
                .frame(width: 22, height: 22)
                .background(Theme.brand.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("步驟 \(number)：\(text)")
    }
}
