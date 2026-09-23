import Foundation

/// 目前這首歌的歌詞：自動搜尋、手動指定 / 匯入、預先載入播放佇列
@MainActor
@Observable
final class LyricsController {
    private(set) var state: LyricsState = .idle
    private(set) var hasManualLyrics = false

    @ObservationIgnored private let provider: LyricsProviding
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    /// 本次執行已預先載入過的曲目 ID（任何結果都算，包括失敗），不再重查
    @ObservationIgnored private var attempted = Set<String>()
    /// 同上，以「歌名|歌手|秒數」記：Spotify 把同一首歌換成別的版本 ID（relinking）也認得
    @ObservationIgnored private var attemptedKeys = Set<String>()
    /// 上次的播放佇列（第一首是下一首）與它接在哪首歌後面；換到下一首時直接沿用，不必再問 Spotify
    @ObservationIgnored private var rememberedQueue: [NowPlaying] = []
    @ObservationIgnored private var rememberedFor: String?
    @ObservationIgnored private var hasLoggedPrefetch = false
    @ObservationIgnored private(set) var query: TrackQuery?
    /// 歌詞狀態改變後通知 AppModel（重算目前句、推送即時動態 / 小工具）
    @ObservationIgnored var onChange: (() -> Void)?

    init(provider: LyricsProviding) {
        self.provider = provider
    }

    static func query(for np: NowPlaying) -> TrackQuery {
        TrackQuery(trackID: np.trackID, title: np.title, artist: np.primaryArtist,
                   album: np.album, duration: np.duration)
    }

    /// 換歌：清空舊歌詞並開始搜尋
    func load(for np: NowPlaying) {
        cancel()
        let q = Self.query(for: np)
        query = q
        set(.searching)
        task = Task { [weak self, provider] in
            let manual = await provider.hasOverride(q.trackID)
            let result = await provider.lyrics(for: q)
            guard let self, !Task.isCancelled, self.query?.trackID == q.trackID else { return }
            self.hasManualLyrics = manual
            guard let result else { return }
            self.apply(result)
        }
    }

    func retry() {
        guard let q = query else { return }
        cancel()
        set(.searching)
        task = Task { [weak self, provider] in
            let result = await provider.lyrics(for: q)
            guard let self, !Task.isCancelled, self.query?.trackID == q.trackID, let result else { return }
            self.apply(result)
        }
    }

    /// 沒有播放中的歌曲
    func reset() {
        cancel()
        prefetchTask?.cancel()
        rememberedQueue = []
        rememberedFor = nil
        query = nil
        hasManualLyrics = false
        set(.idle)
    }

    // MARK: 手動選擇 / 匯入

    func candidates() async -> [LRCLIBTrack] {
        guard let q = query else { return [] }
        return await provider.candidates(for: q)
    }

    func search(_ text: String) async -> [LRCLIBTrack] {
        await provider.search(text: text, duration: query?.duration ?? 0)
    }

    func use(_ track: LRCLIBTrack) {
        guard let q = query, let result = LyricsResult(track: track) else { return }
        // 停止進行中的自動搜尋，避免之後覆蓋使用者的選擇
        cancel()
        Task { await provider.setOverride(result, trackID: q.trackID) }
        hasManualLyrics = true
        debugLog("手動選擇 LRCLIB #\(track.id)")
        apply(result)
    }

    /// 匯入 LRC（或純文字）檔，綁定到目前這首歌
    func importText(_ text: String) {
        guard let q = query else { return }
        cancel()
        let result: LyricsResult = LRCParser.parse(text).isEmpty ? .plain(text) : .synced(text)
        Task { await provider.setOverride(result, trackID: q.trackID) }
        hasManualLyrics = true
        debugLog("已匯入歌詞檔（\(result.shortDescription)）")
        apply(result)
    }

    /// 取消手動指定，改回自動搜尋
    func resetManual() {
        guard let q = query else { return }
        cancel()
        hasManualLyrics = false
        set(.searching)
        debugLog("已取消手動指定的歌詞")
        task = Task { [weak self, provider] in
            await provider.removeOverride(q.trackID)
            let result = await provider.lyrics(for: q)
            guard let self, !Task.isCancelled, self.query?.trackID == q.trackID, let result else { return }
            self.apply(result)
        }
    }

    func clearCache() {
        // 快取清掉了，佇列裡的歌要重新預先載入
        attempted.removeAll()
        attemptedKeys.removeAll()
        Task { [weak self, provider] in
            await provider.clearCache()
            debugLog("已清除歌詞快取（手動指定的歌詞保留）")
            self?.retry()
        }
    }

    // MARK: 預先載入

