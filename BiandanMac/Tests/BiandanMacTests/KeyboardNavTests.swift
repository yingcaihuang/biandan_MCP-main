import XCTest
@testable import BiandanMac

final class KeyboardNavTests: XCTestCase {
    private let order = ["a", "b", "c", "d"]

    func testStep() {
        XCTAssertEqual(KeyboardNav.step(order, current: nil, delta: 1), "a")
        XCTAssertEqual(KeyboardNav.step(order, current: nil, delta: -1), "d")
        XCTAssertEqual(KeyboardNav.step(order, current: "x", delta: 1), "a", "不在当前视图里的选中项从头开始")
        XCTAssertEqual(KeyboardNav.step(order, current: "b", delta: 1), "c")
        XCTAssertEqual(KeyboardNav.step(order, current: "b", delta: -1), "a")
        XCTAssertEqual(KeyboardNav.step(order, current: "d", delta: 1), "d", "到底后停住")
        XCTAssertEqual(KeyboardNav.step(order, current: "a", delta: -1), "a", "到顶后停住")
        XCTAssertNil(KeyboardNav.step([], current: "a", delta: 1))
    }

    func testRange() {
        XCTAssertEqual(KeyboardNav.range(order, from: "b", to: "d"), ["b", "c", "d"])
        XCTAssertEqual(KeyboardNav.range(order, from: "d", to: "b"), ["b", "c", "d"])
        XCTAssertEqual(KeyboardNav.range(order, from: "c", to: "c"), ["c"])
        XCTAssertEqual(KeyboardNav.range(order, from: "x", to: "c"), ["c"])
        XCTAssertEqual(KeyboardNav.range(order, from: "a", to: "x"), ["a"])
        XCTAssertEqual(KeyboardNav.range(order, from: "x", to: "y"), [])
    }
}
