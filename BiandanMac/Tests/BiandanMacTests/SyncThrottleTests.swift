import Foundation
import XCTest
@testable import BiandanMac

final class SyncThrottleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAutomaticRespectsMinimumInterval() {
        var throttle = SyncThrottle()
        XCTAssertEqual(throttle.decide(.automatic, now: t0), .allow)
        throttle.recordSuccess(at: t0, records: 100)
        XCTAssertEqual(throttle.decide(.automatic, now: t0.addingTimeInterval(30)), .skip)
        XCTAssertEqual(throttle.decide(.automatic, now: t0.addingTimeInterval(61)), .allow)
        XCTAssertEqual(throttle.decide(.manual, now: t0.addingTimeInterval(1)), .allow)
        XCTAssertEqual(throttle.decide(.startup, now: t0.addingTimeInterval(1)), .allow)
    }

    func testLargeDatasetWidensInterval() {
        var throttle = SyncThrottle()
        throttle.recordSuccess(at: t0, records: 3000)
        XCTAssertEqual(throttle.autoInterval, 180)
        XCTAssertEqual(throttle.decide(.automatic, now: t0.addingTimeInterval(120)), .skip)
        XCTAssertEqual(throttle.decide(.automatic, now: t0.addingTimeInterval(181)), .allow)
    }

    func testFailureBackoff() {
        var throttle = SyncThrottle()
        throttle.recordFailure(at: t0, retryAfter: nil)
        XCTAssertEqual(throttle.backoff, 30)
        XCTAssertEqual(throttle.decide(.automatic, now: t0.addingTimeInterval(20)), .skip)
        XCTAssertEqual(throttle.decide(.automatic, now: t0.addingTimeInterval(31)), .allow)
        throttle.recordFailure(at: t0, retryAfter: nil)
        throttle.recordFailure(at: t0, retryAfter: nil)
        XCTAssertEqual(throttle.backoff, 120)
        for _ in 0..<20 { throttle.recordFailure(at: t0, retryAfter: nil) }
        XCTAssertEqual(throttle.backoff, 1800)
        XCTAssertEqual(throttle.decide(.manual, now: t0.addingTimeInterval(1)), .allow)
        throttle.recordSuccess(at: t0, records: 10)
        XCTAssertEqual(throttle.consecutiveFailures, 0)
        XCTAssertEqual(throttle.backoff, 0)
    }

    func testRetryAfterBlocksManualToo() {
        var throttle = SyncThrottle()
        throttle.recordFailure(at: t0, retryAfter: 90)
        XCTAssertEqual(throttle.decide(.manual, now: t0.addingTimeInterval(30)), .wait(60))
        XCTAssertEqual(throttle.decide(.automatic, now: t0.addingTimeInterval(30)), .skip)
        XCTAssertEqual(throttle.decide(.manual, now: t0.addingTimeInterval(91)), .allow)
        throttle.recordFailure(at: t0, retryAfter: 99_999)
        XCTAssertEqual(throttle.retryNotBefore, t0.addingTimeInterval(1800))
    }
}
