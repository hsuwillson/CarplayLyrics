import Foundation
import UIKit

/// 開車模式的螢幕亮度：調暗時記住原本的亮度，結束時恢復。
/// - 用 `UIWindowScene.screen`（`UIScreen.main` 已不建議使用）
/// - iOS 本身在鎖定 / 解鎖後也會把亮度恢復成使用者的設定，這裡的恢復只是不等到那時候
/// - 決策在 `DrivingModePolicy`；這裡只做 UIKit 的呼叫
@MainActor
final class ScreenDimmer {
    /// 調暗前的亮度；nil = 目前沒有調暗
    private var savedBrightness: CGFloat?

    var isDimmed: Bool { savedBrightness != nil }

    /// - Parameter target: 要調到多亮（0–1）；nil = 恢復原本亮度（沒調過就什麼都不做）
    func apply(brightness target: Double?) {
        // 最常見的情況（沒要調暗、也沒調暗過）不用去找 scene
        guard target != nil || savedBrightness != nil, let screen = Self.screen() else { return }
        if let target {
            // 只在進入時調一次：之後使用者自己把亮度調高，不要每次輪詢又把它壓回去
            guard savedBrightness == nil else { return }
            let value = CGFloat(min(1, max(0, target)))
            savedBrightness = screen.brightness
            debugLog(String(format: "開車模式：螢幕調暗 %.0f%% → %.0f%%", screen.brightness * 100, value * 100))
            if abs(screen.brightness - value) > 0.01 { screen.brightness = value }
        } else if let saved = savedBrightness {
            savedBrightness = nil
            screen.brightness = saved
            debugLog(String(format: "開車模式：螢幕亮度恢復 %.0f%%", saved * 100))
        }
    }

    /// 目前顯示 App 的那個螢幕（前景的 window scene；沒有時退回任一個）
    private static func screen() -> UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }
}
