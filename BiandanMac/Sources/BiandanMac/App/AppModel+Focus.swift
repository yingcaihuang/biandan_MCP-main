import Foundation

extension AppModel {
    /// 补记专注；成功后选中新记录。
    @discardableResult
    func createFocus(_ input: FocusInput) async -> Bool {
        let ok = await performQueued("补记专注", .createFocus(input))
        if ok {
            selectedOccurrenceID = nil
            selectedFocusID = FocusCodec.identifier(startedAt: input.startedAt)
        }
        return ok
    }

    @discardableResult
    func updateFocus(_ focusID: String, title: String?, goodCount: Int?, badCount: Int?) async -> Bool {
        await performQueued("保存专注记录",
                            .updateFocus(id: focusID, title: title, goodCount: goodCount, badCount: badCount))
    }

    @discardableResult
    func deleteFocus(_ focusID: String) async -> Bool {
        let ok = await performQueued("删除专注记录", .deleteFocus(id: focusID))
        if ok, selectedFocusID == focusID { selectedFocusID = nil }
        return ok
    }
}
