import XCTest
@testable import BiandanMac

final class TimelineHitTests: XCTestCase {
    private func target(_ id: String, _ x: CGFloat, _ y: CGFloat) -> TimelineHoverTarget {
        TimelineHoverTarget(id: id, point: CGPoint(x: x, y: y), item: nil, rows: [])
    }

    func testNearestWithinRadius() {
        let targets = [target("a", 10, 10), target("b", 40, 10), target("c", 40, 23)]
        XCTAssertEqual(TimelineHit.nearest(targets, to: CGPoint(x: 12, y: 30))?.id, "a", "离圆点 20pt 也能指到")
        XCTAssertEqual(TimelineHit.nearest(targets, to: CGPoint(x: 32, y: 11))?.id, "b")
        XCTAssertEqual(TimelineHit.nearest(targets, to: CGPoint(x: 41, y: 21))?.id, "c", "同一列上下两个点取更近的")
        XCTAssertNil(TimelineHit.nearest(targets, to: CGPoint(x: 100, y: 10)))
        XCTAssertNil(TimelineHit.nearest([], to: .zero))
    }
}