    /// 預先載入播放佇列的歌詞。
    /// - 本次執行已處理過的歌（包括失敗）與目前這首不再處理
    /// - 已有快取的只檢查檔案、不解碼、不等待、不逐首記錄；最近失敗過的先略過（6 小時）
    /// - 只有真的連網查詢時，兩首之間才稍等一下
    /// - Parameters:
    ///   - queue: 回傳播放佇列（第一首是下一首）；換到記住的佇列裡的下一首時沿用，不必每次都問 Spotify
    ///   - wholeQueue: true（Wi-Fi、非低耗電）時整個佇列都先載入，隧道 / 地下停車場也有歌詞
    func prefetch(wholeQueue: Bool, queue fetchQueue: @escaping @Sendable () async -> [NowPlaying]) {
        prefetchTask?.cancel()
        guard let current = query else { return }
        let reused = reuseQueue(for: current)
        prefetchTask = Task { [weak self, provider] in
            var list: [NowPlaying]
            if let reused {
                list = reused
            } else {
                list = await fetchQueue()
                guard !Task.isCancelled else { return }
                // Spotify 的佇列偶爾還沒更新，第一首仍是目前這首
                if let first = list.first, LyricsController.isSame(first, current) { list.removeFirst() }
                self?.rememberedQueue = list
                self?.rememberedFor = current.trackID
            }
            guard let self else { return }

            let targets = self.pending(wholeQueue ? Array(list.prefix(20)) : Array(list.prefix(1)), current: current)
            var stats = PrefetchStats()
            var stopped = false
            for q in targets {
                if Task.isCancelled { stopped = true; break }
                switch await provider.prefetchCheck(q.trackID) {
                case .cached:
                    stats.cached += 1
                    self.markAttempted(q)
                    continue
                case .recentlyFailed:
                    stats.recentlyFailed += 1
                    self.markAttempted(q)
                    continue
                case .needed:
                    break
                }
                // 對 LRCLIB 客氣一點：兩次連網查詢之間稍等
                if stats.lookedUp > 0 { try? await Task.sleep(for: .milliseconds(800)) }
                // nil = 查到一半被取消：不記為已處理（下次再查），這一輪也不再重試
                guard !Task.isCancelled, let result = await provider.lyrics(for: q) else { stopped = true; break }
                self.markAttempted(q)
                stats.add(result)
            }
            if stats.lookedUp > 0 || !self.hasLoggedPrefetch {
                self.hasLoggedPrefetch = true
                let label = wholeQueue ? "預先載入播放佇列" : "預先載入下一首「\(list.first?.title ?? "")」"
                debugLog(stats.summary(label: label, stopped: stopped))
            }
        }
    }

    /// 換到記住的佇列裡的歌（通常是第一首）時，去掉它之前的部分沿用；
    /// 找不到目前這首、或剩不到 3 首時回傳 nil，改問 Spotify
    private func reuseQueue(for current: TrackQuery) -> [NowPlaying]? {
        if rememberedFor != current.trackID {
            guard let i = rememberedQueue.prefix(3).firstIndex(where: { Self.isSame($0, current) }) else { return nil }
            rememberedQueue.removeFirst(i + 1)
            rememberedFor = current.trackID
        }
        return rememberedQueue.count >= 3 ? rememberedQueue : nil
    }

    /// 還沒處理過、不是目前這首、不重複的佇列項目
    private func pending(_ tracks: [NowPlaying], current: TrackQuery) -> [TrackQuery] {
        let currentKey = Self.key(current)
        var seen = Set<String>()
        var result: [TrackQuery] = []
        for track in tracks {
            let q = Self.query(for: track)
            let key = Self.key(q)
            guard q.trackID != current.trackID, key != currentKey,
                  !attempted.contains(q.trackID), !attemptedKeys.contains(key),
                  seen.insert(key).inserted else { continue }
            result.append(q)
        }
        return result
    }

    private func markAttempted(_ q: TrackQuery) {
        attempted.insert(q.trackID)
        attemptedKeys.insert(Self.key(q))
    }

    /// 「歌名|歌手|秒數」：辨認同一首歌的不同 Spotify ID
    static func key(_ q: TrackQuery) -> String {
        "\(q.title.lowercased())|\(q.artist.lowercased())|\(Int(q.duration.rounded()))"
    }

    static func isSame(_ track: NowPlaying, _ q: TrackQuery) -> Bool {
        track.trackID == q.trackID || key(query(for: track)) == key(q)
    }

    /// 一輪預先載入的統計（只記一行摘要）
    private struct PrefetchStats {
        var synced = 0, plain = 0, instrumental = 0, notFound = 0, failed = 0
        var cached = 0, recentlyFailed = 0

        var lookedUp: Int { synced + plain + instrumental + notFound + failed }

        mutating func add(_ result: LyricsResult) {
            switch result {
            case .synced: synced += 1
            case .plain: plain += 1
            case .instrumental: instrumental += 1
            case .notFound: notFound += 1
            case .failed: failed += 1
            }
        }

        func summary(label: String, stopped: Bool) -> String {
            var s = "\(label)：新查 \(lookedUp) 首（同步 \(synced)、未同步 \(plain)、找不到 \(notFound)、失敗 \(failed)"
            if instrumental > 0 { s += "、純音樂 \(instrumental)" }
            s += "），已有快取 \(cached) 首"
            if recentlyFailed > 0 { s += "，最近失敗略過 \(recentlyFailed) 首" }
            if stopped { s += "（中途停止）" }
            return s
        }
    }

    // MARK: 內部

    private func cancel() {
        task?.cancel()
        task = nil
    }

    private func apply(_ result: LyricsResult) {
        let new = LyricsState(result)
        if case .failed = new { debugLog("歌詞載入失敗") }
        set(new)
        debugLog("歌詞：\(new.label)")
    }

    private func set(_ new: LyricsState) {
        guard new != state else { return }
        state = new
        onChange?()
    }
}
