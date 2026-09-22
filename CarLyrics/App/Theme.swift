import SwiftUI

/// 設計 token：間距、圓角、品牌色（元件在 Components.swift）
enum Theme {
    static let brand = Color("AccentColor")
    static let spotifyGreen = Color(red: 0.12, green: 0.84, blue: 0.38)

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
    }

    enum Radius {
        static let card: CGFloat = 20
        static let control: CGFloat = 16
        static let row: CGFloat = 14
    }
}
