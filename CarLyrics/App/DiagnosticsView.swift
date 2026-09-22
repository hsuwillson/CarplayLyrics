import ActivityKit
import Combine
import SwiftUI

/// 診斷頁：背景執行、即時動態、小工具、歌詞的即時狀態與紀錄檔
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    private var log: DebugLog { DebugLog.shared }
    @State private var appGroupOK = false
    /// 每秒刷新一次（背景音訊、即時動態的狀態不會觸發畫面更新）
    @State private var now = Date()
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            overviewSection
            versionSection
            systemSection
            backgroundSection
            liveActivitySection
            widgetSection
            lyricsSection
            logSection
        }
        .navigationTitle("診斷")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: log.fileURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享診斷紀錄")
                Button("清除") { log.clear() }
            }
        }
        .onAppear { check() }
        .onReceive(refresh) { now = $0 }
    }

    // MARK: 區塊

    private var overviewSection: some View {
        Section("總覽") {
            DiagRow("Spotify", value: model.auth.isLoggedIn ? "已登入" : "未登入", ok: model.auth.isLoggedIn)
            DiagRow("網路", value: model.isOnline ? "已連線" : "離線", ok: model.isOnline)
            DiagRow("背景音訊", value: model.audioKeeper.isRunning ? "執行中" : "停止",
                    ok: model.audioKeeper.isRunning || !model.backgroundEnabled)
            DiagRow("即時動態", value: model.liveActivity.stateDescription,
                    ok: model.liveActivity.isActive || !model.liveActivityEnabled)
            DiagRow("小工具", value: model.widget.modeDescription, ok: model.widget.mode == .perLine)
            DiagRow("歌詞", value: model.lyrics.state.label, ok: model.hasSyncedLyrics)
        }
    }

    private var versionSection: some View {
        Section("版本") {
            LabeledContent("Build", value: BuildInfo.summary)
            if let date = BuildInfo.buildDate {
                LabeledContent("建置時間", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if let exp = model.signingExpiration {
                LabeledContent("簽名到期", value: exp.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("Bundle ID") {
                Text(Bundle.main.bundleIdentifier ?? "?").font(.caption2)
            }
            LabeledContent("Client ID", value: AppConfig.spotifyClientID.isEmpty ? "尚未設定" : "已設定")
        }
    }

    private var systemSection: some View {
        Section("系統") {
            LabeledContent("App Group", value: appGroupOK ? "OK" : "失敗")
            LabeledContent("Group ID") {
                Text(AppGroup.identifier).font(.caption2)
            }
            LabeledContent("即時動態權限", value: model.activitiesEnabled ? "已允許" : "未允許")
            LabeledContent("耗電狀態", value: model.power.description)
        }
    }

    private var backgroundSection: some View {
        Section {
            LabeledContent("無聲音訊", value: model.audioKeeper.isRunning ? "執行中" : "停止")
            LabeledContent("重啟次數", value: "\(model.audioKeeper.restartCount)")
            if let reason = model.audioKeeper.lastRestartReason,
               let at = model.audioKeeper.lastRestartAt {
                LabeledContent("最近重啟", value: "\(at.formatted(date: .omitted, time: .standard)) \(reason)")
                    .font(.caption)
            }
            LabeledContent("最近輪詢", value: model.lastPollAt.map { "\(Int(now.timeIntervalSince($0))) 秒前" } ?? "—")
            LabeledContent("最長輪詢間隔", value: String(format: "%.1f 秒", model.maxPollGap))
            LabeledContent("回應大小", value: "\(model.lastResponseBytes) bytes")
            if let error = model.lastErrorDetail {
                LabeledContent("最近錯誤", value: error).font(.caption)
            }
            Button("重設統計") { model.resetDiagnostics() }
        } header: {
            Text("背景執行")
        } footer: {
            Text("沒有播放 10 分鐘、或暫停 30 分鐘後，會自動停止背景執行以省電；下次打開 App 會自動恢復。")
        }
    }

    private var liveActivitySection: some View {
        Section {
            LabeledContent("狀態", value: model.liveActivity.stateDescription)
            LabeledContent("更新次數", value: "\(model.liveActivity.updateCount)")
            LabeledContent("系統套用 / 被擋", value: "\(model.liveActivity.acceptedCount) / \(model.liveActivity.rejectedCount)")
            if let at = model.liveActivity.lastRejectedAt {
                LabeledContent("最近被擋", value: at.formatted(date: .omitted, time: .standard))
            }
            if let at = model.liveActivity.lastUpdateAt {
                LabeledContent("最後更新", value: at.formatted(date: .omitted, time: .standard))
            }
            if let at = model.liveActivity.startedAt {
                LabeledContent("開始時間", value: at.formatted(date: .omitted, time: .standard))
            }
            if let error = model.liveActivity.lastError {
                LabeledContent("最近錯誤", value: error).font(.caption)
            }
        } header: {
            Text("即時動態")
        } footer: {
            Text("iOS 最多讓即時動態持續 8 小時；長途中途打開 App 時會自動換新。")
        }
    }

    private var widgetSection: some View {
        Section {
            LabeledContent("模式", value: model.widget.modeDescription)
            LabeledContent("要求 / 系統實際重新整理", value: "\(model.widget.requestCount) / \(model.widget.renderCount)")
            if let at = model.widget.lastRequestAt {
                LabeledContent("最後要求", value: at.formatted(date: .omitted, time: .standard))
            }
            if let at = model.widget.lastRenderAt {
                LabeledContent("系統最後重新整理", value: at.formatted(date: .omitted, time: .standard))
            }
        } header: {
            Text("小工具")
        } footer: {
            Text("「實際」遠少於「要求」代表系統在節流；App 會自動改用一次顯示一段的段落模式。")
        }
    }

    private var lyricsSection: some View {
        Section("歌詞") {
            LabeledContent("狀態", value: model.lyrics.state.label)
            LabeledContent("來源", value: model.lyrics.hasManualLyrics ? "手動指定" : "自動搜尋")
            LabeledContent("延遲", value: String(format: "全部 %+.2f 秒 · 這首 %+.2f 秒", model.globalOffset, model.trackOffset))
            Button("清除歌詞快取（保留手動指定）") { model.lyrics.clearCache() }
        }
    }

    private var logSection: some View {
        Section("紀錄（最新在上）") {
            ForEach(Array(log.entries.reversed())) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.message)
                        .font(.caption)
                }
            }
        }
    }

    private func check() {
        if let d = AppGroup.defaults {
            d.set(Date().timeIntervalSince1970, forKey: "skeletonCheck")
            appGroupOK = d.double(forKey: "skeletonCheck") > 0 && AppGroup.containerURL != nil
        }
    }
}

/// 總覽用的一列：左邊有顏色圓點
private struct DiagRow: View {
    let title: String
    let value: String
    let ok: Bool

    init(_ title: String, value: String, ok: Bool) {
        self.title = title
        self.value = value
        self.ok = ok
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: ok ? .green : .orange)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
