import Foundation
import ImageIO
import UIKit

/// 下載小張專輯封面，縮成 96 px 存進 App Group，給小工具與即時動態使用。
/// 只保留最近 20 張；封面來自 Spotify 提供的網址，不另外保存到任何地方。
actor ArtworkStore {
    private let maxFiles = 20
    private let pixelSize: CGFloat = 96
    private var inFlight: [String: Task<String?, Never>] = [:]

    static func fileName(for trackID: String) -> String {
        "\(trackID.replacingOccurrences(of: "/", with: "_")).jpg"
    }

    /// 回傳 App Group 內的檔名；失敗時 nil
    func prepare(trackID: String, url: URL?) async -> String? {
        let name = Self.fileName(for: trackID)
        guard let dir = SharedArtwork.directory else { return nil }
        let fileURL = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: fileURL.path) { return name }
        guard let url else { return nil }
        if let running = inFlight[trackID] { return await running.value }

        let maxPixel = pixelSize
        let task = Task<String?, Never> {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let jpeg = Self.downsample(data, maxPixel: maxPixel) else { return nil }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try jpeg.write(to: fileURL, options: .atomic)
                return name
            } catch {
                return nil
            }
        }
        inFlight[trackID] = task
        let result = await task.value
        inFlight[trackID] = nil
        prune(dir)
        return result
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }

    private func prune(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > maxFiles else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(maxFiles) { try? fm.removeItem(at: old) }
    }
}
