import Foundation

enum AppConfig {
    /// Spotify Developer Dashboard 上的 Client ID（不是機密；不要放 Client Secret）
    static let spotifyClientID = "72f25b50878c45b2a5f93e12e54352aa"
    static let callbackScheme = "carlyrics"
    static let spotifyRedirectURI = "carlyrics://callback"
    static let spotifyScopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state"
    static let controlScope = "user-modify-playback-state"
}
