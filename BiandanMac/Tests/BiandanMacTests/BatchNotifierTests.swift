import XCTest
@testable import BiandanMac

/// 批量操作做完后的通知：少量且全部成功时不打扰，数量多、有失败或中途登录失效时写清楚。
final class BatchNotifierTests: XCTestCase {
    func testSmallSuccessfulBatchIsQuiet() {
        XCTAssertNil(BatchNotifier.message(label: "完成", total: 3, processed: 3, failed: 0, error: nil))
    }

    func testLargeBatchNotifies() {
        let message = BatchNotifier.message(label: "删除", total: 108, processed: 108, failed: 0, error: nil)
        XCTAssertEqual(message?.title, "批量操作已完成")
        XCTAssertEqual(message?.body, "删除 108 项：成功 108 项")
    }

    func testFailureNotifiesEvenWhenSmall() {
        let message = BatchNotifier.message(label: "删除", total: 3, processed: 3, failed: 1, error: "网络超时")
        XCTAssertEqual(message?.title, "批量操作有部分没成功")
        XCTAssertEqual(message?.body, "删除 3 项：成功 2 项，1 项没成功（网络超时）")
    }

    func testInterruptedBySignOut() {
        let message = BatchNotifier.message(label: "改期", total: 20, processed: 15, failed: 0, error: nil)
        XCTAssertEqual(message?.title, "批量操作有部分没成功")
        XCTAssertEqual(message?.body, "改期 20 项：成功 15 项，5 项因为登录失效没有处理")
    }
}
