import SwiftUI

/// 設定頁（由主畫面右上角齒輪打開）：
/// 設定檢查 / 開車 / 實驗 / 歌詞 / Spotify 帳號 / 進階 / 關於（診斷在關於裡）。
/// 原生分組列表；每列左邊一個彩色小方塊圖示（跟 iOS 設定一樣），顏色依主題分：開車＝藍、實驗＝紫、
/// 歌詞＝靛藍、進階＝灰、關於＝灰。
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        SetupChecklistView()
                    } label: {
                        SettingsLabel("設定檢查",
                                      subtitle: model.setupNeedsAttention ? "有項目需要處理" : "一切正常",
                                      symbol: model.setupNeedsAttention ? "exclamationmark" : "checkmark",
                                      color: model.setupNeedsAttention ? Theme.Semantic.attention : Theme.Semantic.ok)
                    }
                }
                DrivingSection()
                LyricsSection()
                AccountSection()
                AdvancedSection()
                AboutSection()
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: 開車

private struct DrivingSection: View {
    @Environment(AppModel.self) private var model
    /// 按過「現在顯示」之後的回饋（liveActivity 不是 @Observable，按鈕狀態不會自己更新）
    @State private var startRequestedAt: Date?

    var body: some View {
        @Bindable var model = model
        Section {
            Picker(selection: $model.liveActivityMode) {
                ForEach(LiveActivityMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                SettingsLabel("鎖定畫面與 CarPlay 歌詞", symbol: "car.fill", color: .blue)
            }
            Toggle(isOn: $model.autoFocusInCar) {
                SettingsLabel("連上 CarPlay 時自動進入專注模式", symbol: "moon.fill", color: .indigo)
            }
            Toggle(isOn: $model.keepAwakeWhileDriving) {
                SettingsLabel("開車時保持螢幕開著", symbol: "iphone", color: .blue)
            }
            if model.keepAwakeWhileDriving {
                Toggle(isOn: $model.dimScreenWhileDriving) {
                    SettingsLabel("開車時把螢幕調暗", symbol: "sun.min.fill", color: .blue)
                }
            }
            // 一律顯示：「開車時」模式在家看得出為什麼沒有鎖定畫面歌詞；車子沒被認出來時也看得出來
            LabeledContent {
                Text(model.isCarConnected ? "已連接" : "未連接")
                    .foregroundStyle(model.isCarConnected ? Theme.Semantic.playing : Color.secondary)
            } label: {
                SettingsLabel("CarPlay", symbol: "cable.connector", color: .gray)
            }
            if model.liveActivityMode != .off, model.auth.isLoggedIn, model.activitiesEnabled {
                // 手動開始：車子沒被認出來、或 App 在背景時沒開成功，不用等下一次連接（還沒播歌就先顯示「連接中」）
                Button {
                    model.startLiveActivityNow()
                    startRequestedAt = Date()
                } label: {
                    SettingsLabel(startRequestedAt == nil ? "現在顯示鎖定畫面歌詞" : "已送出，看一下鎖定畫面",
                                  symbol: "lock.iphone", color: .blue)
                }
                .accessibilityLabel("現在顯示鎖定畫面歌詞")
                .accessibilityHint("不必連上 CarPlay，馬上在鎖定畫面開始顯示這首歌的歌詞")
            }
        } header: {
            Text("開車")
        } footer: {
            Text(footer(for: model.liveActivityMode))
        }

        Section {
            Toggle(isOn: $model.locationKeepAliveEnabled) {
                SettingsLabel("鎖定時也更新歌詞（使用定位）", symbol: "location.fill", color: .purple)
            }
            if model.locationKeepAliveEnabled {
                LabeledContent("狀態", value: model.locationKeepAliveStatus)
                    .font(.footnote)
                if model.locationKeepAlive.authorization == .denied {
                    Button {
                        model.perform(.openSettings)
                    } label: {
                        SettingsLabel("到系統設定允許定位", symbol: "gear", color: .gray)
                    }
                }
            }
        } header: {
            Text("實驗")
        } footer: {
            Text("iOS 只擋「只有背景音訊」的 App 更新鎖定畫面。打開後，連上 CarPlay 且歌詞顯示中時會用最低精準度的定位，讓手機鎖定後也有機會繼續更新 CarPlay 歌詞。只在車上用，下車就停；不記錄、不上傳位置（狀態列會出現藍色定位指示，是系統規定）。有沒有效請看「診斷」的「理由統計」。")
        }
    }

    private func footer(for mode: LiveActivityMode) -> String {
        switch mode {
        case .whileDriving:
            return "連上 CarPlay 才顯示，下車自動收起。iOS 只讓 App 在打開時開始顯示，所以上車後要打開一次 CarLyrics（可用捷徑自動化，見「設定檢查」）。手機鎖定後 iOS 會擋掉更新，CarPlay 歌詞會停住——開車時讓 CarLyrics 留在螢幕上（專注模式幾乎全黑），或試試下面的實驗。"
        case .always:
            return "播歌時就在鎖定畫面顯示歌詞；動態島會多一個小圖示（系統規定）。沒在播放一陣子會自動收起。手機鎖定後 iOS 會擋掉更新，開車時請讓 CarLyrics 留在螢幕上。"
        case .off:
            return "不在鎖定畫面與 CarPlay 顯示歌詞；仍可使用小工具（CarPlay 小工具頁、鎖定畫面）。"
        }
    }
}

// MARK: 歌詞

private struct LyricsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Stepper(value: $model.globalOffset, in: -5...5, step: 0.25) {
                LabeledContent {
                    Text(String(format: "%+.2f 秒", model.globalOffset))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: model.globalOffset))
                } label: {
                    SettingsLabel("歌詞提前（所有歌曲）", symbol: "timer", color: .indigo)
                }
            }
            if model.nowPlaying != nil {
                Stepper(value: $model.trackOffset, in: -5...5, step: 0.25) {
                    LabeledContent {
                        Text(String(format: "%+.2f 秒", model.trackOffset))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: model.trackOffset))
                    } label: {
                        SettingsLabel("歌詞提前（只有這首）", symbol: "music.note", color: .indigo)
                    }
                }
            }
            if model.globalOffset != 0 || model.trackOffset != 0 {
                Button("歌詞提前全部歸零") {
                    model.globalOffset = 0
                    if model.nowPlaying != nil { model.trackOffset = 0 }
                }
            }
            if let np = model.nowPlaying {
                LabeledContent("目前歌曲") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(np.title) – \(np.artist)")
                            .lineLimit(1)
                        Text(model.lyrics.state.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if model.lyrics.hasManualLyrics {
                Button(role: .destructive) {
                    model.lyrics.resetManual()
                } label: {
                    Label("取消手動指定，改回自動搜尋", systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text("歌詞")
        } footer: {
            Text("歌詞比聲音慢就調大，比聲音快就調小；「只有這首」會記在這首歌上。要換版本或匯入 LRC 檔，用主畫面的「選擇歌詞」。")
        }
    }
}

// MARK: 帳號

private struct AccountSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmLogout = false

    var body: some View {
        Section {
            HStack(spacing: Theme.Spacing.m) {
                SettingsIcon(symbol: "person.fill",
                             color: model.auth.isLoggedIn ? Theme.Semantic.ok : Theme.Semantic.idle)
                Text(model.auth.isLoggedIn ? "已登入" : "尚未登入")
                    .lineLimit(2)
            }
            if model.auth.isLoggedIn {
                if !model.canControlPlayback {
                    Button {
                        model.relogin()
                    } label: {
                        Label("重新登入以使用播放按鈕", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Semantic.attention)
                    }
                }
                Button("登出 Spotify", role: .destructive) { confirmLogout = true }
                    .confirmationDialog("登出後會停止同步歌詞", isPresented: $confirmLogout, titleVisibility: .visible) {
                        Button("登出", role: .destructive) { model.logout() }
                    }
            } else {
                Button {
                    model.login()
                } label: {
                    if model.isLoggingIn {
                        Label { Text("登入中…") } icon: { ProgressView() }
                    } else {
                        Text("登入 Spotify")
                    }
                }
                .disabled(model.isLoggingIn)
            }
        } header: {
            Text("Spotify 帳號")
        }
    }
}

// MARK: 進階

private struct AdvancedSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle(isOn: $model.backgroundEnabled) {
                SettingsLabel("鎖定手機後繼續同步", symbol: "arrow.clockwise", color: .gray)
            }
            Toggle(isOn: $model.endActivityWhenIdle) {
                SettingsLabel("沒在播放時收起鎖定畫面歌詞", symbol: "rectangle.topthird.inset.filled", color: .gray)
            }
            Toggle(isOn: $model.keepScreenOn) {
                SettingsLabel("播放時螢幕不自動關閉（不限開車）", symbol: "sun.max.fill", color: .gray)
            }
            Toggle(isOn: $model.prefetchQueueOnWiFi) {
                SettingsLabel("Wi-Fi 時預先載入播放佇列的歌詞", symbol: "wifi", color: .gray)
            }
            Button {
                model.lyrics.clearCache()
            } label: {
                SettingsLabel("清除歌詞快取（保留手動指定）", symbol: "trash", color: .gray)
            }
        } header: {
            Text("進階")
        } footer: {
            Text("「繼續同步」讓 App 在背景追蹤 Spotify，小工具與回到前景時的歌詞才會是對的。「收起」：Spotify 停止 30 秒、暫停 5 分鐘後收起；連著 CarPlay 時暫停不收，講電話不算閒置。預先載入讓進隧道、地下停車場也有歌詞。")
        }
    }
}

