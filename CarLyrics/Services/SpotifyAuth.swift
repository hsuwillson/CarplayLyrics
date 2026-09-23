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

/// Spotify OAuth：Authorization Code + PKCE（不使用 Client Secret）
@MainActor
@Observable
final class SpotifyAuth: NSObject {
    private(set) var isLoggedIn: Bool
    /// 目前 token 的權限（畫面據此判斷能不能控制播放）
    private(set) var grantedScope: String?

    @ObservationIgnored private var tokens: SpotifyTokens?
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private var refreshTask: Task<SpotifyTokens, Error>?
    /// 登入 / 登出的世代；進行中的 refresh 回來時若世代已變就丟掉
    @ObservationIgnored private var sessionGeneration = 0
    private static let keychainAccount = "spotify.tokens"
    /// 重開機後尚未解鎖，Keychain 暫時讀不到 → 稍後重讀，不要當成「未登入」
    @ObservationIgnored private var keychainLocked = false

    override init() {
        let (data, status) = Keychain.load(account: Self.keychainAccount)
        let saved = data.flatMap { try? JSONDecoder().decode(SpotifyTokens.self, from: $0) }
        tokens = saved
        grantedScope = saved?.scope
        keychainLocked = status == errSecInteractionNotAllowed
        isLoggedIn = saved != nil || keychainLocked
        super.init()
    }

    /// Keychain 之前被鎖住時重讀一次
    func reloadIfNeeded() {
        guard keychainLocked, tokens == nil else { return }
        let (data, status) = Keychain.load(account: Self.keychainAccount)
        if let t = data.flatMap({ try? JSONDecoder().decode(SpotifyTokens.self, from: $0) }) {
            tokens = t
            grantedScope = t.scope
            keychainLocked = false
            isLoggedIn = true
            debugLog("Keychain 已解鎖，重新讀取登入資訊")
        } else if status != errSecInteractionNotAllowed {
            keychainLocked = false
            isLoggedIn = false
        }
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
            throw SpotifyAuthError.missingRefreshToken
        }
        store(SpotifyTokens(accessToken: response.access_token,
                            refreshToken: refresh,
                            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)),
                            scope: response.scope))
    }

    /// 目前的 token 是否包含某個權限
    func hasScope(_ scope: String) -> Bool {
        (grantedScope ?? "").split(separator: " ").contains { $0 == scope }
    }

    func logout() {
        sessionGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        keychainLocked = false
        tokens = nil
        grantedScope = nil
        let status = Keychain.delete(account: Self.keychainAccount)
        if status != errSecSuccess && status != errSecItemNotFound {
            debugLog("Keychain 刪除失敗（\(status)），下次啟動可能仍是登入狀態")
        }
        isLoggedIn = false
    }

    // MARK: Token

    /// 取得有效的 access token；快過期時自動 refresh
    func validAccessToken() async throws -> String {
        reloadIfNeeded()
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
        let generation = sessionGeneration
        defer { refreshTask = nil }

        do {
            let new = try await task.value
            guard generation == sessionGeneration else {
                debugLog("Token 更新完成時已登出，丟棄")
                throw SpotifyAuthError.notLoggedIn
            }
            store(new)
            debugLog("Token 已更新")
            return new
        } catch {
            // 只有 refresh token 確定失效（invalid_grant / 401）才登出；其他錯誤保留 token 稍後再試
            if case SpotifyAuthError.tokenRequestFailed(let code, let body) = error,
               code == 401 || (code == 400 && body.contains("invalid_grant")) {
                debugLog("Refresh token 失效，請重新登入")
                logout()
            } else {
                debugLog("Token 更新失敗，稍後重試：\(error.localizedDescription)")
            }
            throw error
        }
    }

    private func store(_ t: SpotifyTokens) {
        tokens = t
        if grantedScope != t.scope { grantedScope = t.scope }
        if let data = try? JSONEncoder().encode(t) {
            do { try Keychain.save(data, account: Self.keychainAccount) } catch { debugLog("Keychain 寫入失敗：\(error)") }
        }
        if !isLoggedIn { isLoggedIn = true }
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
