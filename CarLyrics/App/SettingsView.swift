import SwiftUI

/// 設定頁（由主畫面右上角齒輪打開）：
/// 設定檢查 / 開車 / 歌詞提前 / 歌詞 / 帳號 / 關於 / 診斷
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
                        Label {
                            Text("設定檢查")
                        } icon: {
                            Image(systemName: model.setupNeedsAttention ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(model.setupNeedsAttention ? Color.orange : Color.green)
                        }
                    }
                }
                DrivingSection()
                OffsetSection()
                LyricsSection()
                AccountSection()
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

// MARK: 帳號

private struct AccountSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmLogout = false

    var body: some View {
        Section {
            HStack(spacing: 10) {
                StatusDot(color: model.auth.isLoggedIn ? .green : .gray)
                Text(model.auth.isLoggedIn ? "已登入" : "尚未登入 Spotify")
                    .lineLimit(2)
            }
            if model.auth.isLoggedIn {
                if !model.canControlPlayback {
                    Button {
                        model.relogin()
                    } label: {
                        Label("重新登入以使用播放按鈕", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Button("登出 Spotify", role: .destructive) { confirmLogout = true }
                    .confirmationDialog("登出後會停止同步歌詞", isPresented: $confirmLogout, titleVisibility: .visible) {
                        Button("登出", role: .destructive) { model.logout() }
                    }
            } else {
                Button("登入 Spotify") { model.login() }
            }
        } header: {
            Text("Spotify 帳號")
        }
    }
}

// MARK: 歌詞提前

private struct OffsetSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Stepper(value: $model.globalOffset, in: -5...5, step: 0.25) {
                LabeledContent("所有歌曲", value: String(format: "%+.2f 秒", model.globalOffset))
                    .monospacedDigit()
            }
            if model.nowPlaying != nil {
                Stepper(value: $model.trackOffset, in: -5...5, step: 0.25) {
                    LabeledContent("只有這首歌", value: String(format: "%+.2f 秒", model.trackOffset))
                        .monospacedDigit()
                }
            }
            if model.globalOffset != 0 || model.trackOffset != 0 {
                Button("全部歸零") {
                    model.globalOffset = 0
                    if model.nowPlaying != nil { model.trackOffset = 0 }
                }
            }
        } header: {
            Text("歌詞提前")
        } footer: {
            Text("歌詞比聲音慢就調大，比聲音快就調小。「只有這首歌」會記在這首歌上，下次播放自動套用。")
        }
    }
}

