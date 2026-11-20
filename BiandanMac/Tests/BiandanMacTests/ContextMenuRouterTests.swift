import AppKit
import XCTest
@testable import BiandanMac

/// 右键路由：取鼠标所在、可见、面积最小的区域；没有区域或没有窗口时交回系统。
@MainActor
final class ContextMenuRouterTests: XCTestCase {
    func testSmallestVisibleRegionWins() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = container

        let cell = CatcherView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let card = CatcherView(frame: NSRect(x: 50, y: 50, width: 100, height: 60))
        container.addSubview(cell)
        container.addSubview(card)

        var hit: [String] = []
        var cardPoint = CGPoint.zero
        cell.onRightClick = { _, _ in hit.append("cell") }
        card.onRightClick = { point, _ in hit.append("card"); cardPoint = point }

        // 卡片内：卡片优先（窗口坐标左下角原点）。
        XCTAssertTrue(ContextMenuRouter.route(window: window, location: NSPoint(x: 80, y: 70)))
        XCTAssertEqual(hit, ["card"])
        XCTAssertEqual(cardPoint.x, 30, accuracy: 0.5)
        XCTAssertEqual(cardPoint.y, 40, accuracy: 0.5, "CatcherView 是翻转坐标，y 从顶部算起")

        // 卡片外：落到象限。
        XCTAssertTrue(ContextMenuRouter.route(window: window, location: NSPoint(x: 300, y: 300)))
        XCTAssertEqual(hit.last, "cell")

        // 卡片隐藏后：落到象限。
        card.isHidden = true
        ContextMenuRouter.route(window: window, location: NSPoint(x: 80, y: 70))
        XCTAssertEqual(hit.last, "cell")

        // 没有窗口、或窗口里没有登记区域：不处理，交回系统。
        XCTAssertFalse(ContextMenuRouter.route(window: nil, location: NSPoint(x: 80, y: 70)))
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        XCTAssertFalse(ContextMenuRouter.route(window: other, location: NSPoint(x: 10, y: 10)))
    }

    func testCatcherNeverHitTests() {
        let view = CatcherView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)), "左键、拖动必须穿透到 SwiftUI 内容")
    }
}
