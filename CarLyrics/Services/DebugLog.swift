import Foundation

/// App 內的除錯紀錄（顯示在「除錯」頁，並寫入檔案，App 被系統終止後仍保留）。
/// 不要記錄 token 或任何密碼。
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
    }

    @Published private(set) var entries: [Entry] = []

    /// 紀錄檔（Application Support/debug.log），可從除錯頁分享
    let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    private static let maxFileBytes = 200_000
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    func add(_ message: String) {
        let now = Date()
        entries.append(Entry(date: now, message: message))
        if entries.count > 300 {
            entries.removeFirst(entries.count - 300)
        }
        print("[CarLyrics] \(message)")
        appendToFile("\(formatter.string(from: now)) \(message)\n")
    }

    func clear() {
        entries.removeAll()
        try? Data().write(to: fileURL)
    }

    private func appendToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
            return
        }
        // 超過上限就只保留後半段
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int), size > Self.maxFileBytes,
           let old = try? Data(contentsOf: fileURL) {
            try? old.suffix(Self.maxFileBytes / 2).write(to: fileURL)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}

func debugLog(_ message: String) {
    Task { @MainActor in
        DebugLog.shared.add(message)
    }
}

/// 版本資訊（CI 會把 build number 與 git SHA 寫進 Info.plist）
enum BuildInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
    static var gitSHA: String {
        (Bundle.main.object(forInfoDictionaryKey: "CLGitSHA") as? String).map { String($0.prefix(7)) } ?? "local"
    }
    static var summary: String {
        "\(version) (\(build)) · \(gitSHA)"
    }
}
