import SwiftUI

@main
struct CarLyricsApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { _, phase in
            // 階段 4 會改成背景也持續執行
            switch phase {
            case .active: model.start()
            case .background: model.stop()
            default: break
            }
        }
    }
}
