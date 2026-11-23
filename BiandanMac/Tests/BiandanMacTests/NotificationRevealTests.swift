import Foundation
import XCTest
@testable import BiandanMac

final class NotificationRevealTests: XCTestCase {
    func testSidebarByStatus() {
        XCTAssertEqual(RevealPlan.sidebar(status: .pending, overdue: false), .all)
        XCTAssertEqual(RevealPlan.sidebar(status: .pending, overdue: true), .overdue)
        XCTAssertEqual(RevealPlan.sidebar(status: .completed, overdue: false), .completed)
        XCTAssertEqual(RevealPlan.sidebar(status: .abandoned, overdue: false), .abandoned)
    }

    func testExpiry() {
        let now = Date()
        XCTAssertFalse(RevealPlan.isExpired(since: now.addingTimeInterval(-30), now: now))
        XCTAssertTrue(RevealPlan.isExpired(since: now.addingTimeInterval(-300), now: now))
        XCTAssertTrue(RevealPlan.isExpired(since: nil, now: now))
    }

    @MainActor
    func testInboxRemembersTarget() {
        ReminderInbox.reveal(.occurrence("42"))
        XCTAssertEqual(ReminderInbox.pendingReveal, .occurrence("42"))
        XCTAssertNotNil(ReminderInbox.pendingRevealAt)
        ReminderInbox.reveal(.importer)
        XCTAssertEqual(ReminderInbox.pendingReveal, .importer)
        ReminderInbox.pendingReveal = nil
    }
}
