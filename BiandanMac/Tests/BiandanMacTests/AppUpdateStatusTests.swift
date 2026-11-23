import Foundation
import XCTest
@testable import BiandanMac

final class AppUpdateStatusTests: XCTestCase {
    func testToolbarTitles() {
        let now = Date()
        XCTAssertNil(AppUpdateStatus.idle.toolbarTitle(at: now))
        XCTAssertNil(AppUpdateStatus.checking.toolbarTitle(at: now))
        XCTAssertNil(AppUpdateStatus.failed("x").toolbarTitle(at: now))
        XCTAssertEqual(AppUpdateStatus.found("1.3.2").toolbarTitle(at: now), "发现新版本 1.3.2")
        XCTAssertEqual(AppUpdateStatus.downloading(version: "1.3.2", received: 0, expected: 0).toolbarTitle(at: now), "下载中…")
        XCTAssertEqual(AppUpdateStatus.downloading(version: "1.3.2", received: 429, expected: 1000).toolbarTitle(at: now), "下载中 42%")
        XCTAssertEqual(AppUpdateStatus.downloadFailed("x").toolbarTitle(at: now), "下载异常")
        XCTAssertEqual(AppUpdateStatus.waiting(version: "1.3.2", reason: "番茄钟结束").toolbarTitle(at: now), "番茄钟结束后安装")
    }

    func testDownloadFraction() {
        XCTAssertNil(AppUpdateStatus.downloading(version: "1", received: 10, expected: 0).downloadFraction)
        XCTAssertEqual(AppUpdateStatus.downloading(version: "1", received: 250, expected: 1000).downloadFraction ?? 0, 0.25, accuracy: 0.0001)
        // 收到的比预计的多（比如服务器没给准长度）也不超过 100%。
        XCTAssertEqual(AppUpdateStatus.downloading(version: "1", received: 2000, expected: 1000).downloadFraction, 1)
        XCTAssertEqual(AppUpdateStatus.extracting(version: "1", progress: 0.5).ringFraction, 0.5)
        XCTAssertNil(AppUpdateStatus.installing("1").ringFraction)
        XCTAssertTrue(AppUpdateStatus.extracting(version: "1", progress: 0).isDownloading)
        XCTAssertFalse(AppUpdateStatus.found("1").isDownloading)
    }

    func testCountdown() {
        let now = Date()
        let status = AppUpdateStatus.countdown(version: "1.3.2", deadline: now.addingTimeInterval(60))
        XCTAssertEqual(status.secondsLeft(at: now), 60)
        XCTAssertEqual(status.toolbarTitle(at: now), "60 秒后安装")
        XCTAssertEqual(status.secondsLeft(at: now.addingTimeInterval(0.8)), 60)
        XCTAssertEqual(status.secondsLeft(at: now.addingTimeInterval(30)), 30)
        XCTAssertEqual(status.secondsLeft(at: now.addingTimeInterval(90)), 0)
        XCTAssertEqual(status.countdownFraction(at: now.addingTimeInterval(45)), 0.25, accuracy: 0.0001)
        XCTAssertEqual(status.version, "1.3.2")
        XCTAssertNil(AppUpdateStatus.upToDate.version)
    }

    func testStageKeyIgnoresProgress() {
        XCTAssertEqual(AppUpdateStatus.downloading(version: "1", received: 1, expected: 9).stageKey,
                       AppUpdateStatus.downloading(version: "1", received: 5, expected: 9).stageKey)
        XCTAssertNotEqual(AppUpdateStatus.found("1").stageKey, AppUpdateStatus.downloadFailed("x").stageKey)
    }
}
