import XCTest
@testable import BiandanMac

/// MCP batch_delete_tasks 单项参数的检查，规则和 delete_task 相同。
final class MCPBatchDeleteTests: XCTestCase {
    private func target(_ object: JSONObject) throws -> BatchDeleteTarget {
        try BiandanService.mcpDeleteTarget(MCPArgs(object))
    }

    func testOneOffTask() throws {
        let item = try target(["task_id": .string("123")])
        XCTAssertEqual(item.taskID, "123")
        XCTAssertNil(item.scope)
        XCTAssertNil(item.occurrenceID)
    }

    func testOccurrenceScopeNeedsOccurrenceID() throws {
        XCTAssertThrowsError(try target(["task_id": .string("123"), "scope": .string("occurrence")]))
        let item = try target(["task_id": .string("123"), "scope": .string("occurrence"),
                               "occurrence_id": .string("456")])
        XCTAssertEqual(item.scope, .occurrence)
        XCTAssertEqual(item.occurrenceID, "456")
    }

    func testFromDateOnlyWithFuturePending() throws {
        XCTAssertThrowsError(try target(["task_id": .string("123"), "scope": .string("series"),
                                         "from_date": .string("2026-12-01")]))
        let item = try target(["task_id": .string("123"), "scope": .string("future_pending"),
                               "from_date": .string("2026-12-01")])
        XCTAssertEqual(item.scope, .futurePending)
        XCTAssertNotNil(item.fromDate)
    }

    func testRejectsUnknownScopeAndBadID() {
        XCTAssertThrowsError(try target(["task_id": .string("123"), "scope": .string("all")]))
        XCTAssertThrowsError(try target(["task_id": .string("abc")]))
    }
}
