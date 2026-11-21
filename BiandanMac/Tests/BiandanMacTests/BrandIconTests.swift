import AppKit
import XCTest
@testable import BiandanMac

final class BrandIconTests: XCTestCase {
    func testIconDecodes() throws {
        XCTAssertGreaterThan(BrandIcon.pngData.count, 1000)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: BrandIcon.pngData))
        XCTAssertEqual(rep.pixelsWide, 512)
        XCTAssertEqual(rep.pixelsHigh, 512)
        XCTAssertNotNil(BrandIcon.image)
    }

    func testCallbackPageEmbedsLocalIcon() {
        let html = AuthCallbackPage.html(.notFound)
        XCTAssertTrue(html.contains("<img class=\"logo\" src=\"data:image/png;base64,"))
        XCTAssertFalse(html.contains("biandangroup.com"), "回调页不应引用远程图片")
    }
}
