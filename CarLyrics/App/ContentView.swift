import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            MainScreen()
        }
        .task { model.start() }
    }
}

// MARK: - 主畫面

/// 主畫面：光暈背景 + 狀態列 + 提示橫幅 + 正在播放 + 歌詞舞台 + 延遲調整 + 動作列
private struct MainScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false
    @State private var picker: PickerRequest?
    @State private var showFocus = false
    @State private var showSetup = false

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
                        .overlay(alignment: .topTrailing) {
                            if model.setupNeedsAttention && model.auth.isLoggedIn {
                                Circle()
                                    .fill(Theme.Semantic.attention)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 3, y: -3)
                            }
                        }
                }
                .accessibilityLabel(model.setupNeedsAttention ? "設定（有項目需要處理）" : "設定")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $picker) { request in
            LyricsPickerView(openImporter: request.openImporter)
        }
        .sheet(isPresented: $showSetup, onDismiss: { model.hasSeenSetup = true }) {
            NavigationStack { SetupChecklistView(isOnboarding: true) }
        }
        .fullScreenCover(isPresented: $showFocus) {
            FocusLyricsView()
        }
        .onAppear {
            if !model.hasSeenSetup { showSetup = true }
        }
        // initial: true → 冷啟動時（控制中心 / 捷徑先於畫面）也看得到
        .onChange(of: model.requestedScreen, initial: true) { _, screen in
            guard let screen else { return }
            model.consumeRequestedScreen()
            guard screen == .focus, model.auth.isLoggedIn else { return }
            // 同時只能呈現一個 modal：先關掉其他 sheet 再開專注模式
            showSettings = false
            showSetup = false
            picker = nil
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                showFocus = true
            }
        }
        .onOpenURL { url in
            // carlyrics://focus（即時動態、小工具點一下）
            if url.host == "focus" { model.request(screen: .focus) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.auth.isLoggedIn {
            // 小螢幕（iPhone SE）或字體調大時放不下 → 改成可捲動，底部按鈕不會被擠出畫面
            ViewThatFits(in: .vertical) {
                mainLayout
                ScrollView {
                    mainLayout
                }
                .scrollIndicators(.hidden)
            }
        } else {
            WelcomeView()
        }
    }

    private var mainLayout: some View {
        VStack(spacing: Theme.Spacing.l) {
            ConnectionStatusBar()
            if let notice = model.notice {
                NoticeBanner(notice: notice) { model.perform($0) }
            }
            LiveActivityHint()
            DrivingModeHint()
            NowPlayingHero()
            LyricsStage(openPicker: { picker = PickerRequest(openImporter: $0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                // 只限制歌詞舞台的字級，按鈕仍跟隨系統文字大小
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            OffsetControl()
            ActionRow(openPicker: { picker = PickerRequest(openImporter: false) }, showFocus: $showFocus)
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.m)
        .animation(Theme.Motion.snappy, value: model.notice)
        // 選擇 / 匯入歌詞成功：輕輕震一下
        .sensoryFeedback(.success, trigger: model.lyricsChosenCount)
    }
}

/// 開「選擇歌詞」時是否直接跳出檔案選擇器
private struct PickerRequest: Identifiable {
    let id = UUID()
    let openImporter: Bool
}

// MARK: - 尚未登入

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xxl) {
                Spacer(minLength: Theme.Spacing.xxl)
                VStack(spacing: Theme.Spacing.l) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                        .background(Theme.brand.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: Theme.brand.opacity(0.35), radius: 16, y: 8)
                        .accessibilityHidden(true)
                    VStack(spacing: Theme.Spacing.s) {
                        Text("CarLyrics")
                            .font(.largeTitle.bold())
                        Text("開車時，把 Spotify 正在唱的那一句\n放到 CarPlay 與鎖定畫面上。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    FeatureRow(symbol: "car.fill", title: "CarPlay 儀表板",
                               detail: "目前句 + 接下來兩句，一眼就看到")
                    FeatureRow(symbol: "lock.iphone", title: "鎖定畫面",
                               detail: "不用解鎖，歌詞自己換句")
                    FeatureRow(symbol: "moon.fill", title: "專注模式",
                               detail: "放在車架上：純黑背景、超大字")
                }
                .padding(Theme.Spacing.l)
                .background(.fill.quaternary, in: Theme.cardShape())
                if let error = model.pollError {
                    Text("\(error.title)：\(error.message)")
                        .font(.footnote)
                        .foregroundStyle(Theme.Semantic.attention)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: Theme.Spacing.m) {
                    Button {
                        model.login()
                    } label: {
                        Group {
                            if model.isLoggingIn {
                                Label { Text("登入中…") } icon: { ProgressView() }
                            } else {
                                Label("登入 Spotify", systemImage: "person.crop.circle")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.brand)
                    .controlSize(.large)
                    .disabled(model.isLoggingIn)
                    Text("需要 Spotify Premium。登入資訊只存在這支 iPhone 的鑰匙圈，不會傳到其他地方。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 狀態列

/// 最上面一行：連線狀態籤（左）+ 歌詞狀態（右）
private struct ConnectionStatusBar: View {
    @Environment(AppModel.self) private var model

    private var dotColor: Color {
        if !model.isOnline { return Theme.Semantic.offline }
        switch model.session {
        case .playing: return Theme.Semantic.playing
        case .paused, .nonMusic: return Theme.Semantic.paused
        default: return Theme.Semantic.idle
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            StatusChip(color: dotColor, text: model.isOnline ? model.session.label : "離線")
                .layoutPriority(1)
            Spacer(minLength: Theme.Spacing.s)
            if model.nowPlaying != nil {
                Text(model.lyrics.state.label)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 鎖定畫面 / CarPlay 歌詞（即時動態）現在為什麼沒有顯示，以及手動開始的按鈕：
/// -「開車時」模式在家：說明連上 CarPlay 後才會顯示；車子沒被認出來時可以手動開始
/// - 其他情況播歌中卻沒有即時動態（背景開始失敗、系統沒允許）：一鍵補開
private struct LiveActivityHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.auth.isLoggedIn, model.liveActivityMode != .off, model.nowPlaying != nil, !model.session.isNonMusic {
            // liveActivity 不是 @Observable：每 2 秒看一次即時動態有沒有開始，開始了這一列就消失
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                row
            }
        }
    }

    @ViewBuilder
    private var row: some View {
        if !model.liveActivity.isActive {
            InlineHint(symbol: "lock.iphone", text: message, lineLimit: 2) {
                if model.activitiesEnabled {
                    Button("現在顯示") { model.startLiveActivityNow() }
                        .accessibilityLabel("現在顯示鎖定畫面歌詞")
                } else {
                    Button("開啟設定") { model.perform(.openSettings) }
                        .accessibilityLabel("開啟系統設定允許即時動態")
                }
            }
        }
    }

    private var message: String {
        if !model.activitiesEnabled { return "鎖定畫面歌詞：系統未允許即時動態" }
        if model.liveActivityMode == .whileDriving, !model.isCarConnected {
            return "鎖定畫面歌詞：連上 CarPlay 後顯示"
        }
        return "鎖定畫面歌詞：尚未開始"
    }
}

/// 開車模式：接著 CarPlay 時提醒「留在螢幕上」——iOS 會擋掉背景送出的即時動態更新，
/// CarLyrics 不在螢幕上時 CarPlay 歌詞就會停住（只剩小工具頁會照時間軸動）
private struct DrivingModeHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.auth.isLoggedIn, let hint = model.drivingHint {
            InlineHint(symbol: model.isDrivingModeActive ? "car.fill" : "exclamationmark.triangle.fill",
                       tint: model.isDrivingModeActive ? Theme.Semantic.playing : Theme.Semantic.attention,
                       text: hint)
        }
    }
}

// MARK: - 正在播放

private struct NowPlayingHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            // 廣告 / Podcast 時不顯示上一首歌的資訊（IdleHero 會顯示「廣告播放中」）
            if let np = model.nowPlaying, !model.session.isNonMusic {
                HStack(spacing: Theme.Spacing.l) {
                    ArtworkView(url: np.artworkURL, size: Theme.Size.artworkHero)
                    TrackTitle(title: np.title, artist: np.artist, album: np.album)
                }
                ProgressStrip(duration: np.duration, isPlaying: np.isPlaying)
                TransportControls(isPlaying: np.isPlaying)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title2.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text(artist)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !album.isEmpty {
                Text(album)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 進度條：播放中每 0.5 秒用本地時鐘平滑推進（不觸發其他畫面重繪）
private struct ProgressStrip: View {
    @Environment(AppModel.self) private var model
    let duration: TimeInterval
    let isPlaying: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: isPlaying ? 0.5 : 60)) { _ in
            let position = min(model.livePosition(), duration)
            VStack(spacing: Theme.Spacing.xs) {
                ProgressView(value: position, total: max(duration, 1))
                    .tint(Color.primary)
                HStack {
                    Text(formatTime(position))
                    Spacer()
                    Text("-" + formatTime(max(0, duration - position)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("播放進度")
            .accessibilityValue("\(formatTime(position))，共 \(formatTime(duration))")
        }
    }
}

private struct TransportControls: View {
    @Environment(AppModel.self) private var model
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.xxl) {
            TransportButton(symbol: "backward.fill") { model.previousOrRestart() }
                .accessibilityLabel("上一首")
            PlayPauseButton(isPlaying: isPlaying) {
                model.control(isPlaying ? .pause : .play)
            }
            TransportButton(symbol: "forward.fill") { model.control(.next) }
                .accessibilityLabel("下一首")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.controlSuccessCount)
        .sensoryFeedback(.error, trigger: model.controlFailureCount)
        .opacity(model.canControlPlayback ? 1 : Theme.Opacity.dimmed)
    }
}

private struct IdleHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            switch model.session {
            case .connecting:
                ProgressView()
                    .controlSize(.regular)
                Text("連接 Spotify 中…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .nonMusic(let kind):
                Text(kind.label)
                    .font(Theme.Font.emptyTitle)
                Text("歌曲開始後會自動顯示歌詞")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            default:
                Text("沒有正在播放的歌曲")
                    .font(Theme.Font.emptyTitle)
                Text("在 Spotify 開始播放後會自動出現")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - 歌詞舞台

private struct LyricsStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// 開啟「選擇歌詞」（參數：是否直接匯入檔案）
    let openPicker: (Bool) -> Void

    var body: some View {
        Group {
            if model.session.isNonMusic {
                EmptyStateView(symbol: "megaphone", title: "廣告 / Podcast 沒有歌詞", message: "結束後會自動接上")
            } else if model.nowPlaying == nil {
                EmptyStateView(symbol: "music.note", title: "在 Spotify 播歌", message: "歌詞會自動出現") {
                    Button {
                        if let url = URL(string: "spotify:") { openURL(url) }
                    } label: {
                        Label("打開 Spotify", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.glass)
                }
            } else {
                switch model.lyrics.state {
                case .synced:
                    SyncedLyricsStage()
                case .plain(let text):
                    PlainLyricsStage(text: text)
                case .searching, .idle:
                    VStack(spacing: Theme.Spacing.m) {
                        ProgressView()
                        Text("正在找《\(model.nowPlaying?.title ?? "")》的歌詞…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity)
                case .notFound:
                    EmptyStateView(symbol: "text.magnifyingglass", title: "找不到這首歌的歌詞",
                                   message: "可以搜尋其他版本，或匯入自己的 LRC 檔") {
                        HStack(spacing: Theme.Spacing.s) {
                            Button("搜尋其他版本") { openPicker(false) }
                            Button("匯入 LRC 檔") { openPicker(true) }
                        }
                        .buttonStyle(.glass)
                    }
                case .failed(let error):
                    EmptyStateView(symbol: "exclamationmark.icloud", title: error.title, message: error.message) {
                        Button("重試") { model.lyrics.retry() }
                            .buttonStyle(.glass)
                    }
                case .instrumental:
                    EmptyStateView(symbol: "music.quarternote.3", title: "純音樂", message: "這首歌沒有歌詞")
                }
            }
        }
        .animation(Theme.Motion.standard, value: model.lyrics.state.label)
    }
}

/// 卡拉 OK 式三句：上一句（淡）、目前句（大字）、下一句（次要）
private struct SyncedLyricsStage: View {
    @Environment(AppModel.self) private var model

    private var previousLine: String {
        guard let i = model.lyricsDisplay.index, i > 0, model.syncedLines.indices.contains(i - 1) else { return " " }
        return model.syncedLines[i - 1].text
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer(minLength: 0)
            Text(previousLine)
                .font(Theme.Font.lyricContext)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .accessibilityHidden(true)
            AnimatedCurrentLine(
                text: model.lyricsDisplay.current.isEmpty ? "♪" : model.lyricsDisplay.current,
                index: model.lyricsDisplay.index,
                font: Theme.Font.lyricHero,
                lineSpacing: 6)
            Text(model.lyricsDisplay.next.isEmpty ? " " : model.lyricsDisplay.next)
                .font(Theme.Font.lyricContext)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityLabel("下一句：\(model.lyricsDisplay.next)")
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

private struct PlainLyricsStage: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label("只有未同步歌詞：無法逐句顯示，也不能調整歌詞提前", systemImage: "text.alignleft")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.title3)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(Theme.Spacing.l)
        .background(.fill.quaternary, in: Theme.cardShape())
    }
}

// MARK: - 延遲調整（精簡版；完整版在設定）

private struct OffsetControl: View {
    @Environment(AppModel.self) private var model
    @State private var perSong = false
    @State private var hitLimit = 0

    private static let step: TimeInterval = 0.25
    private static let range: ClosedRange<TimeInterval> = -5...5

    private var usePerSong: Bool { perSong && model.nowPlaying != nil }
    private var value: TimeInterval { usePerSong ? model.trackOffset : model.globalOffset }
    private var isDisabled: Bool { model.nowPlaying != nil && !model.hasSyncedLyrics }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            StepButton(symbol: "minus") { adjust(-Self.step) }
                .accessibilityLabel("歌詞延後 0.25 秒")
            VStack(spacing: 1) {
                Text(String(format: "%+.2f 秒", value))
                    .font(.headline.monospacedDigit())
                    .contentTransition(.numericText(value: value))
                    .animation(Theme.Motion.snappy, value: value)
                Text(usePerSong ? "只調「\(model.nowPlaying?.title ?? "")」" : "歌詞提前（全部）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(usePerSong ? "這首歌的歌詞提前" : "所有歌曲的歌詞提前")
            .accessibilityValue(String(format: "%+.2f 秒", value))
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
        .glassEffect(.regular, in: Capsule())
        .disabled(isDisabled)
        .opacity(isDisabled ? Theme.Opacity.dimmed : 1)
        .sensoryFeedback(.selection, trigger: value)
        .sensoryFeedback(.warning, trigger: hitLimit)
    }

    private func adjust(_ delta: TimeInterval) {
        let raw = value + delta
        let new = min(Self.range.upperBound, max(Self.range.lowerBound, raw))
        if new != raw { hitLimit += 1 }
        guard new != value else { return }
        if usePerSong {
            model.trackOffset = new
        } else {
            model.globalOffset = new
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
                .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 動作列

private struct ActionRow: View {
    @Environment(AppModel.self) private var model
    let openPicker: () -> Void
    @Binding var showFocus: Bool

    private var hasSong: Bool { model.nowPlaying != nil }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                NavigationLink {
                    FullLyricsView()
                } label: {
                    ActionLabel(title: "完整歌詞", symbol: "list.bullet")
                }
                .buttonStyle(.plain)
                .disabled(!model.hasSyncedLyrics)
                .opacity(model.hasSyncedLyrics ? 1 : Theme.Opacity.disabled)

                Button {
                    showFocus = true
                } label: {
                    ActionLabel(title: "專注模式", symbol: "car.fill")
                }
                .buttonStyle(.plain)
                .disabled(!hasSong)
                .opacity(hasSong ? 1 : Theme.Opacity.disabled)

                Button(action: openPicker) {
                    ActionLabel(title: "選擇歌詞", symbol: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .disabled(!hasSong)
                .opacity(hasSong ? 1 : Theme.Opacity.disabled)
            }
        }
    }
}