// MARK: 關於

private struct AboutSection: View {
    @Environment(AppModel.self) private var model
    @State private var exportFile: ExportFile?

    var body: some View {
        Section {
            LabeledContent("版本", value: BuildInfo.summary)
            if let date = BuildInfo.buildDate {
                LabeledContent("建置時間", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if let exp = model.signingExpiration, let days = model.signingDaysRemaining {
                LabeledContent("簽名有效至") {
                    Text("\(exp.formatted(.dateTime.month().day()))（剩 \(max(0, days)) 天）")
                        .foregroundStyle(days <= 2 ? Theme.Semantic.attention : Color.secondary)
                }
            }
            NavigationLink {
                DiagnosticsView()
            } label: {
                SettingsLabel("診斷", symbol: "stethoscope", color: .gray)
            }
            Button {
                exportFile = ExportFile(url: model.writeDiagnosticsExport())
            } label: {
                SettingsLabel("分享診斷紀錄", symbol: "square.and.arrow.up", color: .gray)
            }
            .sheet(item: $exportFile) { file in
                ShareSheet(url: file.url)
            }
        } header: {
            Text("關於")
        } footer: {
            Text("登入資訊只存在 iOS 鑰匙圈；歌詞快取在這支 iPhone 上；不收集任何資料。歌詞由 LRCLIB 提供。")
        }
    }
}
