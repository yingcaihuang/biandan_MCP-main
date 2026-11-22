import XCTest
@testable import BiandanMac

/// 整张精确识别为空时的分条识别：分条、坐标换算、去重。
final class TextRecognizerStripTests: XCTestCase {
    func testStrips() {
        let strips = TextRecognizer.strips(height: 2020)
        XCTAssertEqual(strips.count, 4)
        XCTAssertEqual(strips.first?.top, 0)
        XCTAssertEqual(strips.first?.owned, 0..<505)
        XCTAssertEqual(strips[1].top, 425)
        XCTAssertEqual(strips.last?.owned.upperBound, 2020)
        XCTAssertEqual(strips.last.map { $0.top + $0.height }, 2020)
        // 负责范围首尾相接，覆盖整张图。
        for (a, b) in zip(strips, strips.dropFirst()) { XCTAssertEqual(a.owned.upperBound, b.owned.lowerBound) }
        XCTAssertEqual(TextRecognizer.strips(height: 300).count, 1)
    }

    func testMapBox() {
        // 2000 高的图，第一条从第 0 行起、高 500：条内最上面的框，换算后也在整张图最上面。
        let strip = TextRecognizer.Strip(top: 0, height: 500, owned: 0..<500)
        let box = TextRecognizer.mapBox(CGRect(x: 0.5, y: 0.8, width: 0.2, height: 0.1), strip: strip, imageHeight: 2000)
        XCTAssertEqual(box.minX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(box.minY, 0.75 + 0.8 * 0.25, accuracy: 0.0001)
        XCTAssertEqual(box.height, 0.025, accuracy: 0.0001)
        XCTAssertEqual(TextRecognizer.centerRow(box, imageHeight: 2000), 75)
        let last = TextRecognizer.Strip(top: 1500, height: 500, owned: 1500..<2000)
        let bottom = TextRecognizer.mapBox(CGRect(x: 0, y: 0, width: 1, height: 0.2), strip: last, imageHeight: 2000)
        XCTAssertEqual(bottom.minY, 0, accuracy: 0.0001)
        XCTAssertEqual(TextRecognizer.centerRow(bottom, imageHeight: 2000), 1950)
    }
}
