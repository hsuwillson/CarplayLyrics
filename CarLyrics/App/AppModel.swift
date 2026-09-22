import Foundation
import SwiftUI

/// 串接 Spotify 輪詢、歌詞查詢與同步引擎
@MainActor
final class AppModel: ObservableObject {
    let auth = SpotifyAuth()
    private lazy var api = SpotifyAPI(auth: auth)
    private let lyricsService = LyricsService()
    private var engine = LyricsSyncEngine()

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plainLyrics: String?
    @Published private(set) var lyricsStatus = "尚未開始"
    @Published private(set) var display = LyricsDisplay.empty
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var statusMessage = ""

    /// 全域歌詞延遲調整（秒）。正值 = 歌詞提前出現
    @Published var offset: TimeInterval {
        didSet { UserDefaults.standard.set(offset, forKey: "lyricsOffset") }
    }

    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var quotaMode = false
    /// 偵測到過期資料時，下一次改用 /me/player
    private var useFullPlayer = false

    init() {
        offset = UserDefaults.standard.double(forKey: "lyricsOffset")
    }

    // MARK: 生命週期

    func start() {
        guard pollTask == nil else { return }
        debugLog("開始輪詢")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.pollOnce()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() {
        guard pollTask != nil else { return }
        debugLog("停止輪詢")
        pollTask?.cancel()
        pollTask = nil
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: 登入

    func login() {
        Task {
            do {
                try await auth.login()
                debugLog("登入成功")
                statusMessage = "登入成功"
            } catch SpotifyAuthError.cancelled {
                debugLog("使用者取消登入")
            } catch {
                debugLog("登入失敗：\(error.localizedDescription)")
                statusMessage = "登入失敗：\(error.localizedDescription)"
            }
        }
    }

    func logout() {
        auth.logout()
        clearPlayback()
        statusMessage = ""
        debugLog("已登出")
    }

    // MARK: 播放控制

    var canControlPlayback: Bool {
        auth.hasScope(AppConfig.controlScope)
    }

    func control(_ command: PlayerCommand) {
        guard canControlPlayback else {
            statusMessage = "請先登出再登入，授權「控制播放」"
            debugLog("缺少 \(AppConfig.controlScope) 權限，需要重新登入")
            return
        }
        Task {
            do {
                try await api.send(command)
                debugLog("播放控制：\(command.rawValue)")
                // 讓 Spotify 有時間切換，再立刻更新一次狀態
                try? await Task.sleep(for: .milliseconds(400))
                _ = await pollOnce()
            } catch {
                statusMessage = error.localizedDescription
                debugLog("播放控制失敗：\(error.localizedDescription)")
            }
        }
    }

    func clearLyricsCache() {
        lyricsService.clearCache()
        debugLog("已清除歌詞快取")
        if let np = nowPlaying { loadLyrics(for: np) }
    }

    // MARK: 輪詢

    /// 執行一次輪詢，回傳下一次輪詢前要等待的秒數
    private func pollOnce() async -> TimeInterval {
        guard auth.isLoggedIn else {
            statusMessage = "請先登入 Spotify"
            return 3
        }
        do {
            let full = useFullPlayer
            useFullPlayer = false
            switch try await api.currentlyPlaying(fullPlayer: full) {
            case .playing(let np, let measuredAt):
                handle(np, measuredAt: measuredAt)
                statusMessage = np.isPlaying ? "播放中" : "已暫停"
                if quotaMode { return 6 }
                if useFullPlayer { return 1 }   // 過期資料 → 盡快用另一個端點確認
                return np.isPlaying ? 2.5 : 5

            case .nothing:
                if nowPlaying != nil { debugLog("Spotify 沒有在播放") }
                clearPlayback()
                statusMessage = "Spotify 沒有在播放"
                return 10

            case .rateLimited(let retryAfter, let quotaExceeded):
                debugLog("HTTP 429，Retry-After \(Int(retryAfter)) 秒\(quotaExceeded ? "（配額用完）" : "")")
                if quotaExceeded {
                    quotaMode = true
                    statusMessage = "Spotify API 配額用完，已降低查詢頻率"
                    return max(retryAfter, 30)
                }
                statusMessage = "請求太頻繁，\(Int(retryAfter)) 秒後重試"
                return max(retryAfter, 1)
            }
        } catch {
            debugLog("輪詢錯誤：\(error.localizedDescription)")
            statusMessage = "錯誤：\(error.localizedDescription)"
            return 5
        }
    }

    private func handle(_ np: NowPlaying, measuredAt: Date) {
        nowPlaying = np
        let snapshot = PlaybackSnapshot(trackID: np.trackID, progress: np.progress, duration: np.duration,
                                        isPlaying: np.isPlaying, timestamp: measuredAt)
        switch engine.update(snapshot) {
        case .newTrack:
            debugLog("換歌：\(np.title) – \(np.artist)")
            loadLyrics(for: np)
        case .seeked:
            debugLog("偵測到拖動進度 → \(formatTime(np.progress))")
        case .playStateChanged:
            debugLog(np.isPlaying ? "繼續播放" : "暫停")
        case .stale:
            debugLog("Spotify 進度沒有前進（\(formatTime(np.progress))），忽略並改用 /me/player 重試")
            useFullPlayer = true
        case .none:
            break
        }
        tick()
    }

    private func clearPlayback() {
        nowPlaying = nil
        engine.reset()
        lyricsTask?.cancel()
        lines = []
        plainLyrics = nil
        display = .empty
        position = 0
        lyricsStatus = "沒有播放中的歌曲"
    }

    // MARK: 歌詞

    private func loadLyrics(for np: NowPlaying) {
        lyricsTask?.cancel()
        lines = []
        plainLyrics = nil
        display = .empty
        lyricsStatus = "搜尋歌詞中…"

        let query = TrackQuery(trackID: np.trackID, title: np.title, artist: np.primaryArtist,
                               album: np.album, duration: np.duration)
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.lyricsService.lyrics(for: query)
            guard !Task.isCancelled, self.nowPlaying?.trackID == np.trackID else { return }
            switch result {
            case .synced(let lrc):
                self.lines = LRCParser.parse(lrc)
                self.lyricsStatus = "同步歌詞（\(self.lines.count) 行）"
            case .plain(let text):
                self.plainLyrics = text
                self.lyricsStatus = "只有未同步歌詞"
            case .instrumental:
                self.lyricsStatus = "純音樂"
            case .notFound:
                self.lyricsStatus = "找不到歌詞"
            case .failed(let message):
                self.lyricsStatus = "歌詞載入失敗：\(message)"
            }
            debugLog("歌詞：\(self.lyricsStatus)")
            self.tick()
        }
    }

    /// 以本地時鐘推算目前位置，更新畫面上的目前句 / 下一句
    private func tick() {
        guard let pos = engine.position(at: Date()) else { return }
        position = pos
        let d = LyricsDisplay(lines: lines, position: pos + offset)
        if d != display { display = d }
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return String(format: "%d:%02d", s / 60, s % 60)
}
