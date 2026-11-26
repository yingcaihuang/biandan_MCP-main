import XCTest
@testable import BiandanMac

/// 本机数据库文件被删后重新打开；开发版和正式版的数据目录分开。
final class StoreRecoveryTests: XCTestCase {
    func testReopenAfterDelete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("biandan-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("biandan.sqlite")
        let store = try LocalStore(url: url)
        XCTAssertFalse(try store.reopenIfDeleted(), "文件还在，不用重新打开")

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(try store.reopenIfDeleted(), "文件被删，应重新打开")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try store.loadSnapshot().tasks.count, 0)
        XCTAssertFalse(try store.reopenIfDeleted(), "重新打开后文件没再变，不用再开")

        // 删掉后被别的程序新建了同名空文件：inode 变了，也要重新打开
        try FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        XCTAssertTrue(try store.reopenIfDeleted())
        XCTAssertNoThrow(try store.loadSnapshot())
    }

    func testMemoryStoreNeverReopens() throws {
        XCTAssertFalse(try LocalStore().reopenIfDeleted())
    }

    func testFolderName() {
        XCTAssertEqual(AppPaths.folderName(bundleID: "ai.racore.BiandanMac"), "BiandanMac")
        XCTAssertEqual(AppPaths.folderName(bundleID: "ai.racore.BiandanMac.dev"), "BiandanMac.dev")
        XCTAssertEqual(AppPaths.folderName(bundleID: nil), "BiandanMac")
    }
}
