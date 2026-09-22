import CryptoKit
import Foundation

/// OAuth PKCE（RFC 7636）工具
enum PKCE {
    private static let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func makeVerifier(length: Int = 64) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &rng)! })
    }

    static func challenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
