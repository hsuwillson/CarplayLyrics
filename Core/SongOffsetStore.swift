import Foundation

/// 每首歌各自的歌詞延遲（秒），以 Spotify 曲目 ID 為 key 存在 UserDefaults
struct SongOffsetStore {
    var defaults: UserDefaults = .standard
    private static let key = "songOffsets"

    func offset(for trackID: String) -> TimeInterval {
        (defaults.dictionary(forKey: Self.key)?[trackID] as? Double) ?? 0
    }

    func set(_ value: TimeInterval, for trackID: String) {
        var dict = defaults.dictionary(forKey: Self.key) ?? [:]
        if abs(value) < 0.001 {
            dict.removeValue(forKey: trackID)
        } else {
            dict[trackID] = value
        }
        defaults.set(dict, forKey: Self.key)
    }
}
