import Foundation
import UIKit

/// App Group 裡的小張封面（App 寫入；小工具與 Live Activity 讀取）
enum SharedArtwork {
    static var directory: URL? {
        AppGroup.containerURL?.appendingPathComponent("artwork", isDirectory: true)
    }

    static func url(for file: String) -> URL? {
        directory?.appendingPathComponent(file)
    }

    /// 讀取封面；檔案不存在或太大時回傳 nil（Live Activity 對圖片尺寸有限制）
    static func image(named file: String?) -> UIImage? {
        guard let file, let url = url(for: file),
              let image = UIImage(contentsOfFile: url.path),
              image.size.width <= 160, image.size.height <= 160 else { return nil }
        return image
    }
}
