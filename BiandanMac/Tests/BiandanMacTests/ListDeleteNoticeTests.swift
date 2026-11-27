import XCTest
@testable import BiandanMac

/// 删除分类在后台进行：进度文字和做完后的通知。
final class ListDeleteNoticeTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(ListDeleteNotice.label(name: "2026 节假日", deleteTasks: false), "把「2026 节假日」的任务移回未分类")
        XCTAssertEqual(ListDeleteNotice.label(name: "2026 节假日", deleteTasks: true), "删除「2026 节假日」的任务")
    }

    func testSmallSuccessIsQuiet() {
        XCTAssertNil(ListDeleteNotice.message(name: "工作", deleteTasks: false, total: 3, done: 3, ok: true, error: nil))
    }

    func testLargeSuccess() {
        let moved = ListDeleteNotice.message(name: "2026 节假日", deleteTasks: false, total: 151, done: 151, ok: true, error: nil)
        XCTAssertEqual(moved?.title, "分类已删除")
        XCTAssertEqual(moved?.body, "「2026 节假日」已删除，151 个任务已移回「未分类」")
        let deleted = ListDeleteNotice.message(name: "2026 节假日", deleteTasks: true, total: 151, done: 151, ok: true, error: nil)
        XCTAssertEqual(deleted?.body, "「2026 节假日」和其中 151 个任务已删除")
    }

    func testFailureAlwaysNotifies() {
        let message = ListDeleteNotice.message(name: "工作", deleteTasks: true, total: 3, done: 1, ok: false, error: "网络超时")
        XCTAssertEqual(message?.title, "删除分类没完成")
        XCTAssertEqual(message?.body, "「工作」已处理 1/3 个任务：网络超时。可以同步后再删一次。")
    }
}
