import XCTest
@testable import BiandanMac

final class OnboardingTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "biandan.test.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testProgressCountsRequiredOnly() {
        XCTAssertEqual(Onboarding.progress([]).total, 5)
        XCTAssertEqual(Onboarding.progress([.firstTask, .ai]).done, 1)
        XCTAssertEqual(Onboarding.progress(Set(ChecklistItem.allCases)).done, 5)
    }

    @MainActor
    func testExistingUserIsAdoptedOnce() {
        let defaults = suite()
        let fresh = Onboarding(defaults: defaults)
        fresh.adoptExistingUser(hasData: false)
        XCTAssertFalse(fresh.welcomeSeen)
        fresh.adoptExistingUser(hasData: true)
        XCTAssertTrue(fresh.welcomeSeen)
        XCTAssertTrue(fresh.tourSeen)
        XCTAssertTrue(fresh.checklistHidden)
        let reloaded = Onboarding(defaults: defaults)
        XCTAssertTrue(reloaded.welcomeSeen)
        XCTAssertTrue(reloaded.tourSeen)
    }

    @MainActor
    func testResetStartsOverAndIsNotReadopted() {
        let defaults = suite()
        let onboarding = Onboarding(defaults: defaults)
        onboarding.adoptExistingUser(hasData: true)
        onboarding.mark(.quadrant)
        onboarding.resetAll()
        XCTAssertFalse(onboarding.welcomeSeen)
        XCTAssertFalse(onboarding.checklistHidden)
        onboarding.adoptExistingUser(hasData: true)
        XCTAssertFalse(onboarding.welcomeSeen)
        let reloaded = Onboarding(defaults: defaults)
        XCTAssertFalse(reloaded.tourSeen)
        XCTAssertFalse(reloaded.marked.contains(ChecklistItem.quadrant.rawValue))
    }

    @MainActor
    func testMarksPersist() {
        let defaults = suite()
        Onboarding(defaults: defaults).mark(.capture)
        XCTAssertTrue(Onboarding(defaults: defaults).marked.contains(ChecklistItem.capture.rawValue))
    }

    func testLocalConversion() {
        let frame = CGRect(x: 100, y: 200, width: 1000, height: 700)
        let screen = CGRect(x: 150, y: 800, width: 80, height: 30)
        XCTAssertEqual(TourLayout.local(screen, in: frame), CGRect(x: 50, y: 70, width: 80, height: 30))
    }

    @MainActor
    func testActionStepsHavePromptsAndTargets() {
        for step in Onboarding.tourSteps where step.action != nil {
            XCTAssertNotNil(step.prompt, step.title)
            XCTAssertNotNil(step.target, step.title)
        }
        XCTAssertEqual(Onboarding.tourSteps.map(\.id), Array(0..<Onboarding.tourSteps.count))
    }

    func testCardStaysInsideWhenTargetIsOutside() {
        // 浮窗球在主窗口右边外面：卡片贴着窗口右边，不超出去。
        let origin = TourLayout.cardOrigin(hole: CGRect(x: 1010, y: 300, width: 50, height: 50),
                                           card: CGSize(width: 340, height: 200), in: CGSize(width: 1000, height: 700))
        XCTAssertEqual(origin.x, 648)
    }

    @MainActor
    func testFloatingBallStepAsksForCapture() {
        let last = Onboarding.tourSteps.last
        XCTAssertEqual(last?.target, .floatingBall)
        XCTAssertEqual(last?.action, .capture)
    }

    func testCardPlacement() {
        let container = CGSize(width: 1000, height: 700)
        let card = CGSize(width: 340, height: 200)
        // 右边放得下：放右边，竖直居中对齐目标。
        let right = TourLayout.cardOrigin(hole: CGRect(x: 10, y: 100, width: 200, height: 400), card: card, in: container)
        XCTAssertEqual(right, CGPoint(x: 226, y: 200))
        // 右边放不下：放左边。
        let left = TourLayout.cardOrigin(hole: CGRect(x: 700, y: 100, width: 250, height: 100), card: card, in: container)
        XCTAssertEqual(left.x, 344)
        // 左右都放不下：放下面。
        let below = TourLayout.cardOrigin(hole: CGRect(x: 0, y: 50, width: 1000, height: 100), card: card, in: container)
        XCTAssertEqual(below, CGPoint(x: 330, y: 166))
        // 没有目标：居中。
        XCTAssertEqual(TourLayout.cardOrigin(hole: nil, card: card, in: container), CGPoint(x: 330, y: 250))
    }
}
