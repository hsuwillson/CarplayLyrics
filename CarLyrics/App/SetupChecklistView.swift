import SwiftUI

/// 設定檢查 / 第一次使用引導：把「要同時成立的幾件事」變成看得見的清單
struct SetupChecklistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
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
                        Text("開車時在 CarPlay 與鎖定畫面顯示 Spotify 的同步歌詞。完成下面幾項就可以上路。")
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
                if model.auth.isLoggedIn {
                    CheckRow(title: "控制播放權限",
                             detail: model.canControlPlayback ? "App 內的播放按鈕可以用" : "登入時沒有授權「控制播放」",
                             ok: model.canControlPlayback) {
                        if !model.canControlPlayback { Button("重新登入") { model.relogin() } }
                    }
                }
                CheckRow(title: "系統允許即時動態", detail: model.activitiesEnabled ? "鎖定畫面與 CarPlay 可以顯示歌詞" : "目前被系統設定關閉",
                         ok: model.activitiesEnabled) {
                    if !model.activitiesEnabled { Button("開啟設定") { model.perform(.openSettings) } }
                }
                Toggle(isOn: $model.backgroundEnabled) {
                    CheckLabel(title: "鎖定手機後繼續同步", detail: "關掉的話鎖定後歌詞會停住", ok: model.backgroundEnabled)
                }
                Toggle(isOn: $model.keepAwakeWhileDriving) {
                    CheckLabel(title: "開車時保持螢幕開著",
                               detail: "手機鎖定後 iOS 會擋掉更新，CarPlay 歌詞會停住",
                               ok: model.keepAwakeWhileDriving)
                }
                if let days = model.signingDaysRemaining {
                    CheckRow(title: "App 簽名", detail: days < 0 ? "已過期，請用 AltStore 重新整理" : "還有 \(days) 天到期",
                             ok: days > 2) { EmptyView() }
                }
            } header: {
                Text("必要設定")
            }

            Section {
                Toggle(isOn: $model.locationKeepAliveEnabled) {
                    CheckLabel(title: "鎖定時也更新歌詞（使用定位，實驗）",
                               detail: model.locationKeepAliveEnabled ? model.locationKeepAliveStatus
                                                                       : "開車時用最低精準度定位，讓鎖定後也有機會更新",
                               // 選用：關著也不算「需要處理」，只有開了卻沒有定位權限才提醒
                               ok: !model.locationKeepAliveEnabled
                                   || model.locationKeepAlive.authorization != .denied)
                }
            } header: {
                Text("選用")
            } footer: {
                Text("打開時會詢問定位權限，請選「使用 App 期間」。只在車上用，不記錄、不上傳位置。")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("上車自動打開 CarLyrics", systemImage: "wand.and.stars")
                        .font(.headline)
                    Text("iOS 只讓 App 在打開時開始顯示鎖定畫面與 CarPlay 歌詞。設一次捷徑自動化，之後每次上車都會自動打開；把手機放在車架上、讓 CarLyrics 留在螢幕上（專注模式幾乎全黑），CarPlay 歌詞就會逐句更新。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(Self.automationSteps.enumerated()), id: \.offset) { i, step in
                            Text("\(i + 1). \(step)")
                                .font(.subheadline)
                        }
                    }
                    // iOS 在手機鎖定時不一定會真的把 App 叫到前景（實測前先不要說死）：給一個保險做法
                    Label {
                        Text("手機鎖著時自動化不一定會打開 App。上車後鎖定畫面沒有歌詞：點一下自動化的通知、或打開 CarLyrics 一次；還是沒有就到「設定」按「現在顯示鎖定畫面歌詞」。鎖定後 CarPlay 儀表板的歌詞會停住（iOS 限制），小工具頁仍會照時間軸繼續。")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Button {
                        if let url = URL(string: "shortcuts://") { openURL(url) }
                    } label: {
                        Label("打開捷徑 App", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 6)
            } header: {
                Text("每次上車")
            }

            Section {
                GuideRow(symbol: "car.fill", title: "把小工具加到 CarPlay（手機鎖定時的備援）",
                         steps: ["iPhone「設定」→「一般」→「CarPlay」", "選你的車 →「小工具」", "打開「顯示小工具」，加入 CarLyrics",
                                 "小工具不靠 App 在前景，鎖定手機後仍會每十幾秒換一段"])
                GuideRow(symbol: "rectangle.stack", title: "在 CarPlay 打開即時動態",
                         steps: ["同一頁（CarPlay → 你的車）", "打開「即時動態」"])
            } header: {
                Text("CarPlay 設定（做一次就好）")
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

extension SetupChecklistView {
    static let automationSteps = [
        "捷徑 App →「自動化」→ 右上角「+」",
        "選「CarPlay」→ 勾「連接」→ 選「立即執行」",
        "動作搜尋「CarLyrics」→ 選「專注模式」",
    ]
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
