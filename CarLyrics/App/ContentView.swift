import ActivityKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    AccountBar(auth: model.auth)
                    NowPlayingCard()
                    LyricsCard()
                    OffsetCard()
                }
                .padding()
            }
            .navigationTitle("CarLyrics")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Image(systemName: "ladybug")
                    }
                }
            }
        }
        .task { model.start() }
    }
}

private struct AccountBar: View {
    @ObservedObject var auth: SpotifyAuth
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(auth.isLoggedIn ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(auth.isLoggedIn ? model.statusMessage : "尚未登入 Spotify")
                .font(.subheadline)
                .lineLimit(2)
            Spacer()
            if auth.isLoggedIn {
                Button("登出", role: .destructive) { model.logout() }
                    .font(.subheadline)
            } else {
                Button("登入 Spotify") { model.login() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct NowPlayingCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let np = model.nowPlaying {
                Text(np.title)
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(np.album.isEmpty ? np.artist : "\(np.artist) · \(np.album)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: min(model.position, np.duration), total: max(np.duration, 1))
                HStack {
                    Text(formatTime(model.position))
                    Spacer()
                    Text(formatTime(np.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                HStack(spacing: 44) {
                    Button { model.control(.previous) } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button { model.control(np.isPlaying ? .pause : .play) } label: {
                        Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 34))
                    }
                    Button { model.control(.next) } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .font(.system(size: 26))
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

                if !model.canControlPlayback {
                    Text("要使用播放按鈕，請先登出再重新登入 Spotify")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text("沒有正在播放的歌曲")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct LyricsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            if !model.lines.isEmpty {
                Text(model.display.current.isEmpty ? "♪" : model.display.current)
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .animation(.easeInOut(duration: 0.2), value: model.display.index)
                Text(model.display.next)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            } else if let plain = model.plainLyrics {
                Text("（這首歌只有未同步歌詞）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(model.lyricsStatus)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
            }
            Text(model.lyricsStatus)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct OffsetCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: $model.offset, in: -5...5, step: 0.25) {
                Text("歌詞提前 \(model.offset, specifier: "%+.2f") 秒")
                    .monospacedDigit()
            }
            Text("歌詞比聲音慢就調大，比聲音快就調小")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var log = DebugLog.shared
    @State private var appGroupOK = false
    @State private var liveActivitiesEnabled = false

    var body: some View {
        List {
            Section("系統") {
                LabeledContent("App Group", value: appGroupOK ? "OK" : "失敗")
                LabeledContent("Group ID") {
                    Text(AppGroup.identifier).font(.caption2)
                }
                LabeledContent("Live Activities", value: liveActivitiesEnabled ? "已啟用" : "未啟用")
                LabeledContent("Client ID", value: AppConfig.spotifyClientID.isEmpty ? "尚未設定" : "已設定")
                Button("清除歌詞快取") { model.clearLyricsCache() }
            }
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
        .navigationTitle("除錯")
        .toolbar {
            Button("清除紀錄") { log.clear() }
        }
        .onAppear(perform: check)
    }

    private func check() {
        if let d = AppGroup.defaults {
            d.set(Date().timeIntervalSince1970, forKey: "skeletonCheck")
            appGroupOK = d.double(forKey: "skeletonCheck") > 0 && AppGroup.containerURL != nil
        }
        liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    }
}
