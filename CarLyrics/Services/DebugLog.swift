import Foundation

/// App 內的除錯紀錄（顯示在「除錯」頁）。不要記錄 token 或任何密碼。
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
    }

    @Published private(set) var entries: [Entry] = []

    func add(_ message: String) {
        entries.append(Entry(date: Date(), message: message))
        if entries.count > 300 {
            entries.removeFirst(entries.count - 300)
        }
        print("[CarLyrics] \(message)")
    }

    func clear() {
        entries.removeAll()
    }
}

func debugLog(_ message: String) {
    Task { @MainActor in
        DebugLog.shared.add(message)
    }
}
