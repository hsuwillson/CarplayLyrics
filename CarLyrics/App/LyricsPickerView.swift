import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let lrc = UTType(filenameExtension: "lrc") ?? .plainText
}

/// 選擇其他 LRCLIB 結果、自由搜尋、匯入 LRC 檔
struct LyricsPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LRCLIBTrack] = []
    @State private var isLoading = false
    @State private var showImporter = false
    @State private var errorMessage: String?
    /// 從「找不到歌詞」的「匯入 LRC 檔」進來時，直接開檔案選擇器
    private let openImporter: Bool

    init(openImporter: Bool = false) {
        self.openImporter = openImporter
    }

    var body: some View {
        NavigationStack {
            List {
                searchSection
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                resultsSection
            }
            .navigationTitle("選擇歌詞")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
            .task {
                if openImporter { showImporter = true }
                if let np = model.nowPlaying { query = "\(np.title) \(np.primaryArtist)" }
                isLoading = true
                results = await model.lyrics.candidates()
                isLoading = false
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.lrc, .plainText, .text, .data]) { result in
                handleImport(result)
            }
        }
    }

    private var searchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("歌名 歌手", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { search() }
                Button("搜尋") { search() }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            }
            Button {
                showImporter = true
            } label: {
                Label("匯入 LRC 檔", systemImage: "doc.badge.plus")
            }
            if model.lyrics.hasManualLyrics {
                Button(role: .destructive) {
                    model.lyrics.resetManual()
                    dismiss()
                } label: {
                    Label("取消手動指定，改回自動搜尋", systemImage: "arrow.uturn.backward")
                }
            }
        } footer: {
            Text("選擇或匯入的歌詞會記住，下次播這首歌直接使用。")
        }
    }

    private var resultsSection: some View {
        Section {
            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("搜尋中…").foregroundStyle(.secondary)
                }
            } else if results.isEmpty {
                Text("沒有結果，試試只輸入歌名或換個拼法。")
                    .foregroundStyle(.secondary)
            }
            ForEach(results, id: \.id) { track in
                Button {
                    model.useCandidate(track)
                    dismiss()
                } label: {
                    CandidateRow(track: track, songDuration: model.nowPlaying?.duration ?? 0)
                }
            }
        } header: {
            Text(isLoading ? "LRCLIB" : "LRCLIB 結果（\(results.count)）")
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            isLoading = true
            results = await model.lyrics.search(text)
            isLoading = false
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "無法讀取檔案（需要 UTF-8 文字檔）"
                return
            }
            model.importLyrics(text)
            dismiss()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

private struct CandidateRow: View {
    let track: LRCLIBTrack
    let songDuration: TimeInterval

    private var kindText: String {
        if track.hasSynced { return "同步" }
        if track.instrumental == true { return "純音樂" }
        return "未同步"
    }

    private var kindColor: Color {
        track.hasSynced ? Color.green : Color.gray
    }

    private var durationText: String? {
        guard let d = track.duration else { return nil }
        guard songDuration > 0 else { return formatTime(d) }
        let diff = Int(abs(d - songDuration).rounded())
        return diff == 0 ? "\(formatTime(d))（長度相同）" : "\(formatTime(d))（差 \(diff) 秒）"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: track.hasSynced ? "waveform" : "text.alignleft")
                .font(.title3)
                .foregroundStyle(kindColor)
                .frame(width: 28)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.trackName ?? "（無歌名）")
                    .foregroundStyle(Color.primary)
                Text([track.artistName, track.albumName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(kindText)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(kindColor.opacity(0.2), in: Capsule())
                    if let durationText {
                        Text(durationText)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
