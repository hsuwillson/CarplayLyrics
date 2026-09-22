import AuthenticationServices
import Foundation
import UIKit

struct SpotifyTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// 實際取得的權限（舊版存的 token 沒有這個欄位）
    var scope: String?
}

enum SpotifyAuthError: LocalizedError {
    case notLoggedIn
    case cancelled
    case invalidCallback(String)
    case stateMismatch
    case tokenRequestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "尚未登入 Spotify"
        case .cancelled: return "已取消登入"
        case .invalidCallback(let m): return "登入回傳異常：\(m)"
        case .stateMismatch: return "登入驗證失敗（state 不符）"
        case .tokenRequestFailed(let code, let body): return "取得 token 失敗（HTTP \(code)）\(body)"
        }
    }
}

/// Spotify OAuth：Authorization Code + PKCE（不使用 Client Secret）
@MainActor
final class SpotifyAuth: NSObject, ObservableObject {
    @Published private(set) var isLoggedIn: Bool

    private var tokens: SpotifyTokens?
    private var session: ASWebAuthenticationSession?
    private var refreshTask: Task<SpotifyTokens, Error>?
    private static let keychainAccount = "spotify.tokens"

    override init() {
        let saved = Keychain.load(account: Self.keychainAccount)
            .flatMap { try? JSONDecoder().decode(SpotifyTokens.self, from: $0) }
        tokens = saved
        isLoggedIn = saved != nil
        super.init()
    }

    // MARK: 登入

    func login() async throws {
        let verifier = PKCE.makeVerifier()
        let state = UUID().uuidString

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.spotifyClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: AppConfig.spotifyRedirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "scope", value: AppConfig.spotifyScopes),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = components.url else { throw SpotifyAuthError.invalidCallback("URL 錯誤") }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            // 確保 continuation 只 resume 一次
            let once = ResumeOnce()
            let s = ASWebAuthenticationSession(url: authURL, callback: .customScheme(AppConfig.callbackScheme)) { url, error in
                guard once.claim() else { return }
                if let url {
                    continuation.resume(returning: url)
                } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    continuation.resume(throwing: SpotifyAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? SpotifyAuthError.invalidCallback("沒有回傳資料"))
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            self.session = s
            if !s.start(), once.claim() {
                continuation.resume(throwing: SpotifyAuthError.invalidCallback("無法開啟登入頁"))
            }
        }
        session = nil

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let err = value("error") { throw SpotifyAuthError.invalidCallback(err) }
        guard value("state") == state else { throw SpotifyAuthError.stateMismatch }
        guard let code = value("code") else { throw SpotifyAuthError.invalidCallback("缺少 code") }

        let response = try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": AppConfig.spotifyRedirectURI,
            "client_id": AppConfig.spotifyClientID,
            "code_verifier": verifier,
        ])
        guard let refresh = response.refresh_token else {
            throw SpotifyAuthError.tokenRequestFailed(200, "缺少 refresh_token")
        }
        store(SpotifyTokens(accessToken: response.access_token,
                            refreshToken: refresh,
                            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)),
                            scope: response.scope))
    }

    /// 目前的 token 是否包含某個權限
    func hasScope(_ scope: String) -> Bool {
        (tokens?.scope ?? "").split(separator: " ").contains { $0 == scope }
    }

    func logout() {
        tokens = nil
        Keychain.delete(account: Self.keychainAccount)
        isLoggedIn = false
    }

    // MARK: Token

    /// 取得有效的 access token；快過期時自動 refresh
    func validAccessToken() async throws -> String {
        guard let t = tokens else { throw SpotifyAuthError.notLoggedIn }
        if t.expiresAt.timeIntervalSinceNow > 60 { return t.accessToken }
        return try await refresh().accessToken
    }

    @discardableResult
    func refresh() async throws -> SpotifyTokens {
        if let running = refreshTask { return try await running.value }
        guard let current = tokens else { throw SpotifyAuthError.notLoggedIn }

        let task = Task { () throws -> SpotifyTokens in
            let r = try await self.requestToken([
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": AppConfig.spotifyClientID,
            ])
            return SpotifyTokens(accessToken: r.access_token,
                                 refreshToken: r.refresh_token ?? current.refreshToken,
                                 expiresAt: Date().addingTimeInterval(TimeInterval(r.expires_in)),
                                 scope: r.scope ?? current.scope)
        }
        refreshTask = task
        defer { refreshTask = nil }

        do {
            let new = try await task.value
            store(new)
            debugLog("Token 已更新")
            return new
        } catch {
            // refresh token 失效（例如被撤銷）→ 需要重新登入
            if case SpotifyAuthError.tokenRequestFailed(let code, _) = error, code == 400 || code == 401 {
                debugLog("Refresh token 失效，請重新登入")
                logout()
            }
            throw error
        }
    }

    private func store(_ t: SpotifyTokens) {
        tokens = t
        if let data = try? JSONEncoder().encode(t) {
            do { try Keychain.save(data, account: Self.keychainAccount) } catch { debugLog("Keychain 寫入失敗：\(error)") }
        }
        isLoggedIn = true
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
        let scope: String?
    }

    private func requestToken(_ params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(params).data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // 錯誤回應只包含錯誤代碼，不含 token
            let body = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
            throw SpotifyAuthError.tokenRequestFailed(status, body)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-._~")
        return params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

extension SpotifyAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        }
    }
}
