import XCTest
@testable import BiandanMac

/// 番茄钟按剩余比例分 4 段配色，每段 25%。
final class PomodoroPhaseTests: XCTestCase {
    func testPhaseBoundaries() {
        XCTAssertEqual(PomodoroSession.phase(remainingFraction: 1), 0)
        XCTAssertEqual(PomodoroSession.phase(remainingFraction: 0.76), 0)
        XCTAssertEqual(PomodoroSession.phase(remainingFraction: 0.75), 1)
        XCTAssertEqual(PomodoroSession.phase(remainingFraction: 0.51), 1)
        XCTAssertEqual(PomodoroSession.phase(remainingFraction: 0.5), 2)
        XCTAssertEqual(PomodoroSession.phase(remainingFraction: 0.26), 2)
        XCTAssertEqual(PomodoroSession.phase(remainingFraction: 0.25), 3)
        XCTAssertEqual(PomodoroSession.phase(remainingFraction: 0), 3)
    }

    func testRemainingFraction() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let session = PomodoroSession(startedAt: start, plannedMinutes: 20, title: "专注", link: nil)
        XCTAssertEqual(session.remainingFraction(at: start), 1, accuracy: 0.0001)
        XCTAssertEqual(session.remainingFraction(at: start.addingTimeInterval(5 * 60)), 0.75, accuracy: 0.0001)
        XCTAssertEqual(session.remainingFraction(at: start.addingTimeInterval(19 * 60)), 0.05, accuracy: 0.0001)
        XCTAssertEqual(session.remainingFraction(at: start.addingTimeInterval(30 * 60)), 0, accuracy: 0.0001)
    }

    func testPausedTimeDoesNotCount() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var session = PomodoroSession(startedAt: start, plannedMinutes: 20, title: "专注", link: nil)
        session.pause(at: start.addingTimeInterval(5 * 60))
        XCTAssertEqual(session.remainingFraction(at: start.addingTimeInterval(15 * 60)), 0.75, accuracy: 0.0001)
    }
}
