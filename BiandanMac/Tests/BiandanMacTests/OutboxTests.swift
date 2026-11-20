import Foundation
import XCTest
@testable import BiandanMac

final class OutboxTests: XCTestCase {
    func testCommandRoundTrip() throws {
        let commands: [OutboxCommand] = [
            .completeOccurrence(id: "1763600000000"),
            .changeProgress(id: "1", action: .setCount, count: 3),
            .setSubtask(id: "1", index: 2, checked: true),
            .updateTask(taskID: "5", title: "读书", remark: nil, important: true, urgent: nil, collected: false),
            .setTimeReminder(taskID: "5", date: "2026-11-21", time: "09:30:00", enabled: true),
            .rescheduleTask(taskID: "5", start: "2026-11-22", end: nil, startTime: nil, endTime: "18:00:00"),
            .createFocus(FocusInput(startedAt: Date(timeIntervalSince1970: 1_763_600_000), minutes: 25, title: "写代码",
                                    goodCount: 1, badCount: 0,
                                    link: FocusLink(occurrenceID: "9", listID: 1, title: "写代码"))),
            .deleteFocus(id: "1763600000000"),
        ]
        for command in commands {
            let entry = try XCTUnwrap(OutboxEntry.make(label: "测试", command: command))
            XCTAssertEqual(entry.payload, OutboxPayload(label: "测试", command: command))
            XCTAssertFalse(entry.command.contains("("))
        }
        XCTAssertEqual(OutboxCommand.completeOccurrence(id: "1").name, "completeOccurrence")
    }

    func testTransientClassification() {
        XCTAssertTrue(OutboxPolicy.isTransient(CloudError("x", network: true)))
        XCTAssertTrue(OutboxPolicy.isTransient(CloudError("x", status: 503)))
        XCTAssertTrue(OutboxPolicy.isTransient(CloudError("x", status: 429)))
        XCTAssertFalse(OutboxPolicy.isTransient(CloudError("x", status: 409)))
        XCTAssertFalse(OutboxPolicy.isTransient(CloudError("x", status: 404)))
        XCTAssertFalse(OutboxPolicy.isTransient(CloudError("服务返回了无效的 JSON")))
        XCTAssertTrue(OutboxPolicy.isTransient(AuthError.renewalUnavailable(status: nil)))
        XCTAssertTrue(OutboxPolicy.isTransient(AuthError.renewalUnavailable(status: 503)))
        XCTAssertFalse(OutboxPolicy.isTransient(AuthError.renewalUnavailable(status: 403)))
        XCTAssertFalse(OutboxPolicy.isTransient(AuthError.reauthorizationRequired))
        XCTAssertTrue(OutboxPolicy.isTransient(ServiceError(wrapping: CloudError("x", network: true), mayHaveWritten: true)))
        XCTAssertFalse(OutboxPolicy.isTransient(ServiceError("请填写标题")))
        XCTAssertTrue(OutboxPolicy.isTransient(OperationFailure(error: CloudError("x", status: 502), changes: ChangeSet())))
        XCTAssertFalse(OutboxPolicy.isTransient(OperationFailure(error: ServiceError("x"), changes: ChangeSet())))
    }

    func testStoreKeepsOrderAndState() throws {
        let store = try LocalStore()
        let entries = try (1...3).map { index in
            try XCTUnwrap(OutboxEntry.make(label: "第 \(index) 条", command: .clearSchedule(taskID: String(index))))
        }
        for entry in entries { try store.enqueueOutbox(entry) }
        XCTAssertEqual(try store.outboxEntries(state: OutboxEntry.pending).map(\.opID), entries.map(\.opID))

        try store.updateOutbox(entries[0].opID, attempts: 1, lastError: "超时", state: OutboxEntry.pending)
        try store.updateOutbox(entries[1].opID, attempts: 1, lastError: "404", state: OutboxEntry.failed)
        let pending = try store.outboxEntries(state: OutboxEntry.pending)
        XCTAssertEqual(pending.map(\.opID), [entries[0].opID, entries[2].opID])
        XCTAssertEqual(pending.first?.attempts, 1)
        XCTAssertEqual(pending.first?.lastError, "超时")
        XCTAssertEqual(try store.outboxEntries(state: OutboxEntry.failed).count, 1)

        try store.removeOutbox(entries[0].opID)
        try store.removeOutbox(state: OutboxEntry.failed)
        XCTAssertEqual(try store.outboxEntries().map(\.opID), [entries[2].opID])
    }
}
