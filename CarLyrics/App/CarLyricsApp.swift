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

/// 只有專注模式（車架模式）允許橫向，其他畫面維持直向
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var allowsLandscape = false {
        didSet { updateOrientation() }
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Self.allowsLandscape ? .allButUpsideDown : .portrait }
    }

    @MainActor
    private static func updateOrientation() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        if !allowsLandscape {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
    }
}
