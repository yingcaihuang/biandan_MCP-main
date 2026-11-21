import SwiftUI

/// 鼠标移上去稍停就弹出、移开（离开锚点和浮层）后收起的浮层；点锚点也可以开关。
/// 浮层里可以点按钮：从锚点移到浮层上时不会收起。背景用主题卡片色。
struct HoverPopoverModifier<Popup: View>: ViewModifier {
    let arrowEdge: Edge
    let popup: (@escaping () -> Void) -> Popup
    @State private var shown = false
    @State private var overAnchor = false
    @State private var overPopup = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                overAnchor = inside
                schedule()
            }
            .onTapGesture {
                pending?.cancel()
                shown.toggle()
            }
            .popover(isPresented: $shown, arrowEdge: arrowEdge) {
                popup { shown = false }
                    .onHover { inside in
                        overPopup = inside
                        schedule()
                    }
                    .presentationBackground(Theme.card)
            }
    }

    private func schedule() {
        pending?.cancel()
        let want = overAnchor || overPopup
        guard want != shown else { return }
        let delay = want ? 220 : 300
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            if (overAnchor || overPopup) == want { shown = want }
        }
    }
}

extension View {
    func hoverPopover<Popup: View>(arrowEdge: Edge = .bottom,
                                   @ViewBuilder _ popup: @escaping (@escaping () -> Void) -> Popup) -> some View {
        modifier(HoverPopoverModifier(arrowEdge: arrowEdge, popup: popup))
    }
}
