import XCTest
@testable import BiandanMac

final class ReminderActionTests: XCTestCase {
    func testActions() {
        XCTAssertNil(ReminderAction.complete.snoozeSeconds)
        XCTAssertEqual(ReminderAction.snooze10.snoozeSeconds, 600)
        XCTAssertEqual(ReminderAction.snooze60.snoozeSeconds, 3600)
        XCTAssertEqual(ReminderAction(rawValue: "biandan.action.complete"), .complete)
        XCTAssertNil(ReminderAction(rawValue: "com.apple.UNNotificationDefaultActionIdentifier"))
        let category = ReminderAction.category()
        XCTAssertEqual(category.identifier, ReminderAction.categoryID)
        XCTAssertEqual(category.actions.map(\.title), ["完成", "10 分钟后提醒", "1 小时后提醒"])
    }

    /// 稍后提醒的标识不能带 ReminderScheduler 的前缀，否则重排提醒时会被清掉。
    func testSnoozeIdentifiers() {
        let id = ReminderAction.snoozeIdentifier("123")
        XCTAssertFalse(id.hasPrefix(ReminderScheduler.prefix))
        XCTAssertEqual(ReminderAction.occurrenceID(fromSnooze: id), "123")
        XCTAssertNil(ReminderAction.occurrenceID(fromSnooze: "biandan.reminder.123.1"))
        XCTAssertNil(ReminderAction.occurrenceID(fromSnooze: ReminderAction.snoozePrefix))
    }

    func testStaleSnoozes() {
        let ids = [ReminderAction.snoozeIdentifier("a"), ReminderAction.snoozeIdentifier("b"),
                   "biandan.reminder.c.1", "biandan.test.x"]
        XCTAssertEqual(ReminderAction.staleSnoozes(ids, keeping: ["a"]), [ReminderAction.snoozeIdentifier("b")])
        XCTAssertEqual(ReminderAction.staleSnoozes(ids, keeping: []).count, 2)
    }
}
