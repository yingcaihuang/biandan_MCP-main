import AppKit
import SwiftUI
import XCTest
@testable import BiandanMac

/// 把日期、时刻面板渲染成 PNG（/tmp/biandan-*-panel.png），用于检查外观。
@MainActor
final class PickerRenderTests: XCTestCase {
    private func render<V: View>(_ view: V, to path: String) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "渲染失败")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }

    func testRenderPanels() throws {
        let today = LocalDate(iso: "2026-11-20")!
        try render(ThemedCalendarPanel(selection: LocalDate(iso: "2026-11-24")!, minimum: today, today: today,
                                       weekStart: 1, tint: Quadrant.neither.tint) { _ in },
                   to: "/tmp/biandan-calendar-panel.png")
        try render(ThemedCalendarPanel(selection: LocalDate(iso: "2026-10-01")!, minimum: nil, today: today,
                                       weekStart: 0, tint: Quadrant.importantUrgent.tint) { _ in },
                   to: "/tmp/biandan-calendar-holiday-panel.png")
        try render(ThemedTimePanel(initial: LocalTime(hour: 14, minute: 30)!, tint: Quadrant.neither.tint,
                                   onChange: { _ in }, onDone: {}),
                   to: "/tmp/biandan-time-panel.png")
    }
}
