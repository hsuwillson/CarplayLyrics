import SwiftUI

/// 設計 token（元件在 Components.swift）。
///
/// 方向：「夜間行車」——歌詞是主角，其餘都是配角。
/// - 字體：歌詞用 rounded 系統字（中文自動落回蘋方，圓體只影響英數），字距靠 `lineSpacing` 撐開，
///   中文行高 ≈ 字級 × 1.25 才不會擠在一起。
/// - 顏色：品牌靛藍只用在背景光暈與主要動作；語意色（播放 / 暫停 / 注意 / 離線）一律用系統色，
///   會跟著「增強對比」自動調整。專注模式用純黑 + 白色的三段透明度。
/// - 材質：Liquid Glass 只給「控制層」（按鈕、動作列、橫幅）；內容本身不用玻璃，同一畫面
///   玻璃面數量壓到最少（Apple 文件：太多 glassEffect 會拖慢繪製）。
/// - 動態：只在換句 / 狀態改變時動；開啟「減少動態效果」時只淡入淡出。
enum Theme {
    /// 品牌靛藍（Assets：淺色 (88,70,210)、深色 (140,125,255)；對白 / 黑底對比皆 ≥ 4.5:1）
    static let brand = Color("AccentColor")

    // MARK: 語意色（系統色：跟隨深淺色與「增強對比」）

    enum Semantic {
        static let playing = Color.green
        static let paused = Color.yellow
        static let attention = Color.orange
        static let offline = Color.red
        static let idle = Color.gray
        static let ok = Color.green
        static let destructive = Color.red
    }

    // MARK: 專注模式（純黑背景）的白色三階

    enum Ink {
        static let primary = Color.white
        static let secondary = Color.white.opacity(0.62)
        static let tertiary = Color.white.opacity(0.38)
        static let hairline = Color.white.opacity(0.16)

        /// 「增強對比」開啟時把次要文字提亮
        static func adjustedSecondary(highContrast: Bool) -> Color {
            highContrast ? Color.white.opacity(0.82) : secondary
        }

        static func adjustedTertiary(highContrast: Bool) -> Color {
            highContrast ? Color.white.opacity(0.62) : tertiary
        }
    }

    // MARK: 間距（4 pt 網格）

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
        /// 畫面左右留白
        static let gutter: CGFloat = 20
    }

    // MARK: 圓角（一律 continuous）

    enum Radius {
        static let card: CGFloat = 24
        static let control: CGFloat = 18
        static let row: CGFloat = 14
        static let chip: CGFloat = 10
        static let artwork: CGFloat = 14
    }

    // MARK: 字體

    enum Font {
        /// 主畫面目前句
        static let lyricHero = SwiftUI.Font.system(.largeTitle, design: .rounded, weight: .bold)
        /// 主畫面前 / 後一句
        static let lyricContext = SwiftUI.Font.system(.title3, design: .rounded, weight: .medium)
        /// 完整歌詞：目前句 / 其他句
        static let lyricRowCurrent = SwiftUI.Font.system(.title, design: .rounded, weight: .bold)
        static let lyricRow = SwiftUI.Font.system(.title2, design: .rounded, weight: .semibold)
        /// 空狀態 / 提示標題
        static let emptyTitle = SwiftUI.Font.title3.weight(.semibold)
        /// 中文行距：字級的 18 %（系統預設行高對 CJK 偏緊）
        static func lineSpacing(for pointSize: CGFloat) -> CGFloat { pointSize * 0.18 }
        /// 專注模式目前句的基準字級（再乘以使用者的字級倍率）
        static let focusBase: CGFloat = 46
        static let focusLineSpacing: CGFloat = 8
    }

    // MARK: 尺寸

    enum Size {
        /// 最小點擊範圍
        static let tapTarget: CGFloat = 44
        /// 開車時的按鈕
        static let carTapTarget: CGFloat = 56
        static let artworkHero: CGFloat = 84
        static let playButton: CGFloat = 72
        static let focusPlayButton: CGFloat = 88
        /// 設定列左邊的小圖示方塊
        static let settingsIcon: CGFloat = 29
    }

    // MARK: 透明度

    enum Opacity {
        static let disabled: Double = 0.4
        static let dimmed: Double = 0.55
    }

    // MARK: 動態（都很短；「減少動態效果」時退回淡入淡出）

    enum Motion {
        static let quick = Animation.easeInOut(duration: 0.2)
        static let standard = Animation.easeInOut(duration: 0.3)
        static let gentle = Animation.easeInOut(duration: 0.6)
        static let snappy = Animation.snappy(duration: 0.3)

        static func lineChange(reduceMotion: Bool) -> Animation {
            reduceMotion ? quick : standard
        }
    }
}

// MARK: - 形狀

extension Theme {
    static func cardShape(_ radius: CGFloat = Radius.card) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
