import XCTest
@testable import BiandanMac

final class BatchUndoTests: XCTestCase {
    /// 合并后撤销按相反顺序执行（每步内部保持原顺序），重做按原顺序执行。
    func testCombineReversesUndoOrder() {
        let a = UndoStep(undo: [.moveTask(taskID: "a", listID: "1")], redo: [.moveTask(taskID: "a", listID: "2")])
        let b = UndoStep(undo: [.moveTask(taskID: "b", listID: "1"), .moveTask(taskID: "b", listID: "3")],
                         redo: [.moveTask(taskID: "b", listID: "2")])
        let plan = UndoPlan.combine([a, b])
        func text(_ commands: [OutboxCommand]) -> [String] { commands.map { String(describing: $0) } }
        XCTAssertEqual(text(plan.undo), text(b.undo + a.undo))
        XCTAssertEqual(text(plan.redo), text(a.redo + b.redo))
        XCTAssertTrue(UndoPlan.combine([]).undo.isEmpty)
    }

    func testDeleteSummary() {
        XCTAssertTrue(BatchDeleteSheet.summary(total: 3, repeating: 0).contains("连同任务定义"))
        XCTAssertTrue(BatchDeleteSheet.summary(total: 2, repeating: 2).contains("只删除这一次"))
        XCTAssertTrue(BatchDeleteSheet.summary(total: 5, repeating: 2).contains("其余 3 项"))
    }
}
