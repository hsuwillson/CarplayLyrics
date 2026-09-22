import SwiftUI

/// 主畫面橫幅要顯示的一則提示
struct AppNotice: Equatable, Identifiable {
    enum Action: Equatable {
        case relogin, retry, openSettings

        var title: String {
            switch self {
            case .relogin: return "重新登入"
            case .retry: return "重試"
            case .openSettings: return "開啟設定"
            }
        }
    }

    var id: String { title }
    let symbol: String
    let title: String
    let message: String
    let action: Action?
    /// 需要使用者處理（橘色）；暫時性問題用灰色
    let needsAttention: Bool

    init(symbol: String, title: String, message: String, action: Action?, needsAttention: Bool) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
        self.needsAttention = needsAttention
    }

    init(error: UserFacingError) {
        let action: Action? = {
            switch error.action {
            case .relogin: return .relogin
            case .retry: return .retry
            case .openSettings: return .openSettings
            case .none: return nil
            }
        }()
        let symbol: String = {
            switch error {
            case .offline: return "wifi.slash"
            case .timeout: return "hourglass"
            case .spotifyUnauthorized, .missingControlScope, .loginFailed: return "person.crop.circle.badge.exclamationmark"
            case .rateLimited, .quotaExceeded: return "gauge.with.dots.needle.100percent"
            default: return "exclamationmark.triangle"
            }
        }()
        self.init(symbol: symbol, title: error.title, message: error.message, action: action,
                  needsAttention: error.needsAttention)
    }

    static let liveActivitiesDisabled = AppNotice(
        symbol: "rectangle.badge.xmark", title: "系統已關閉即時動態",
        message: "鎖定畫面與 CarPlay 不會顯示歌詞。請到「設定」打開 CarLyrics 的即時動態。",
        action: .openSettings, needsAttention: true)

    static func signingExpiring(days: Int) -> AppNotice {
        AppNotice(symbol: "clock.badge.exclamationmark",
                  title: days < 0 ? "簽名已過期" : days == 0 ? "簽名今天到期" : "簽名 \(days) 天後到期",
                  message: "請在電腦開著 AltServer 時，用 AltStore 重新整理 CarLyrics，否則 App 會打不開。",
                  action: nil, needsAttention: true)
    }
}

/// 可收合的提示橫幅：圖示 + 標題 + 說明 + 一顆動作按鈕
struct NoticeBanner: View {
    let notice: AppNotice
    let perform: (AppNotice.Action) -> Void
    @State private var dismissedID: String?

    init(notice: AppNotice, perform: @escaping (AppNotice.Action) -> Void) {
        self.notice = notice
        self.perform = perform
    }

    var body: some View {
        if dismissedID != notice.id {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: notice.symbol)
                    .font(.title3)
                    .foregroundStyle(notice.needsAttention ? Color.orange : Color.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(.subheadline.weight(.semibold))
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if let action = notice.action {
                    Button(action.title) { perform(action) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.glass)
                } else {
                    Button {
                        withAnimation(.snappy) { dismissedID = notice.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("關閉提示")
                }
            }
            .padding(12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .contain)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
