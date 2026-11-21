import SwiftUI

/// 内容区底部只在写入失败时出现，8 秒后自动消失。
/// 后台写入的进度只在侧栏底部的同步状态里小字显示。
struct OperationBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let notice = model.conflictNotice {
                ConflictNoticeCard(notice: notice)
            }
            if let error = model.operationError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.overdue)
                    Text(error)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        model.operationError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(12)
                .frame(maxWidth: 560)
                .floatingSurface(RoundedRectangle(cornerRadius: 10), border: Theme.overdue.opacity(0.5),
                                 glassTint: Theme.overdue.opacity(0.08), glassBorder: true)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 16)
        .animation(.easeInOut(duration: 0.2), value: model.operationError)
        .animation(.easeInOut(duration: 0.2), value: model.conflictNotice)
        .task(id: model.conflictNotice) {
            guard let current = model.conflictNotice else { return }
            try? await Task.sleep(for: .seconds(15))
            if model.conflictNotice == current { model.conflictNotice = nil }
        }
        .task(id: model.operationError) {
            guard let current = model.operationError else { return }
            try? await Task.sleep(for: .seconds(8))
            if model.operationError == current { model.operationError = nil }
        }
    }
}
