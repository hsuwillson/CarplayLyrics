import SwiftUI
import UIKit

@main
struct CarLyricsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.appBecameActive()
            case .background: model.appEnteredBackground()
            default: break
            }
        }
    }
}

/// 畫面方向：一般畫面只有直向；專注模式（車架模式）可以自由旋轉，或鎖定橫向。
/// 鎖定橫向時只回報橫向，所以即使使用者開著系統「方向鎖定」，畫面仍會轉過去。
enum OrientationMode {
    case portrait, any, landscapeOnly

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .portrait: return .portrait
        case .any: return .allButUpsideDown
        case .landscapeOnly: return .landscape
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var orientation: OrientationMode = .portrait {
        didSet {
            guard orientation != oldValue else { return }
            updateOrientation()
        }
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Self.orientation.mask }
    }

    @MainActor
    private static func updateOrientation() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        // 專注模式是 presented view controller，要對最上層的那一個呼叫
        for window in scene.windows {
            var vc = window.rootViewController
            while let presented = vc?.presentedViewController { vc = presented }
            vc?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        switch orientation {
        case .portrait:
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        case .landscapeOnly:
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        case .any:
            break
        }
    }
}
