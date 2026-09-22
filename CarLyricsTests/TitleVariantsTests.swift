import XCTest

final class TitleVariantsTests: XCTestCase {
    func testPlainTitle() {
        XCTAssertEqual(TitleVariants.make("測試歌"), ["測試歌"])
    }

    func testStripDecorations() {
        XCTAssertEqual(TitleVariants.stripDecorations("Test Song (Live) - Remastered 2020"), "Test Song")
        XCTAssertEqual(TitleVariants.stripDecorations("測試歌【電視劇主題曲】"), "測試歌")
        XCTAssertEqual(TitleVariants.stripDecorations("測試歌（現場版）"), "測試歌")
    }

    func testMixedCJKAndLatin() {
        XCTAssertEqual(TitleVariants.make("測試歌 Test Song"), ["測試歌 Test Song", "測試歌", "Test Song"])
    }

    func testDecoratedMixed() {
        let v = TitleVariants.make("測試 Test (feat. Someone)")
        XCTAssertEqual(v, ["測試 Test (feat. Someone)", "測試 Test", "測試", "Test"])
    }
}
