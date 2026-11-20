import Foundation
import XCTest
@testable import BiandanMac

final class GeoTextTests: XCTestCase {
    func testFormat() {
        XCTAssertEqual(GeoText.format(31.2304), "31.2304")
        XCTAssertEqual(GeoText.format(121.473701234), "121.473701")
        XCTAssertEqual(GeoText.format(30), "30")
        XCTAssertEqual(GeoText.format(-0.5), "-0.5")
    }

    func testCoordinateParsing() {
        let point = GeoText.coordinate(latitude: " 31.2304 ", longitude: "121.4737")
        XCTAssertEqual(point?.latitude, 31.2304)
        XCTAssertEqual(point?.longitude, 121.4737)
        XCTAssertNil(GeoText.coordinate(latitude: "", longitude: "121"))
        XCTAssertNil(GeoText.coordinate(latitude: "91", longitude: "0"))
        XCTAssertNil(GeoText.coordinate(latitude: "0", longitude: "181"))
        XCTAssertNil(GeoText.coordinate(latitude: "-1", longitude: "-1"))
        XCTAssertNil(GeoText.coordinate(latitude: "abc", longitude: "1"))
    }

    func testInitialRegion() {
        let near = GeoText.initialRegion(GeoText.coordinate(latitude: "31", longitude: "121"))
        XCTAssertEqual(near.center.latitude, 31)
        XCTAssertLessThan(near.span.latitudeDelta, 1)
        let country = GeoText.initialRegion(nil)
        XCTAssertGreaterThan(country.span.latitudeDelta, 10)
    }
}
