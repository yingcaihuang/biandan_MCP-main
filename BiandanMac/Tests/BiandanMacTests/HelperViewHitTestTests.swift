import AppKit
import XCTest
@testable import BiandanMac

/// 挂在主窗口上的辅助视图都不能接收鼠标点击，否则会盖住分栏，按钮和选择器点不动。
@MainActor
final class HelperViewHitTestTests: XCTestCase {
    func testHelperViewsPassClicksThrough() {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let point = NSPoint(x: 100, y: 100)
        let views: [NSView] = [
            WindowSetupView(frame: frame),
            KeyMonitorView(frame: frame),
            PassThroughView(frame: frame),
            CatcherView(frame: frame),
        ]
        for view in views {
            XCTAssertNil(view.hitTest(point), "\(type(of: view)) 不应接收鼠标点击")
        }
    }
}
