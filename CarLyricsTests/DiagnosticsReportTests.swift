import XCTest

final class DiagnosticsReportTests: XCTestCase {
    func testSectionsSkipNilAndEmpty() {
        var r = DiagnosticsReport(reason: "測試")
        r.add("A", [("x", "1"), ("y", nil), ("z", "3")])
        r.add("空的", [("n", nil)])
        r.add("B", [("k", "v")])
        XCTAssertEqual(r.sections.map(\.title), ["A", "B"])
        XCTAssertEqual(r.sections[0].items, [.init(key: "x", value: "1"), .init(key: "z", value: "3")])
        XCTAssertEqual(r.text, "［狀態快照：測試］\n〔A〕x=1，z=3\n〔B〕k=v")
    }

    func testEmptyReportHasHeaderOnly() {
        XCTAssertEqual(DiagnosticsReport(reason: "空").text, "［狀態快照：空］")
    }

    func testFormatters() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(DiagnosticsReport.seconds(2.5), "2.5 秒")
        XCTAssertNil(DiagnosticsReport.seconds(nil))
        XCTAssertEqual(DiagnosticsReport.ago(Date(timeIntervalSince1970: 90), now: now), "10 秒前")
        XCTAssertEqual(DiagnosticsReport.ago(Date(timeIntervalSince1970: 120), now: now), "0 秒前")
        XCTAssertNil(DiagnosticsReport.ago(nil, now: now))
        XCTAssertEqual(DiagnosticsReport.yesNo(true), "是")
        XCTAssertEqual(DiagnosticsReport.yesNo(false), "否")
        XCTAssertEqual(DiagnosticsReport.percent(0.456), "46%")
        XCTAssertNil(DiagnosticsReport.percent(-1))
    }
}
