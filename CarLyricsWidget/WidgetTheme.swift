import SwiftUI

/// 小工具 / 即時動態的設計 token（Extension 看不到 App 的 Theme.swift，這裡是同一套規則的縮小版）。
/// 原則：目前句永遠最大最亮；接下來的句子一階一階變淡；播放中＝綠、暫停＝灰、過時＝橘色圖示 + 灰字（清楚但不吵）。
enum WidgetTheme {
    enum Color {
        static let playing = SwiftUI.Color.green
        static let paused = SwiftUI.Color.secondary
        static let stale = SwiftUI.Color.orange
        /// 接下來的句子：第一句 / 之後
        static let upcoming = SwiftUI.Color.secondary
        static let upcomingFaded = SwiftUI.Color.secondary.opacity(0.6)
        /// 每句底下系統自己推進的細進度條：在走的那一條＝正在唱＝播放中的綠
        static let lineBar = playing
    }

    enum Font {
        /// 鎖定畫面即時動態的目前句（最多三行）
        static let lockCurrent = SwiftUI.Font.system(.title, design: .rounded, weight: .heavy)
        static let lockUpcoming = SwiftUI.Font.headline
        static let lockUpcomingFaded = SwiftUI.Font.subheadline
        /// CarPlay 儀表板（activityFamily .small）：固定字級，車機不吃 Dynamic Type。
        /// 目前句 20 pt、接下來每句 15 pt 同樣大小（CarPlay 約一分鐘才重畫，列與列之間靠進度條分辨）
        static let carCurrent = SwiftUI.Font.system(size: 20, weight: .bold, design: .rounded)
        static let carRow = SwiftUI.Font.system(size: 15, weight: .medium)
        static let carHint = SwiftUI.Font.system(size: 12, weight: .medium)
        /// 動態島展開區 / 小工具
        static let islandCurrent = SwiftUI.Font.system(.title3, design: .rounded, weight: .bold)
        static let widgetCurrent = SwiftUI.Font.system(.title3, design: .rounded, weight: .bold)
    }

    enum Spacing {
        static let tight: CGFloat = 3
        static let row: CGFloat = 6
        static let lockPadding: CGFloat = 16
        static let carPadding: CGFloat = 10
        /// CarPlay 卡拉 OK 視窗的列距（列數優先於留白）
        static let carRow: CGFloat = 4
    }

    /// 進度條高度：歌曲 / 逐句（鎖定畫面）/ CarPlay 目前句 / 接下來的句子
    enum Bar {
        static let song: CGFloat = 4
        static let line: CGFloat = 3
        static let carCurrent: CGFloat = 3
        static let upcoming: CGFloat = 2
    }

    /// 中文行距：目前句多行時撐開一點
    static let lineSpacing: CGFloat = 2

    /// 玻璃 / 鎖定畫面：字級跟隨系統，但超過特大就不再放大（卡片高度有限）
    static let maxDynamicType: DynamicTypeSize = .xxLarge
}
