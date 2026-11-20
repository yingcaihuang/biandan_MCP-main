import Foundation

extension AppModel {
    /// 补记专注；成功后选中新记录。
    @discardableResult
    func createFocus(_ input: FocusInput) async -> Bool {
        let ok = await performChange("补记专注") { try await $0.createFocus(input).1 }
        if ok {
            selectedOccurrenceID = nil
            selectedFocusID = FocusCodec.identifier(startedAt: input.startedAt)
        }
        return ok
    }

    @discardableResult
    func updateFocus(_ focusID: String, title: String?, goodCount: Int?, badCount: Int?) async -> Bool {
        await performChange("保存专注记录") {
            try await $0.updateFocus(focusID, title: title, goodCount: goodCount, badCount: badCount)
        }
    }

    @discardableResult
    func deleteFocus(_ focusID: String) async -> Bool {
        let ok = await performChange("删除专注记录") { try await $0.deleteFocus(focusID) }
        if ok, selectedFocusID == focusID { selectedFocusID = nil }
        return ok
    }
}
