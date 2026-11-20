import Foundation
import XCTest
@testable import BiandanMac

final class FocusTests: XCTestCase {
    func testIdentifierAndMinutes() {
        XCTAssertEqual(FocusCodec.identifier(startedAt: Date(timeIntervalSince1970: 1_700_000_000.9999)), "1700000000999")
        XCTAssertNil(FocusCodec.validMinutes(0))
        XCTAssertNil(FocusCodec.validMinutes(1441))
        XCTAssertNil(FocusCodec.validMinutes(.nan))
        XCTAssertEqual(FocusCodec.validMinutes(25.9), 25)
        XCTAssertEqual(FocusCodec.validMinutes(1440), 1440)
    }

    func testEndTimeText() {
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = zone
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10, minute: 0))!
        XCTAssertEqual(FocusCodec.endTimeText(start.addingTimeInterval(1800), timeZone: zone), "2026-11-20T10:30:00+08:00")
    }

    func testCreateLogMatchesPythonFormat() {
        let plain = FocusCodec.createLog(title: "  读书 ", link: nil, endTime: "2026-11-20T10:30:00+08:00")
        XCTAssertEqual(plain, #"{"eventId": -1, "eventType": -1, "eventTitle": "读书", "endTime": "2026-11-20T10:30:00+08:00"}"#)
        let link = FocusLink(occurrenceID: "1763600000000", listID: 3, title: "写周报")
        let linked = FocusCodec.createLog(title: "", link: link, endTime: "x")
        XCTAssertEqual(linked, #"{"eventId": 1763600000000, "eventType": 3, "eventTitle": "写周报", "endTime": "x"}"#)
        let quoted = FocusCodec.createLog(title: #"a"b"#, link: nil, endTime: "x")
        XCTAssertEqual(FocusLog(raw: quoted).eventTitle, #"a"b"#)
    }

    func testUpdatedLogKeepsUnknownKeys() {
        let original = #"{"eventId":5,"eventType":1,"eventTitle":"a","endTime":"x","extra":true}"#
        let log = FocusLog(raw: FocusCodec.updatedLog(original: original, title: " b "))
        XCTAssertEqual(log.eventTitle, "b")
        XCTAssertEqual(log.eventID, "5")
        XCTAssertEqual(log.endTime, "x")
        XCTAssertEqual(log.object["extra"], .bool(true))
    }

    func testUpdatedLogFromPlainText() {
        let log = FocusLog(raw: FocusCodec.updatedLog(original: "Fri Nov 20 2026", title: "b"))
        XCTAssertEqual(log.eventTitle, "b")
        XCTAssertNil(log.eventID)
        XCTAssertEqual(log.eventType, -1)
        XCTAssertEqual(log.endTime, "Fri Nov 20 2026")
    }
}
