import XCTest

final class PKCETests: XCTestCase {
    func testRFC7636Example() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierFormat() {
        let v = PKCE.makeVerifier()
        XCTAssertEqual(v.count, 64)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(v.unicodeScalars.allSatisfy(allowed.contains))
        XCTAssertNotEqual(v, PKCE.makeVerifier())
    }
}
