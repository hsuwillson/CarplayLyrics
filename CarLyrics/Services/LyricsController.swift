import Foundation

/// 目前這首歌的歌詞：自動搜尋、手動指定 / 匯入、預先載入下一首
@MainActor
@Observable
final class LyricsController {
    private(set) var state: LyricsState = .idle
    private(set) var hasManualLyrics = false

    @ObservationIgnored private let provider: LyricsProviding
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    /// 已經預載過的佇列指紋（前三首的 ID）
    @ObservationIgnored private var prefetchedFingerprint: String?
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
        Task { [weak self, provider] in
            await provider.clearCache()
            debugLog("已清除歌詞快取（手動指定的歌詞保留）")
            self?.retry()
        }
    }

    // MARK: 預先載入

    /// 預先載入播放佇列的歌詞。
    /// - Parameters:
    ///   - queue: 回傳播放佇列（第一首是下一首）
    ///   - wholeQueue: true（Wi-Fi、非低耗電）時整個佇列都先載入，隧道 / 地下停車場也有歌詞
    func prefetch(wholeQueue: Bool, queue fetchQueue: @escaping @Sendable () async -> [NowPlaying]) {
        prefetchTask?.cancel()
        let currentID = query?.trackID
        let already = prefetchedFingerprint
        prefetchTask = Task { [weak self, provider] in
            let list = await fetchQueue()
            guard !Task.isCancelled, let next = list.first, next.trackID != currentID else { return }
            let fingerprint = list.prefix(3).map(\.trackID).joined(separator: "-")
            guard fingerprint != already else { return }
            self?.prefetchedFingerprint = fingerprint

            let targets = wholeQueue ? Array(list.prefix(20)) : [next]
            var loaded = 0
            for track in targets {
                guard !Task.isCancelled else { return }
                let result = await provider.lyrics(for: LyricsController.query(for: track))
                if result != nil { loaded += 1 }
                if track.trackID == next.trackID, let result {
                    debugLog("預先載入下一首：\(next.title)（\(result.shortDescription)）")
                }
                // 對 LRCLIB 客氣一點
                if targets.count > 1 { try? await Task.sleep(for: .seconds(1)) }
            }
            if targets.count > 1 {
                debugLog("已預先載入播放佇列 \(loaded)/\(targets.count) 首的歌詞")
            }
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
