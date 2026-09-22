import Foundation

/// 純畫面用的唯讀輔助屬性（不改變任何狀態，也不碰網路）
extension AppModel {
    /// 有同步歌詞可以逐句顯示
    var hasSyncedLyrics: Bool { !lines.isEmpty }

    /// 目前句的前一句；沒有就是空字串
    var previousLineText: String {
        guard let i = display.index, i > 0, lines.indices.contains(i - 1) else { return "" }
        return lines[i - 1].text
    }

    /// 目前句；還沒唱到第一句或間奏時顯示 ♪
    var currentLineText: String {
        display.current.isEmpty ? "♪" : display.current
    }

    var nextLineText: String { display.next }

    /// 全域 + 這首歌的延遲總和（秒）
    var totalOffset: TimeInterval { offset + songOffset }

    /// 播放進度 0...1
    var progressFraction: Double {
        guard let np = nowPlaying, np.duration > 0 else { return 0 }
        return min(1, max(0, position / np.duration))
    }

    var isPlaying: Bool { nowPlaying?.isPlaying ?? false }
}
