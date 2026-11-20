import Foundation
import XCTest
@testable import BiandanMac

final class ConflictTests: XCTestCase {
    func testOtherFieldChangedRetriesOurChange() {
        let base: JSONObject = ["taskTitle": .string("读书"), "isImportant": .int(0)]
        let latest: JSONObject = ["taskTitle": .string("读书"), "isImportant": .int(1)]
        let result = ConflictMerge.resolve(base: base, latest: latest, desired: ["taskTitle": .string("读两本书")])
        XCTAssertEqual(result.remaining, ["taskTitle": .string("读两本书")])
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testSameValueAlreadyWritten() {
        let base: JSONObject = ["isUrgency": .int(0)]
        let latest: JSONObject = ["isUrgency": .bool(true)]
        let result = ConflictMerge.resolve(base: base, latest: latest, desired: ["isUrgency": .int(1)])
        XCTAssertTrue(result.remaining.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testSameFieldChangedElsewhereIsConflict() {
        let base: JSONObject = ["taskTitle": .string("读书"), "startTime": .string("2026-11-20")]
        let latest: JSONObject = ["taskTitle": .string("看电影"), "startTime": .string("2026-11-20")]
        let desired: JSONObject = ["taskTitle": .string("读两本书"), "startTime": .string("2026-11-21")]
        let result = ConflictMerge.resolve(base: base, latest: latest, desired: desired)
        XCTAssertEqual(result.conflicts, ["taskTitle"])
        XCTAssertEqual(result.remaining, ["startTime": .string("2026-11-21")])
    }

    func testMissingFieldTreatedAsUntouched() {
        let result = ConflictMerge.resolve(base: [:], latest: [:], desired: ["location": .string("公司")])
        XCTAssertEqual(result.remaining, ["location": .string("公司")])
        let added = ConflictMerge.resolve(base: [:], latest: ["location": .string("家")], desired: ["location": .string("公司")])
        XCTAssertEqual(added.conflicts, ["location"])
    }

    func testMessageDedupesLabels() {
        let text = ConflictMerge.message(kind: .task, conflicts: ["latitude", "location", "taskTitle"])
        XCTAssertTrue(text.contains("已被其他设备修改"))
        XCTAssertTrue(text.contains("地点、标题"))
    }
}
