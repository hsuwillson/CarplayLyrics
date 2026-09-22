import Foundation

enum AppConfig {
    /// TODO: 換成 Spotify Developer Dashboard 上的 Client ID（Client ID 不是機密，但不要放 Client Secret）
    static let spotifyClientID = "YOUR_SPOTIFY_CLIENT_ID"
    static let spotifyRedirectURI = "carlyrics://callback"
    static let spotifyScopes = "user-read-currently-playing user-read-playback-state"
}
