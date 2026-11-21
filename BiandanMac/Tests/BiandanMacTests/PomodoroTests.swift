import Foundation
import XCTest
@testable import BiandanMac

final class PomodoroTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(link: FocusLink? = nil) -> PomodoroSession {
        PomodoroSession(startedAt: t0, plannedMinutes: 25, title: "写周报", link: link)
    }

    func testPauseIsExcluded() {
        var value = session()
        value.pause(at: t0.addingTimeInterval(300))
        XCTAssertEqual(value.elapsed(at: t0.addingTimeInterval(500)), 300)
        value.resume(at: t0.addingTimeInterval(600))
        XCTAssertFalse(value.isPaused)
        XCTAssertEqual(value.elapsed(at: t0.addingTimeInterval(900)), 600)
        XCTAssertEqual(value.remaining(at: t0.addingTimeInterval(900)), 900)
        XCTAssertFalse(value.isFinished(at: t0.addingTimeInterval(1799)))
        XCTAssertTrue(value.isFinished(at: t0.addingTimeInterval(1800)))
        XCTAssertEqual(value.elapsed(at: t0.addingTimeInterval(4000)), 1500)
    }

    func testRecords() {
        let link = FocusLink(occurrenceID: "o1", listID: 3, title: "写周报")
        let value = session(link: link)
        XCTAssertEqual(value.record(at: t0.addingTimeInterval(1500), completed: true),
                       FocusInput(startedAt: t0, minutes: 25, title: "写周报", goodCount: 1, badCount: 0, link: link))
        XCTAssertEqual(value.record(at: t0.addingTimeInterval(630), completed: false),
                       FocusInput(startedAt: t0, minutes: 10, title: "写周报", goodCount: 0, badCount: 1, link: link))
        XCTAssertNil(value.record(at: t0.addingTimeInterval(59), completed: false))
    }

    func testClockText() {
        XCTAssertEqual(PomodoroSession.clock(1500), "25:00")
        XCTAssertEqual(PomodoroSession.clock(1499.2), "25:00")
        XCTAssertEqual(PomodoroSession.clock(59), "00:59")
        XCTAssertEqual(PomodoroSession.clock(-3), "00:00")
    }
}
