import SwiftUI
import ActivityKit

struct ContentView: View {
    @State private var appGroupOK = false
    @State private var liveActivitiesEnabled = false

    var body: some View {
        NavigationStack {
            List {
                Section("階段 1：骨架檢查") {
                    LabeledContent("App Group", value: appGroupOK ? "OK" : "失敗")
                    LabeledContent("Live Activities", value: liveActivitiesEnabled ? "已啟用" : "未啟用")
                    LabeledContent("Client ID", value: AppConfig.spotifyClientID == "YOUR_SPOTIFY_CLIENT_ID" ? "尚未設定" : "已設定")
                }
            }
            .navigationTitle("CarLyrics")
        }
        .onAppear(perform: check)
    }

    private func check() {
        if let d = AppGroup.defaults {
            d.set(Date().timeIntervalSince1970, forKey: "skeletonCheck")
            appGroupOK = d.double(forKey: "skeletonCheck") > 0 && AppGroup.containerURL != nil
        }
        liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    }
}

#Preview { ContentView() }
