import ActivityKit
import Combine
import SwiftUI
import UIKit

/// 診斷頁：背景執行、即時動態、小工具、歌詞的即時狀態與紀錄檔
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    private var log: DebugLog { DebugLog.shared }
    @State private var appGroupOK = false
    /// 分享用的檔案（按下分享時才產生：目前狀態 + 完整紀錄）
    @State private var exportFile: ExportFile?
    @State private var confirmClear = false
    /// 每秒刷新一次（背景音訊、即時動態的狀態不會觸發畫面更新）
    @State private var now = Date()
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            shareSection
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
                Button {
                    shareLog()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享診斷紀錄")
                Button("清除") { confirmClear = true }
            }
        }
        .confirmationDialog("清除所有診斷紀錄？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { log.clear() }
        }
        .sheet(item: $exportFile) { file in
            ShareSheet(url: file.url)
        }
        .onAppear { check() }
        .onReceive(refresh) { now = $0 }
    }

    // MARK: 區塊

    private var shareSection: some View {
        Section {
            Button {
                shareLog()
            } label: {
                Label("分享診斷紀錄給 Claude", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } footer: {
            Text("會附上目前所有狀態與完整紀錄（含歌名／歌手與歌詞搜尋，不含帳號或密碼）。出問題時先別關 App，直接按這裡。")
        }
    }

    private func shareLog() {
        exportFile = ExportFile(url: model.writeDiagnosticsExport())
    }

    private var overviewSection: some View {
        Section("總覽") {
            DiagRow("Spotify", value: model.auth.isLoggedIn ? "已登入" : "未登入", ok: model.auth.isLoggedIn)
            DiagRow("網路", value: model.isOnline ? "已連線" : "離線", ok: model.isOnline)
            DiagRow("背景音訊", value: model.audioKeeper.isRunning ? "執行中" : "停止",
                    ok: model.audioKeeper.isRunning || !model.backgroundEnabled)
            DiagRow("即時動態", value: model.liveActivity.stateDescription,
                    ok: model.liveActivity.isActive || !model.liveActivityEnabled)
            DiagRow("小工具", value: LyricsTimelineStore.neverRendered ? "尚未加入任何畫面" : model.widget.modeDescription,
                    ok: model.widget.mode == .perLine)
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
            LabeledContent("電源", value: Self.batteryLabel(UIDevice.current.batteryState))
            LabeledContent("車用音訊", value: model.isCarConnected ? "已連接" : "未連接")
            LabeledContent("開車模式",
                           value: model.isDrivingModeActive ? "生效（留在前景、螢幕不自動關閉）" : "未生效")
            LabeledContent("螢幕自動關閉", value: UIApplication.shared.isIdleTimerDisabled ? "已停用" : "正常")
        }
    }

    /// 充電中時輪詢會用前景的間隔（車上多半插著充電）
    private static func batteryLabel(_ s: UIDevice.BatteryState) -> String {
        switch s {
        case .charging: return "充電中"
        case .full: return "已充飽"
        case .unplugged: return "電池"
        default: return "未知"
        }
    }

    private var backgroundSection: some View {
        Section {
            LabeledContent("無聲音訊", value: model.audioKeeper.isRunning ? "執行中" : "停止")
            if model.audioKeeper.interrupted {
                LabeledContent("音訊中斷", value: "中（講電話 / Siri）")
            }
            LabeledContent("重啟次數", value: "\(model.audioKeeper.restartCount)")
            if let reason = model.audioKeeper.lastRestartReason,
               let at = model.audioKeeper.lastRestartAt {
                LabeledContent("最近重啟", value: "\(at.formatted(date: .omitted, time: .standard)) \(reason)")
                    .font(.caption)
            }
            LabeledContent("最近輪詢", value: model.lastPollAt.map { "\(Int(now.timeIntervalSince($0))) 秒前" } ?? "—")
            LabeledContent("最長輪詢間隔", value: String(format: "%.1f 秒", model.maxPollGap))
            LabeledContent("輪詢往返（最近 / 最長）",
                           value: String(format: "%.2f / %.2f 秒", model.lastPollRoundTrip, model.maxPollRoundTrip))
            LabeledContent("回應大小", value: "\(model.lastResponseBytes) bytes")
            if let error = model.lastErrorDetail {
                LabeledContent("最近錯誤", value: error).font(.caption)
            }
            Button("重設統計") {
                model.resetDiagnostics()
                LyricsTimelineStore.resetRenderLagStats()
            }
        } header: {
            Text("背景執行")
        } footer: {
            Text("省電：沒有播放 10 分鐘、暫停 30 分鐘、廣告／Podcast 60 分鐘後停止背景執行（連著 CarPlay 時放寬 3 倍；講電話不算）；下次打開 App 會自動恢復。")
        }
    }

    private var liveActivitySection: some View {
        Section {
            LabeledContent("狀態", value: model.liveActivity.stateDescription)
            LabeledContent("更新次數", value: "\(model.liveActivity.updateCount)")
            LabeledContent("系統套用 / 被擋", value: "\(model.liveActivity.acceptedCount) / \(model.liveActivity.rejectedCount)")
            LabeledContent("未驗證", value: "\(model.liveActivity.verifySkipped)")
            if model.liveActivity.backgroundBlocked {
                LabeledContent("背景更新", value: "被擋（每 15 秒探測一次）")
            }
            if let interval = model.liveActivity.lastStaleInterval {
                LabeledContent("staleDate", value: "送出後 \(Int(interval)) 秒（下一句 + 寬限）")
            }
            LabeledContent("stale 次數 / 畫面自己推進",
                           value: "\(model.liveActivity.staleCount) / \(model.liveActivity.staleAdvanceCount)")
            if let at = model.liveActivity.lastRejectedAt {
                LabeledContent("最近被擋", value: at.formatted(date: .omitted, time: .standard))
            }
            if let field = model.liveActivity.lastMismatchField {
                LabeledContent("最近不同的欄位", value: field).font(.caption)
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
            Text("「未驗證」= 送出後 2 秒內又有新內容，來不及確認系統有沒有套用（歌詞密集時很常見，不是問題）。「被擋」多發生在 App 不在螢幕上時：iOS 會拒絕背景送出的更新，所以開車時請讓 CarLyrics 留在前景。stale = 超過 staleDate 沒更新，畫面會自己把下一句升成目前句一次。iOS 最多讓即時動態持續 8 小時；長途中途打開 App 時會自動換新。")
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
            if let lag = LyricsTimelineStore.lastRenderLag {
                LabeledContent("重新整理延遲（最近 / 最大）",
                               value: String(format: "%.1f / %.1f 秒", lag, LyricsTimelineStore.maxRenderLag ?? lag))
            }
            if let count = LyricsTimelineStore.lastRenderEntryCount {
                LabeledContent("最近交出的格數",
                               value: LyricsTimelineStore.lastRenderFirstIndex.map { "\(count)（從第 \($0 + 1) 句起）" } ?? "\(count)")
            }
            if LyricsTimelineStore.neverRendered {
                LabeledContent("狀態", value: "尚未加入任何畫面")
            }
        } header: {
            Text("小工具")
        } footer: {
            Text("「實際」遠少於「要求」代表系統在節流；App 會自動改用一次顯示一段的段落模式。「延遲」= App 寫入時間軸到系統真的來拿之間隔了多久（只算 5 分鐘內的）。")
        }
    }

    private var lyricsSection: some View {
        Section("歌詞") {
            LabeledContent("狀態", value: model.lyrics.state.label)
            LabeledContent("來源", value: model.lyrics.hasManualLyrics ? "手動指定" : "自動搜尋")
            LabeledContent("歌詞提前", value: String(format: "全部 %+.2f 秒 · 這首 %+.2f 秒", model.globalOffset, model.trackOffset))
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

/// 分享的檔案（sheet 需要 Identifiable）
struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// 系統分享面板
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
