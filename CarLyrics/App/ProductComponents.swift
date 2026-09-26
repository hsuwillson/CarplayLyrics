import SwiftUI

extension View {
    func productCard() -> some View {
        self.background(Color(uiColor: .secondarySystemGroupedBackground), in: Theme.cardShape())
            .overlay { Theme.cardShape().strokeBorder(.primary.opacity(0.07), lineWidth: 1) }
    }
}

/// 狀態來自音訊路由與 ActivityKit，不把連上車或送出更新誤標為「同步成功」。
struct CarPlayConnectionCard: View {
    @Environment(AppModel.self) private var model
    let openSetup: () -> Void

    var body: some View {
        Button(action: openSetup) {
            HStack(alignment: .center, spacing: Theme.Spacing.m) {
                Image(systemName: "car.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.brand)
                    .frame(width: 44, height: 44)
                    .background(Theme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(Theme.Spacing.l)
            .productCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看 CarPlay 設定與使用步驟")
    }

    private var title: String {
        if !model.hasSeenSetup { return "準備你的 CarPlay" }
        if model.liveActivityMode == .off { return "CarPlay 即時動態已關閉" }
        return model.isCarConnected ? "已偵測到車用音訊" : "CarPlay 使用指南"
    }

    private var detail: String {
        if !model.hasSeenSetup { return "完成一次設定，了解如何在車上顯示歌詞。" }
        if model.liveActivityMode == .off { return "仍可使用小工具；點此查看設定。" }
        return model.isCarConnected ? "歌詞更新速度由車機與系統決定。" : "連接車輛後，打開 CarLyrics 開始顯示。"
    }
}

/// 歡迎頁的靜態示意，內容為自編文字，不冒充即時播放。
struct WelcomeLyricsPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            HStack {
                Label("歌詞畫面示意", systemImage: "waveform")
                Spacer()
                Image(systemName: "car.fill")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("讓旋律陪著你").font(.title3).foregroundStyle(.secondary)
                Text("把這一刻，唱成風景。")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("下一段旅程，慢慢聽。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Capsule().fill(Theme.brand).frame(width: 48, height: 3)
                Capsule().fill(Theme.brand.opacity(0.15)).frame(height: 3)
            }
            .accessibilityHidden(true)
        }
        .padding(Theme.Spacing.xl)
        .productCard()
    }
}
