import XCTest
@testable import BiandanMac

/// 打开了 AI 决策却没配好时，要说清楚为什么跳过。
final class DecisionReadinessTests: XCTestCase {
    private func settings(enabled: Bool = true, workspace: String = "llm-abc123", key: String? = "sk-test") -> DecisionSettings {
        DecisionSettings(enabled: enabled, workspace: workspace, region: .beijing, sensitivity: .balanced, apiKey: key)
    }

    func testReasons() {
        XCTAssertNil(settings(enabled: false, workspace: "").unavailableReason, "没打开不算跳过")
        XCTAssertEqual(settings(workspace: "  ").unavailableReason, "没填业务空间 ID")
        XCTAssertEqual(settings(key: nil).unavailableReason, "没填 DashScope API Key")
        XCTAssertEqual(settings(key: "").unavailableReason, "没填 DashScope API Key")
        let ready = settings()
        XCTAssertNil(ready.unavailableReason)
        XCTAssertEqual(ready.isReady, ready.unavailableReason == nil)
    }
}
