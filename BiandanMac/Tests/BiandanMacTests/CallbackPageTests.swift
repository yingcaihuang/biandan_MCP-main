import XCTest
@testable import BiandanMac

final class CallbackPageTests: XCTestCase {
    /// 静态回调页：完整 HTML、无脚本。
    func testStaticPages() throws {
        for kind in AuthCallbackPage.Kind.allCases {
            let html = AuthCallbackPage.html(kind)
            XCTAssertTrue(html.hasPrefix("<!doctype html>"), "\(kind)")
            XCTAssertTrue(html.contains("class=\"logo\""), "\(kind)")
            XCTAssertFalse(html.lowercased().contains("<script"), "\(kind)")
            XCTAssertFalse(html.contains("\\("), "\(kind) 有未展开的插值")
            try html.write(toFile: "/tmp/biandan-callback-\(kind).html", atomically: true, encoding: .utf8)
        }
    }

    /// 进度页：各阶段渲染、带 nonce 脚本；结束状态不会被迟到的进度覆盖。
    func testProgressPages() throws {
        let progress = LoginProgress()
        var pages: [(String, LoginProgress.Snapshot)] = [("exchanging", progress.snapshot)]
        progress.update(.syncing, detail: "正在同步执行实例… 120")
        pages.append(("syncing", progress.snapshot))
        progress.update(.done, detail: "同步完成",
                        counts: LoginProgress.Counts(lists: 2, tasks: 4, occurrences: 4, focus: 0))
        pages.append(("done", progress.snapshot))
        progress.update(.syncing, detail: "迟到的进度")
        XCTAssertEqual(progress.snapshot.phase, .done)

        let failing = LoginProgress()
        failing.update(.syncing, detail: "正在同步任务…")
        failing.update(.failed, detail: "首次同步没有完成", error: "GET 失败，HTTP 503")
        XCTAssertEqual(failing.snapshot.failedStep, 4)
        pages.append(("failed", failing.snapshot))

        for (name, snapshot) in pages {
            let html = AuthCallbackPage.progressHTML(snapshot, session: "SESSION", nonce: "NONCE")
            XCTAssertTrue(html.contains("<script nonce=\"NONCE\">"), name)
            XCTAssertTrue(html.contains("/biandan/status?s="), name)
            XCTAssertFalse(html.contains("\\("), "\(name) 有未展开的插值")
            try html.write(toFile: "/tmp/biandan-callback-\(name).html", atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(AuthCallbackPage.progressHTML(pages[2].1, session: nil, nonce: nil).contains("共 2 个分类"))
        XCTAssertTrue(AuthCallbackPage.progressHTML(pages[3].1, session: nil, nonce: nil).contains("HTTP 503"))

        let json = try JSONSerialization.jsonObject(with: failing.json()) as? [String: Any]
        XCTAssertEqual(json?["phase"] as? String, "failed")
        XCTAssertEqual(json?["failedStep"] as? Int, 4)

        let early = LoginProgress()
        early.update(.failed, detail: "登录没有完成", error: "x")
        XCTAssertEqual(early.snapshot.failedStep, 3)
    }

    func testErrorTextIsEscaped() {
        let progress = LoginProgress()
        progress.update(.failed, detail: "x", error: "<b>&</b>")
        let html = AuthCallbackPage.progressHTML(progress.snapshot, session: nil, nonce: nil)
        XCTAssertFalse(html.contains("<b>&</b>"))
        XCTAssertTrue(html.contains("&lt;b&gt;&amp;&lt;/b&gt;"))
    }
}
