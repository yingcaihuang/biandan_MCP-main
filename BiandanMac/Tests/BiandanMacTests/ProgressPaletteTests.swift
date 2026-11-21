import AppKit
import SwiftUI
import XCTest
@testable import BiandanMac

final class ProgressPaletteTests: XCTestCase {
    private func assertRGB(_ ratio: Double, _ hex: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        let got = ProgressPalette.components(at: ratio), want = ProgressPalette.rgb(hex)
        XCTAssertEqual(got.r, want.r, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(got.g, want.g, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(got.b, want.b, accuracy: 0.002, file: file, line: line)
    }

    func testEndpointsAndStops() {
        assertRGB(0, 0xD93025)
        assertRGB(1, 0x43A047)
        assertRGB(0.30, 0xF08A24)
        assertRGB(0.60, 0xF2C511)
        // 越界、非数字按端点处理。
        assertRGB(-1, 0xD93025)
        assertRGB(3, 0x43A047)
        assertRGB(.nan, 0xD93025)
    }

    func testInterpolatesBetweenStops() {
        let mid = ProgressPalette.components(at: 0.375)
        let a = ProgressPalette.rgb(0xF08A24), b = ProgressPalette.rgb(0xF5A800)
        XCTAssertEqual(mid.g, (a.g + b.g) / 2, accuracy: 0.002)
        // 从红到绿：绿色分量整体上升，红色分量在后半段下降。
        XCTAssertLessThan(ProgressPalette.components(at: 0.1).g, ProgressPalette.components(at: 0.6).g)
        XCTAssertGreaterThan(ProgressPalette.components(at: 0.6).r, ProgressPalette.components(at: 1).r)
    }

    /// 渲染 0%–100% 的圆环到 /tmp/biandan-progress-rings.png，用于检查外观。
    @MainActor
    func testRenderRings() throws {
        let samples = [(0, 4), (1, 10), (1, 5), (1, 3), (2, 5), (1, 2), (3, 5), (3, 4), (9, 10), (4, 4)]
        let row = HStack(spacing: 14) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                SummaryProgressRing(progress: TodayProgress(done: sample.0, total: sample.1), label: "今天")
            }
        }
        .padding(16)
        .background(Theme.card)
        let renderer = ImageRenderer(content: row.environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "渲染失败")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/biandan-progress-rings.png"))
    }
}
