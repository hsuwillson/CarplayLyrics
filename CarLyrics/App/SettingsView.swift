import SwiftUI

/// 設定頁（由主畫面右上角齒輪打開）：帳號、歌詞時間、開車模式、歌詞、進階
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                AccountSection(auth: model.auth)
                OffsetSection()
                DrivingSection()
                LyricsSection()
                AdvancedSection()
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
    @EnvironmentObject private var model: AppModel
    @ObservedObject var auth: SpotifyAuth

    private var statusText: String {
        guard auth.isLoggedIn else { return "尚未登入 Spotify" }
        return model.statusMessage.isEmpty ? "已登入" : model.statusMessage
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                StatusDot(color: auth.isLoggedIn ? .green : .gray)
                Text(statusText)
                    .lineLimit(2)
            }
            if auth.isLoggedIn {
                if !model.canControlPlayback {
                    Label("要使用播放按鈕，請先登出再重新登入 Spotify", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
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

// MARK: 歌詞時間

private struct OffsetSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            Stepper(value: $model.offset, in: -5...5, step: 0.25) {
                LabeledContent("所有歌曲", value: String(format: "%+.2f 秒", model.offset))
                    .monospacedDigit()
            }
            if model.nowPlaying != nil {
                Stepper(value: $model.songOffset, in: -5...5, step: 0.25) {
                    LabeledContent("只有這首歌", value: String(format: "%+.2f 秒", model.songOffset))
                        .monospacedDigit()
                }
            }
            if model.offset != 0 || model.songOffset != 0 {
                Button("全部歸零") {
                    model.offset = 0
                    if model.nowPlaying != nil { model.songOffset = 0 }
                }
            }
        } header: {
            Text("歌詞提前")
        } footer: {
            Text("歌詞比聲音慢就調大，比聲音快就調小。「所有歌曲」套用到每一首；「只有這首歌」會記在這首歌上，下次播放自動套用。")
        }
    }
}

// MARK: 開車模式

private struct DrivingSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            Toggle(isOn: $model.backgroundEnabled) {
                Label("背景持續執行", systemImage: "arrow.clockwise.circle")
            }
            Toggle(isOn: $model.liveActivityEnabled) {
                Label("Live Activity（鎖定畫面 / CarPlay）", systemImage: "car")
            }
            Toggle(isOn: $model.locationAssistEnabled) {
                Label("背景定位輔助（讓鎖定畫面持續更新）", systemImage: "location")
            }
            .disabled(!model.backgroundEnabled)
            Toggle(isOn: $model.keepScreenOn) {
                Label("播放時螢幕不自動關閉", systemImage: "sun.max")
            }
        } header: {
            Text("開車模式")
        } footer: {
            Text("開車前先打開一次 CarLyrics 再鎖定手機；Live Activity 只能在 App 開著時啟動。背景定位只用最低精準度，不記錄也不上傳位置。停止播放 10 分鐘後會自動停止背景執行以省電。")
        }
    }
}

// MARK: 歌詞

private struct LyricsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            LabeledContent("狀態", value: model.lyricsStatus)
            if let np = model.nowPlaying {
                LabeledContent("歌曲", value: "\(np.title) – \(np.artist)")
                    .lineLimit(1)
            }
            if model.hasManualLyrics {
                Button(role: .destructive) {
                    model.resetManualLyrics()
                } label: {
                    Label("取消手動指定，改回自動搜尋", systemImage: "arrow.uturn.backward")
                }
            }
            Button {
                model.clearLyricsCache()
            } label: {
                Label("清除歌詞快取（保留手動指定）", systemImage: "trash")
            }
        } header: {
            Text("歌詞")
        } footer: {
            Text("要換成其他版本的歌詞或匯入 LRC 檔，請用主畫面的「換歌詞」。")
        }
    }
}

// MARK: 進階

private struct AdvancedSection: View {
    var body: some View {
        Section {
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("除錯", systemImage: "ladybug")
            }
            LabeledContent("版本", value: BuildInfo.summary)
                .font(.footnote)
        } header: {
            Text("進階")
        }
    }
}
