import XCTest
@testable import BiandanMac

final class CheckboxTintTests: XCTestCase {
    func testUsesListColorWhenEnabled() {
        let purple = ListColor(sortIndex: 2, colorIndex: 8)
        XCTAssertEqual(CheckboxTint.hex(listColor: purple, enabled: true), ListColor.palette[8])
    }

    func testKeepsOriginalStyle() {
        let purple = ListColor(sortIndex: 2, colorIndex: 8)
        XCTAssertNil(CheckboxTint.hex(listColor: purple, enabled: false))
        XCTAssertNil(CheckboxTint.hex(listColor: ListColor(sortIndex: 0, colorIndex: 0), enabled: true))
        XCTAssertNil(CheckboxTint.hex(listColor: nil, enabled: true))
        XCTAssertNil(CheckboxTint.hex(listColor: ListColor(sortIndex: 0, colorIndex: 99), enabled: true))
    }
}
