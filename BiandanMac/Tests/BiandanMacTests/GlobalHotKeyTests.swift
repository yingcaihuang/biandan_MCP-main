import Carbon.HIToolbox
import XCTest
@testable import BiandanMac

final class GlobalHotKeyTests: XCTestCase {
    func testCombos() {
        XCTAssertEqual(QuickAddHotKey.controlOptionN.keyCode, UInt32(kVK_ANSI_N))
        XCTAssertEqual(QuickAddHotKey.controlOptionN.modifiers, UInt32(controlKey | optionKey))
        XCTAssertEqual(QuickAddHotKey.commandOptionN.modifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(QuickAddHotKey.controlShiftSpace.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(QuickAddHotKey.controlShiftSpace.modifiers, UInt32(controlKey | shiftKey))
        XCTAssertNil(QuickAddHotKey.off.keyCode)
    }

    func testStatusText() {
        XCTAssertNil(QuickAddHotKey.statusText(noErr))
        XCTAssertTrue(QuickAddHotKey.statusText(OSStatus(eventHotKeyExistsErr))?.contains("占用") == true)
        XCTAssertNotNil(QuickAddHotKey.statusText(-50))
    }
}
