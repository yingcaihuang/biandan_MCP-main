import XCTest
@testable import BiandanMac

/// 批量写云端的有限并发和限流重试规则。
final class BatchConcurrencyTests: XCTestCase {
    private actor Gauge {
        var now = 0
        var peak = 0
        func enter() { now += 1; peak = max(peak, now) }
        func leave() { now -= 1 }
    }

    private struct Boom: Error {}

    func testKeepsOrderAndRespectsLimit() async throws {
        let gauge = Gauge()
        let out = try await BatchConcurrency.map(Array(0..<10), limit: 3) { _, value in
            await gauge.enter()
            try await Task.sleep(nanoseconds: UInt64((10 - value) * 2_000_000))
            await gauge.leave()
            return value * 2
        }
        XCTAssertEqual(out, (0..<10).map { $0 * 2 })
        let peak = await gauge.peak
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 1)
    }

    func testStopsOnError() async {
        do {
            _ = try await BatchConcurrency.map(Array(0..<6), limit: 2) { _, value -> Int in
                if value == 1 { throw Boom() }
                return value
            }
            XCTFail("应该抛错")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testEmptyInput() async throws {
        let out = try await BatchConcurrency.map([Int]()) { _, value in value }
        XCTAssertEqual(out, [])
    }

    func testGroupsKeepOrder() {
        XCTAssertEqual(BatchConcurrency.groups(["a", "b", "a", "c", "b"]), [[0, 2], [1, 4], [3]])
        XCTAssertEqual(BatchConcurrency.groups([String]()), [])
    }

    func testRetryPolicy() {
        XCTAssertTrue(RetryPolicy.shouldRetry(status: 429, method: "POST"))
        XCTAssertTrue(RetryPolicy.shouldRetry(status: 503, method: "GET"))
        XCTAssertFalse(RetryPolicy.shouldRetry(status: 503, method: "PATCH"))
        XCTAssertFalse(RetryPolicy.shouldRetry(status: 500, method: "GET"))
        XCTAssertFalse(RetryPolicy.shouldRetry(status: nil, method: "GET"))
        XCTAssertEqual(RetryPolicy.delay(attempt: 1, retryAfter: nil), 0.5, accuracy: 0.001)
        XCTAssertEqual(RetryPolicy.delay(attempt: 2, retryAfter: nil), 1, accuracy: 0.001)
        XCTAssertEqual(RetryPolicy.delay(attempt: 3, retryAfter: nil), 2, accuracy: 0.001)
        XCTAssertEqual(RetryPolicy.delay(attempt: 1, retryAfter: 2), 2, accuracy: 0.001)
        XCTAssertEqual(RetryPolicy.delay(attempt: 1, retryAfter: 30), 10, accuracy: 0.001)
    }
}
