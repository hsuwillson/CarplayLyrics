import SwiftUI

/// 設定檢查 / 第一次使用引導：把「要同時成立的幾件事」變成看得見的清單
struct SetupChecklistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let isOnboarding: Bool

    init(isOnboarding: Bool = false) {
        self.isOnboarding = isOnboarding
    }

    var body: some View {
        @Bindable var model = model
        List {
            if isOnboarding {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(Theme.brand)
                            .accessibilityHidden(true)
                        Text("歡迎使用 CarLyrics")
                            .font(.title2.bold())
                        Text("開車時在鎖定畫面、動態島與 CarPlay 顯示 Spotify 的同步歌詞。完成下面幾項就可以上路。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }

            Section {
                CheckRow(title: "登入 Spotify", detail: model.auth.isLoggedIn ? "已登入" : "需要 Spotify Premium 帳號",
                         ok: model.auth.isLoggedIn) {
                    if !model.auth.isLoggedIn { Button("登入") { model.login() } }
                }
                CheckRow(title: "控制播放權限", detail: model.canControlPlayback ? "可以用上一首 / 暫停等按鈕" : "登入時沒有授權「控制播放」",
                         ok: model.auth.isLoggedIn && model.canControlPlayback) {
                    if model.auth.isLoggedIn && !model.canControlPlayback { Button("重新登入") { model.relogin() } }
                }
                CheckRow(title: "系統允許即時動態", detail: model.activitiesEnabled ? "鎖定畫面與 CarPlay 可以顯示歌詞" : "目前被系統設定關閉",
                         ok: model.activitiesEnabled) {
                    if !model.activitiesEnabled { Button("開啟設定") { model.perform(.openSettings) } }
                }
                Toggle(isOn: $model.backgroundEnabled) {
                    CheckLabel(title: "背景持續執行", detail: "鎖定手機後繼續同步", ok: model.backgroundEnabled)
                }
                if let days = model.signingDaysRemaining {
                    CheckRow(title: "App 簽名", detail: days < 0 ? "已過期，請用 AltStore 重新整理" : "還有 \(days) 天到期",
                             ok: days > 2) { EmptyView() }
                }
            } header: {
                Text("必要設定")
            }

            Section {
                GuideRow(symbol: "car.fill", title: "把小工具加到 CarPlay",
                         steps: ["iPhone「設定」→「一般」→「CarPlay」", "選你的車 →「小工具」", "打開「顯示小工具」，加入 CarLyrics"])
                GuideRow(symbol: "rectangle.stack", title: "在 CarPlay 打開即時動態",
                         steps: ["同一頁（CarPlay → 你的車）", "打開「即時動態」"])
                GuideRow(symbol: "wand.and.stars", title: "上車自動打開 CarLyrics（建議）",
                         steps: ["打開「捷徑」App →「自動化」→「+」", "選「CarPlay」→「連接時」→「立即執行」", "動作選「開啟 CarLyrics」"])
            } header: {
                Text("開車前")
            } footer: {
                Text("即時動態只能在 App 開著時啟動，所以上車時打開一次 CarLyrics 最可靠。")
            }
        }
        .navigationTitle(isOnboarding ? "開始使用" : "設定檢查")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isOnboarding {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        model.hasSeenSetup = true
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct CheckLabel: View {
    let title: String
    let detail: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(ok ? Color.green : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(ok ? "完成" : "需要處理")
    }
}

private struct CheckRow<Action: View>: View {
    let title: String
    let detail: String
    let ok: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack {
            CheckLabel(title: title, detail: detail, ok: ok)
            Spacer()
            action()
                .buttonStyle(.bordered)
                .font(.caption.weight(.semibold))
        }
    }
}

private struct GuideRow: View {
    let symbol: String
    let title: String
    let steps: [String]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    Text("\(i + 1). \(step)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}