// MARK: 開車模式

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
                Label("鎖定畫面與 CarPlay 歌詞", systemImage: "car")
            }
            Toggle(isOn: $model.autoFocusInCar) {
                Label("連上 CarPlay 時自動進入專注模式", systemImage: "car.side")
            }
            Toggle(isOn: $model.keepAwakeWhileDriving) {
                Label("開車時保持螢幕開著（CarPlay 歌詞才會即時更新）", systemImage: "iphone.and.arrow.forward")
            }
            if model.keepAwakeWhileDriving {
                Toggle(isOn: $model.dimScreenWhileDriving) {
                    Label("開車時把手機螢幕調暗", systemImage: "sun.min")
                }
            }
            Toggle(isOn: $model.keepScreenOn) {
                Label("播放時螢幕不自動關閉", systemImage: "sun.max")
            }
            // 一律顯示：「開車時」模式在家看得出為什麼沒有鎖定畫面歌詞；車子沒被認出來時也看得出來
            LabeledContent("CarPlay", value: model.isCarConnected ? "已連接" : "未連接")
                .font(.footnote)
            if model.liveActivityMode != .off, model.auth.isLoggedIn, model.activitiesEnabled {
                // 手動開始：車子沒被認出來、或 App 在背景時沒開成功，不用等下一次連接（還沒播歌就先顯示「連接中」）
                Button {
                    model.startLiveActivityNow()
                    startRequestedAt = Date()
                } label: {
                    Label(startRequestedAt == nil ? "現在顯示鎖定畫面歌詞" : "已送出，看一下鎖定畫面",
                          systemImage: "lock.iphone")
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
            Toggle(isOn: $model.backgroundEnabled) {
                Label("鎖定手機後繼續同步", systemImage: "arrow.clockwise.circle")
            }
            Toggle(isOn: $model.endActivityWhenIdle) {
                Label("沒在播放時收起鎖定畫面歌詞", systemImage: "rectangle.topthird.inset.filled")
            }
        } header: {
            Text("進階")
        } footer: {
            Text("「鎖定手機後繼續同步」讓 App 在背景繼續追蹤 Spotify（小工具與回到前景時的歌詞才會是對的）；但 iOS 仍會擋掉背景送出的鎖定畫面／CarPlay 更新。收起：Spotify 停止 30 秒、暫停 5 分鐘後自動結束；連著 CarPlay 時暫停不收（得來速、等人都沒事），沒在播放 30 分鐘才收；講電話不算閒置。")
        }
    }

    private func footer(for mode: LiveActivityMode) -> String {
        switch mode {
        case .whileDriving:
            return "連上 CarPlay 才顯示，平常動態島保持乾淨，下車自動收起。iOS 只允許 App 打開時開始顯示，所以上車後要打開一次 CarLyrics——到「設定檢查」設定捷徑自動化。\n重要：CarLyrics 不在螢幕上（鎖定或切到別的 App）時，iOS 會擋掉它送出的更新，CarPlay 歌詞就會停在最後一句；所以開車時請讓 CarLyrics 留在手機螢幕上（專注模式幾乎全黑，不費電），「保持螢幕開著」會幫你不讓手機自動鎖定。鎖定後只剩 CarPlay 小工具頁的歌詞會照時間軸動。"
        case .always:
            return "播歌時在鎖定畫面顯示歌詞。iOS 會同時在動態島放一個小圖示（系統規定，無法關閉）；沒在播放一陣子後會自動收起。CarLyrics 不在螢幕上時 iOS 會擋掉更新，歌詞會停住——開車時請讓它留在螢幕上。"
        case .off:
            return "不在鎖定畫面與 CarPlay 顯示歌詞。可以改用小工具（CarPlay 小工具頁、鎖定畫面）。"
        }
    }
}

// MARK: 歌詞

private struct LyricsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            LabeledContent("狀態", value: model.lyrics.state.label)
            if let np = model.nowPlaying {
                LabeledContent("歌曲", value: "\(np.title) – \(np.artist)")
                    .lineLimit(1)
            }
            if model.lyrics.hasManualLyrics {
                Button(role: .destructive) {
                    model.lyrics.resetManual()
                } label: {
                    Label("取消手動指定，改回自動搜尋", systemImage: "arrow.uturn.backward")
                }
            }
            Toggle(isOn: $model.prefetchQueueOnWiFi) {
                Label("Wi-Fi 時預先載入整個播放佇列", systemImage: "wifi")
            }
            Button {
                model.lyrics.clearCache()
            } label: {
                Label("清除歌詞快取（保留手動指定）", systemImage: "trash")
            }
        } header: {
            Text("歌詞")
        } footer: {
            Text("要換成其他版本的歌詞或匯入 LRC 檔，請用主畫面的「選擇歌詞」。預先載入會在換歌時進行，進隧道或地下停車場也看得到歌詞。")
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
                        .foregroundStyle(days <= 2 ? Color.orange : Color.secondary)
                }
            }
            Button {
                exportFile = ExportFile(url: model.writeDiagnosticsExport())
            } label: {
                Label("分享診斷紀錄", systemImage: "square.and.arrow.up")
            }
            .sheet(item: $exportFile) { file in
                ShareSheet(url: file.url)
            }
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("診斷", systemImage: "stethoscope")
            }
        } header: {
            Text("關於")
        } footer: {
            Text("登入資訊只存在 iOS 鑰匙圈；歌詞快取在這支 iPhone 上；不收集任何資料。歌詞由 LRCLIB 提供。")
        }
    }
}
