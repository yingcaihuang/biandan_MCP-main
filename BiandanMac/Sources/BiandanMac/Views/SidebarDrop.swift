import SwiftUI

extension View {
    /// 侧栏行接收拖来的任务卡片；拖的卡片在多选里时整批处理。
    @ViewBuilder
    func sidebarDrop(_ target: SidebarItem, model: AppModel) -> some View {
        if target.acceptsDrop {
            dropDestination(for: String.self) { identifiers, _ in
                guard !identifiers.isEmpty else { return false }
                Task { await model.dropOnSidebar(identifiers, target) }
                return true
            }
            .help(target.dropHelp ?? "")
        } else {
            self
        }
    }
}
