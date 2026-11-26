import AppKit
import os

// MARK: - 系统「服务」菜单：用便单识别日程
//
// 在任何 App 里选中文字（或图片）→ 右键 → 服务 →「用便单识别日程」，交给和浮窗球同一套识别流程，弹出确认卡片。
// Info.plist 里的 NSServices 由 Tools/build_app.sh 写入（NSMessage = captureSchedule），启动时把这个对象设为
// NSApp.servicesProvider。便单没开时系统会先把它拉起，这里等读完登录状态再识别。

final class ScheduleServiceProvider: NSObject {
    static let shared = ScheduleServiceProvider()
    static let logger = Logger(subsystem: "ai.racore.BiandanMac", category: "service")

    /// 选择器 captureSchedule:userData:error:，对应 Info.plist 里的 NSMessage。
    @objc func captureSchedule(_ pasteboard: NSPasteboard, userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        MainActor.assumeIsolated {
            let image = text.isEmpty ? ScheduleCaptureFlow.image(from: pasteboard) : nil
            guard !text.isEmpty || image != nil else {
                error.pointee = "选中的内容里没有文字或图片。"
                return
            }
            Self.logger.info("服务菜单识别日程：\(image == nil ? "文字" : "图片", privacy: .public)")
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                guard let model = try? await IntentSupport.model() else {
                    AppModel.current?.operationError = "便单还没登录，登录后再用「服务 → 用便单识别日程」。"
                    AppModel.current?.showMainWindow()
                    return
                }
                if let image {
                    ScheduleCaptureFlow.fromImage(image, model: model, anchor: nil, input: .service)
                } else {
                    ScheduleCaptureFlow.fromText(text, model: model, anchor: nil, input: .service)
                }
            }
        }
    }
}
