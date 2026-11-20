import AppKit
import SwiftUI
import XCTest
@testable import BiandanMac

/// 把右键面板的布局渲染成 PNG（/tmp/biandan-context-menu.png），用于检查外观和高度。
/// 结构与 OccurrenceContextMenu 一致（该视图依赖 AppModel，这里用同样的组件拼出来）。
@MainActor
final class MenuRenderTests: XCTestCase {
    func testRenderContextMenu() throws {
        let panel = ThemedMenuPanel(title: "参加 Cloud Flare 的年会。", subtitle: "11/27", tint: Quadrant.neither.tint) {
            ThemedMenuGroup {
                ThemedMenuRow(icon: "checkmark", title: "完成本次", tint: Theme.done) {}
                ThemedMenuSeparator()
                ThemedMenuRow(icon: "slash.circle", title: "放弃本次", tint: Theme.subtext) {}
            }
            VStack(alignment: .leading, spacing: 6) {
                ThemedMenuCaption("改期")
                HStack(spacing: 6) {
                    ThemedMenuChip(title: "今天") {}
                    ThemedMenuChip(title: "明天") {}
                    ThemedMenuChip(title: "下周一") {}
                    ThemedMenuChip(title: "无日期", tint: Theme.subtext) {}
                }
            }
            ThemedMenuCaption("移到象限")
            QuadrantMiniGrid(current: .neither) { _ in }
            VStack(alignment: .leading, spacing: 8) {
                ThemedMenuCaption("移到待办单")
                ThemedMenuGroup {
                    ThemedMenuListRow(color: ListColor(raw: 0).color, title: "默认", selected: true) {}
                    ThemedMenuSeparator()
                    ThemedMenuRow(icon: "plus", title: "新建待办单…", tint: Theme.accent) {}
                }
            }
            HStack(spacing: 0) {
                ThemedMenuIconButton(icon: "star", title: "收藏", tint: Theme.accent) {}
                ThemedMenuIconButton(icon: "repeat", title: "设为重复", tint: Quadrant.notImportantUrgent.tint) {}
                ThemedMenuIconButton(icon: "doc.on.doc", title: "复制标题", tint: Theme.subtext) {}
                ThemedMenuIconButton(icon: "trash", title: "删除", tint: Theme.overdue, destructive: true) {}
            }
            .themedCard()
        }
        let renderer = ImageRenderer(content: panel.environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "渲染失败")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/biandan-context-menu.png"))
        print("MENU_SIZE \(image.size)")
    }

    func testNextMonday() {
        // 2026-11-20 是周五 → 11-23；周一 11-23 → 11-30；周日 11-22 → 11-23。
        XCTAssertEqual(OccurrenceContextMenu.nextMonday(after: LocalDate(iso: "2026-11-20")!).iso, "2026-11-23")
        XCTAssertEqual(OccurrenceContextMenu.nextMonday(after: LocalDate(iso: "2026-11-23")!).iso, "2026-11-30")
        XCTAssertEqual(OccurrenceContextMenu.nextMonday(after: LocalDate(iso: "2026-11-22")!).iso, "2026-11-23")
    }
}
