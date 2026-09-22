import XCTest

final class ProvisioningProfileTests: XCTestCase {
    /// 模擬描述檔：前後夾雜二進位（CMS 簽章），中間是 XML plist
    private func profileData(groups: [String], expiration: String? = "2026-09-29T08:00:00Z") -> Data {
        let groupXML = groups.map { "<string>\($0)</string>" }.joined()
        let exp = expiration.map { "<key>ExpirationDate</key><date>\($0)</date>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>測試描述檔</string>
        <key>TeamName</key><string>測試團隊</string>
        \(exp)
        <key>Entitlements</key><dict>
        <key>com.apple.security.application-groups</key><array>\(groupXML)</array>
        </dict></dict></plist>
        """
        var data = Data([0x30, 0x82, 0x01, 0xFF, 0x00, 0x13])
        data.append(Data(xml.utf8))
        data.append(Data([0x00, 0xA0, 0x82, 0x0B]))
        return data
    }

    func testParsesGroupsAndExpiration() throws {
        let p = try XCTUnwrap(ProvisioningProfile(data: profileData(groups: ["group.com.willsonhsu.CarLyrics.ABCDE12345"])))
        XCTAssertEqual(p.appGroups, ["group.com.willsonhsu.CarLyrics.ABCDE12345"])
        XCTAssertEqual(p.name, "測試描述檔")
        XCTAssertEqual(p.teamName, "測試團隊")
        let exp = try XCTUnwrap(p.expirationDate)
        XCTAssertEqual(p.daysRemaining(now: exp.addingTimeInterval(-5.5 * 86_400)), 5)
        XCTAssertEqual(p.daysRemaining(now: exp.addingTimeInterval(3600)), -1)
    }

    func testMissingFields() throws {
        let p = try XCTUnwrap(ProvisioningProfile(data: profileData(groups: [], expiration: nil)))
        XCTAssertEqual(p.appGroups, [])
        XCTAssertNil(p.expirationDate)
        XCTAssertNil(p.daysRemaining())
    }

    func testGarbage() {
        XCTAssertNil(ProvisioningProfile(data: Data([1, 2, 3])))
    }
}
