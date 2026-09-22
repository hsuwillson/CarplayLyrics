import Foundation

/// App 內的除錯紀錄（顯示在「除錯」頁，並寫入檔案，App 被系統終止後仍保留）。
/// 不要記錄 token 或任何密碼。
@MainActor
@Observable
final class DebugLog {
    static let shared = DebugLog()

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
    }

    private(set) var entries: [Entry] = []

    /// 紀錄檔（Application Support/debug.log），可從除錯頁分享
    @ObservationIgnored let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    private static let maxFileBytes = 200_000
    @ObservationIgnored private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()
    /// 檔案寫入放在背景佇列，不佔主執行緒
    @ObservationIgnored private let writer = LogFileWriter()

    func add(_ message: String) {
        let now = Date()
        entries.append(Entry(date: now, message: message))
        if entries.count > 300 {
            entries.removeFirst(entries.count - 300)
        }
        #if DEBUG
        print("[CarLyrics] \(message)")
        #endif
        writer.append("\(formatter.string(from: now)) \(message)\n", to: fileURL, maxBytes: Self.maxFileBytes)
    }

    func clear() {
        entries.removeAll()
        writer.truncate(fileURL)
    }
}

/// 在序列背景佇列寫紀錄檔；FileHandle 保持開啟，超過上限時只保留後半段
private final class LogFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CarLyrics.DebugLog", qos: .utility)
    private var handle: FileHandle?
    private var size = 0

    func append(_ line: String, to url: URL, maxBytes: Int) {
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            self.openIfNeeded(url)
            if self.size + data.count > maxBytes {
                try? self.handle?.close()
                self.handle = nil
                if let old = try? Data(contentsOf: url) {
                    try? old.suffix(maxBytes / 2).write(to: url)
                }
                self.openIfNeeded(url)
            }
            try? self.handle?.write(contentsOf: data)
            self.size += data.count
        }
    }

    func truncate(_ url: URL) {
        queue.async {
            try? self.handle?.close()
            self.handle = nil
            try? Data().write(to: url)
        }
    }

    private func openIfNeeded(_ url: URL) {
        guard handle == nil else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }
}

/// 已在主執行緒時直接寫入（保持紀錄順序）；其他執行緒才排到主執行緒
func debugLog(_ message: String) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { DebugLog.shared.add(message) }
    } else {
        Task { @MainActor in DebugLog.shared.add(message) }
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
    /// CI 寫入的建置時間（ISO 8601）
    static var buildDate: Date? {
        (Bundle.main.object(forInfoDictionaryKey: "CLBuildDate") as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}
