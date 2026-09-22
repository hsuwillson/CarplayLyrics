import ActivityKit
import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            MainScreen(auth: model.auth)
        }
        .task { model.start() }
    }
}

// MARK: - 主畫面

/// 主畫面：漸層背景 + 狀態列 + 正在播放 + 歌詞舞台 + 延遲調整 + 動作列
private struct MainScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var auth: SpotifyAuth
    @State private var showSettings = false
    @State private var showPicker = false
    @State private var showFocus = false

    var body: some View {
        ZStack {
            AppBackground(isPlaying: model.isPlaying)
            content
        }
        .navigationTitle("CarLyrics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showPicker) {
            LyricsPickerView()
                .environmentObject(model)
        }
        .fullScreenCover(isPresented: $showFocus) {
            FocusLyricsView()
                .environmentObject(model)
        }
    }

    @ViewBuilder
    private var content: some View {
        if auth.isLoggedIn {
            // 小螢幕（iPhone SE）或字體調大時放不下 → 改成可捲動，底部按鈕不會被擠出畫面
            ViewThatFits(in: .vertical) {
                mainLayout
                ScrollView {
                    mainLayout
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        } else {
            WelcomeView()
        }
    }
}

private extension MainScreen {
    var mainLayout: some View {
        VStack(spacing: 16) {
            ConnectionStatusBar()
            NowPlayingHero()
            LyricsStage()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            OffsetControl()
            ActionRow(showPicker: $showPicker, showFocus: $showFocus)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

/// 尚未登入
private struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    private var errorText: String? {
        let s = model.statusMessage
        guard !s.isEmpty, s != "請先登入 Spotify" else { return nil }
        return s
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("CarLyrics")
                .font(.largeTitle.bold())
            Text("登入 Spotify 後，開車時就能在鎖定畫面與 CarPlay 看到同步歌詞。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Button {
                model.login()
            } label: {
                Label("登入 Spotify", systemImage: "person.crop.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.green)
            .controlSize(.large)
            Spacer()
            Spacer()
        }
        .padding(32)
    }
}

/// 最上面一行：連線狀態 + 歌詞狀態
private struct ConnectionStatusBar: View {
    @EnvironmentObject private var model: AppModel

    private var dotColor: Color {
        if model.isPlaying { return .green }
        if model.nowPlaying != nil { return .yellow }
        return .gray
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: dotColor)
            Text(model.statusMessage.isEmpty ? "已連接 Spotify" : model.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(model.lyricsStatus)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

// MARK: 正在播放

private struct NowPlayingHero: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if let np = model.nowPlaying {
                TrackTitle(title: np.title, artist: np.artist, album: np.album)
                ProgressStrip(position: model.position, duration: np.duration)
                TransportControls(isPlaying: np.isPlaying)
                if !model.canControlPlayback {
                    Text("要使用播放按鈕，請先登出再重新登入 Spotify")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            } else {
                IdleHero()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TrackTitle: View {
    let title: String
    let artist: String
    let album: String

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(album.isEmpty ? artist : "\(artist) · \(album)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

private struct ProgressStrip: View {
    let position: TimeInterval
    let duration: TimeInterval

    var body: some View {
        VStack(spacing: 4) {
            ProgressView(value: min(position, duration), total: max(duration, 1))
                .tint(Color.primary)
            HStack {
                Text(formatTime(position))
                Spacer()
                Text("-" + formatTime(max(0, duration - position)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

private struct TransportControls: View {
    @EnvironmentObject private var model: AppModel
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 28) {
            TransportButton(symbol: "backward.fill") { model.previousOrRestart() }
                .accessibilityLabel("上一首")
            PlayPauseButton(isPlaying: isPlaying) {
                model.control(isPlaying ? .pause : .play)
            }
            TransportButton(symbol: "forward.fill") { model.control(.next) }
                .accessibilityLabel("下一首")
        }
    }
}

private struct IdleHero: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("沒有正在播放的歌曲")
                .font(.title3.weight(.semibold))
            Text("在 Spotify 開始播放後會自動出現")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: 歌詞舞台

private struct LyricsStage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.hasSyncedLyrics {
                SyncedLyricsStage()
            } else if let plain = model.plainLyrics {
                PlainLyricsStage(text: plain)
            } else {
                EmptyLyricsStage()
            }
        }
    }
}

private struct SyncedLyricsStage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Text(model.previousLineText.isEmpty ? " " : model.previousLineText)
                .font(.title3)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            AnimatedCurrentLine(
                text: model.currentLineText,
                index: model.display.index,
                font: .system(.largeTitle, design: .rounded, weight: .bold))
            Text(model.nextLineText.isEmpty ? " " : model.nextLineText)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

private struct PlainLyricsStage: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("這首歌只有未同步歌詞", systemImage: "text.alignleft")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct EmptyLyricsStage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: model.nowPlaying == nil ? "car.fill" : "text.quote")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            if model.nowPlaying == nil {
                Text("開車前先打開一次 CarLyrics 再鎖定手機，\n歌詞會顯示在鎖定畫面與 CarPlay。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.lyricsStatus)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

// MARK: 延遲調整（精簡版；完整版在設定）

private struct OffsetControl: View {
    @EnvironmentObject private var model: AppModel
    @State private var perSong = false

    private static let step: TimeInterval = 0.25
    private static let range: ClosedRange<TimeInterval> = -5...5

    private var usePerSong: Bool { perSong && model.nowPlaying != nil }
    private var value: TimeInterval { usePerSong ? model.songOffset : model.offset }

    var body: some View {
        HStack(spacing: 8) {
            StepButton(symbol: "minus") { adjust(-Self.step) }
                .accessibilityLabel("歌詞延後 0.25 秒")
            VStack(spacing: 1) {
                Text(String(format: "%+.2f 秒", value))
                    .font(.headline.monospacedDigit())
                Text(usePerSong ? "只調「\(model.nowPlaying?.title ?? "")」" : "歌詞提前（全部）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            StepButton(symbol: "plus") { adjust(Self.step) }
                .accessibilityLabel("歌詞提前 0.25 秒")
            if model.nowPlaying != nil {
                Picker("套用範圍", selection: $perSong) {
                    Text("全部").tag(false)
                    Text("這首").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }

    private func adjust(_ delta: TimeInterval) {
        let new = min(Self.range.upperBound, max(Self.range.lowerBound, value + delta))
        if usePerSong {
            model.songOffset = new
        } else {
            model.offset = new
        }
    }
}

private struct StepButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: 動作列

private struct ActionRow: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showPicker: Bool
    @Binding var showFocus: Bool

    private var hasSong: Bool { model.nowPlaying != nil }

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink {
                FullLyricsView()
            } label: {
                ActionLabel(title: "完整歌詞", symbol: "list.bullet")
            }
            .disabled(!model.hasSyncedLyrics)
            .opacity(model.hasSyncedLyrics ? 1 : 0.4)

            Button {
                showFocus = true
            } label: {
                ActionLabel(title: "專注模式", symbol: "car.fill")
            }
            .buttonStyle(.plain)
            .disabled(!hasSong)
            .opacity(hasSong ? 1 : 0.4)

            Button {
                showPicker = true
            } label: {
                ActionLabel(title: "換歌詞", symbol: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .disabled(!hasSong)
            .opacity(hasSong ? 1 : 0.4)
        }
    }
}

// MARK: - 除錯

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var log = DebugLog.shared
    @State private var appGroupOK = false
    @State private var liveActivitiesEnabled = false
    /// 每秒刷新一次（背景音訊、Live Activity 的狀態不是 @Published）
    @State private var now = Date()
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            overviewSection
            versionSection
            systemSection
            backgroundSection
            liveActivitySection
            lyricsSection
            logSection
        }
        .navigationTitle("除錯")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: log.fileURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button("清除") { log.clear() }
            }
        }
        .onAppear { check() }
        .onReceive(refresh) { now = $0 }
    }

    // MARK: 區塊

    private var overviewSection: some View {
        Section("總覽") {
            DiagRow("Spotify", value: model.auth.isLoggedIn ? "已登入" : "未登入",
                    ok: model.auth.isLoggedIn)
            DiagRow("背景音訊", value: model.backgroundKeeper.isRunning ? "執行中" : "停止",
                    ok: model.backgroundKeeper.isRunning || !model.backgroundEnabled)
            DiagRow("Live Activity", value: model.liveActivity.stateDescription,
                    ok: model.liveActivity.isActive || !model.liveActivityEnabled)
            DiagRow("歌詞", value: model.lyricsStatus, ok: model.hasSyncedLyrics)
        }
    }

    private var versionSection: some View {
        Section("版本") {
            LabeledContent("Build", value: BuildInfo.summary)
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
            LabeledContent("Live Activities 權限", value: liveActivitiesEnabled ? "已啟用" : "未啟用")
        }
    }

    private var backgroundSection: some View {
        Section {
            LabeledContent("無聲音訊", value: model.backgroundKeeper.isRunning ? "執行中" : "停止")
            LabeledContent("重啟次數", value: "\(model.backgroundKeeper.restartCount)")
            if let reason = model.backgroundKeeper.lastRestartReason,
               let at = model.backgroundKeeper.lastRestartAt {
                LabeledContent("最近重啟", value: "\(at.formatted(date: .omitted, time: .standard)) \(reason)")
                    .font(.caption)
            }
            LabeledContent("最近輪詢", value: model.lastPollAt.map { "\(Int(now.timeIntervalSince($0))) 秒前" } ?? "—")
            LabeledContent("最長輪詢間隔", value: String(format: "%.1f 秒", model.maxPollGap))
            LabeledContent("回應大小", value: "\(model.lastResponseBytes) bytes")
            LabeledContent("背景定位", value: model.locationKeeper.isUpdating ? "執行中" : "停止")
            LabeledContent("定位權限", value: model.locationKeeper.authorizationDescription)
            LabeledContent("定位更新次數", value: "\(model.locationKeeper.updateCount)")
            if let error = model.locationKeeper.lastError {
                LabeledContent("定位錯誤", value: error).font(.caption)
            }
            if let error = model.lastErrorMessage {
                LabeledContent("最近錯誤", value: error).font(.caption)
            }
            Button("重設輪詢統計") { model.resetPollStats() }
        } header: {
            Text("背景執行")
        } footer: {
            Text("停止播放 10 分鐘後會自動停止背景執行以省電；下次打開 App 會自動恢復。")
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
            LabeledContent("小工具 要求 / 實際", value: "\(model.widgetReloadCount) / \(LyricsTimelineStore.renderCount)")
            if let at = model.lastWidgetReloadAt {
                LabeledContent("小工具最後載入", value: at.formatted(date: .omitted, time: .standard))
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
            Text("Live Activity")
        } footer: {
            Text("iOS 最多讓 Live Activity 持續 8 小時；長途請中途打開 App 一次。")
        }
    }

    private var lyricsSection: some View {
        Section("歌詞") {
            LabeledContent("狀態", value: model.lyricsStatus)
            LabeledContent("來源", value: model.hasManualLyrics ? "手動指定" : "自動搜尋")
            LabeledContent("延遲", value: String(format: "全部 %+.2f 秒 · 這首 %+.2f 秒", model.offset, model.songOffset))
            Button("清除歌詞快取（保留手動指定）") { model.clearLyricsCache() }
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
        liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
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
    }
}
