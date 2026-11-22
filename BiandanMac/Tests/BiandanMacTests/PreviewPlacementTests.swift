import XCTest
@testable import BiandanMac

/// 确认卡片的位置：球在下半屏往上长，在上半屏往下长；任何时候都不越过菜单栏和 Dock。
final class PreviewPlacementTests: XCTestCase {
    /// 1728×1117 的屏幕，Dock 占底部 74，菜单栏 33。
    let area = CGRect(x: 0, y: 74, width: 1728, height: 1010)
    let size = CGSize(width: 520, height: 600)

    func testBallBottomRightGrowsUp() {
        let ball = CGRect(x: 1660, y: 120, width: 56, height: 56)
        XCTAssertTrue(PreviewPlacement.growsUp(anchor: ball, area: area))
        let frame = PreviewPlacement.initialFrame(size: size, anchor: ball, area: area)
        XCTAssertEqual(frame.maxX, ball.minX - PreviewPlacement.gap)
        XCTAssertEqual(frame.minY, ball.minY)
        XCTAssertTrue(area.contains(frame))

        // 识别完内容变高：底边不动，往上长。
        let taller = PreviewPlacement.resized(frame, to: CGSize(width: 520, height: 900), growsUp: true, area: area)
        XCTAssertEqual(taller.minY, ball.minY)
        XCTAssertTrue(area.contains(taller))
    }

    func testBallTopRightGrowsDown() {
        let ball = CGRect(x: 1660, y: 900, width: 56, height: 56)
        XCTAssertFalse(PreviewPlacement.growsUp(anchor: ball, area: area))
        let frame = PreviewPlacement.initialFrame(size: size, anchor: ball, area: area)
        XCTAssertEqual(frame.maxY, ball.maxY)
        let taller = PreviewPlacement.resized(frame, to: CGSize(width: 520, height: 900), growsUp: false, area: area)
        XCTAssertGreaterThanOrEqual(taller.minY, area.minY + PreviewPlacement.margin)
        XCTAssertTrue(area.contains(taller))
    }

    func testNeverTallerThanVisibleArea() {
        let ball = CGRect(x: 1660, y: 120, width: 56, height: 56)
        let frame = PreviewPlacement.initialFrame(size: CGSize(width: 520, height: 3000), anchor: ball, area: area)
        XCTAssertEqual(frame.height, PreviewPlacement.maxHeight(in: area))
        XCTAssertEqual(frame.minY, area.minY + PreviewPlacement.margin)
        XCTAssertEqual(frame.maxY, area.maxY - PreviewPlacement.margin)
        let resized = PreviewPlacement.resized(frame, to: CGSize(width: 520, height: 2000), growsUp: true, area: area)
        XCTAssertTrue(area.contains(resized))
    }

    func testLeftBallPutsCardOnRight() {
        let ball = CGRect(x: 10, y: 100, width: 56, height: 56)
        let frame = PreviewPlacement.initialFrame(size: size, anchor: ball, area: area)
        XCTAssertEqual(frame.minX, ball.maxX + PreviewPlacement.gap)
        XCTAssertTrue(area.contains(frame))
    }

    func testNoBallGrowsDown() {
        XCTAssertFalse(PreviewPlacement.growsUp(anchor: nil, area: area))
        let frame = PreviewPlacement.initialFrame(size: size, anchor: nil, area: area)
        XCTAssertEqual(frame.midX, area.midX, accuracy: 0.5)
        XCTAssertTrue(area.contains(frame))
    }
}
