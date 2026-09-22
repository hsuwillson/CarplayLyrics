import SwiftUI

/// 設定頁（由主畫面右上角齒輪打開）：
/// 設定檢查 / 帳號 / 歌詞提前 / 開車模式 / 歌詞 / 關於 / 診斷
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
                AccountSection()
                OffsetSection()
                DrivingSection()
                LyricsSection()
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

    var body: some View {
        Section {
            HStack(spacing: 10) {
                StatusDot(color: model.auth.isLoggedIn ? .green : .gray)
                Text(model.auth.isLoggedIn ? model.session.label : "尚未登入 Spotify")
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
                Button("登出 Spotify", role: .destructive) { model.logout() }
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

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle(isOn: $model.backgroundEnabled) {
                Label("背景持續執行", systemImage: "arrow.clockwise.circle")
            }
            Toggle(isOn: $model.liveActivityEnabled) {
                Label("即時動態（鎖定畫面 / CarPlay）", systemImage: "car")
            }
            Toggle(isOn: $model.keepScreenOn) {
                Label("播放時螢幕不自動關閉", systemImage: "sun.max")
            }
        } header: {
            Text("開車模式")
        } footer: {
            Text("即時動態只能在 App 開著時啟動：上車時先打開一次 CarLyrics 再鎖定手機。")
        }
    }
}

// MARK: 歌詞

private struct LyricsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
            Button {
                model.lyrics.clearCache()
            } label: {
                Label("清除歌詞快取（保留手動指定）", systemImage: "trash")
            }
        } header: {
            Text("歌詞")
        } footer: {
            Text("要換成其他版本的歌詞或匯入 LRC 檔，請用主畫面的「選擇歌詞」。")
        }
    }
}

// MARK: 關於

private struct AboutSection: View {
    @Environment(AppModel.self) private var model

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
