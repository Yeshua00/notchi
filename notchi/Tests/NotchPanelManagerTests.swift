import AppKit
import XCTest
@testable import notchi

@MainActor
final class NotchPanelManagerTests: XCTestCase {
    private final class SessionCountBox {
        var value: Int

        init(_ value: Int) {
            self.value = value
        }
    }

    private var defaultsSuiteNames: [String] = []

    override func tearDown() {
        for suiteName in defaultsSuiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        defaultsSuiteNames.removeAll()
        super.tearDown()
    }

    func testMinimizeWhenIdleOffKeepsNormalCollapsedWithNoSessions() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettings.minimizeWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)

        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.notchRect.width, accuracy: 0.5)
    }

    func testMinimizeWhenIdleOnWithNoSessionsEntersCompactIdle() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.minimizeWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)

        XCTAssertEqual(manager.collapsedMode, .compactIdle)
        XCTAssertEqual(manager.compactNotchRect.width, manager.notchSize.width + 16, accuracy: 0.5)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.compactNotchRect.width, accuracy: 0.5)
    }

    func testFirstSessionStartExitsCompactIdle() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.minimizeWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)

        sessionCount.value = 1
        manager.refreshIdleMode()

        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.notchRect.width, accuracy: 0.5)
    }

    func testLastSessionEndReturnsToCompactIdleWhenCollapsed() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.minimizeWhenIdleKey)
        let sessionCount = SessionCountBox(1)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)

        sessionCount.value = 0
        manager.refreshIdleMode()

        XCTAssertEqual(manager.collapsedMode, .compactIdle)
    }

    func testLastSessionEndWhileExpandedLeavesPanelOpenUntilCollapse() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.minimizeWhenIdleKey)
        let sessionCount = SessionCountBox(1)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        manager.expand()
        XCTAssertTrue(manager.isExpanded)

        sessionCount.value = 0
        manager.refreshIdleMode()

        XCTAssertTrue(manager.isExpanded)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)

        manager.collapse()

        XCTAssertFalse(manager.isExpanded)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)
    }

    func testCompactHoverEntersPreviewImmediatelyAndReturnsAfterDelay() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.minimizeWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(
            sessionCount: sessionCount,
            defaults: defaults,
            hoverExitDelay: .milliseconds(10)
        )

        configureGeometry(for: manager)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)

        manager.handleCollapsedHoverEntered()
        XCTAssertEqual(manager.collapsedMode, .compactHoverPreview)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.notchRect.width, accuracy: 0.5)

        manager.handleCollapsedHoverExited()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(manager.collapsedMode, .compactIdle)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.compactNotchRect.width, accuracy: 0.5)
    }

    func testMouseMovementOutsideCompactIdleDoesNotEnterPreview() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.minimizeWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)

        manager.handleMouseLocationChanged(CGPoint(x: 0, y: 0))

        XCTAssertEqual(manager.collapsedMode, .compactIdle)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.compactNotchRect.width, accuracy: 0.5)
    }

    func testDisablingMinimizeWhenIdleFromHoverPreviewReturnsToNormalCollapsed() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.minimizeWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        manager.handleCollapsedHoverEntered()
        XCTAssertEqual(manager.collapsedMode, .compactHoverPreview)

        defaults.set(false, forKey: AppSettings.minimizeWhenIdleKey)
        manager.refreshIdleMode()

        XCTAssertEqual(manager.collapsedMode, .normalCollapsed)
        XCTAssertEqual(manager.activeCollapsedRect.width, manager.notchRect.width, accuracy: 0.5)
    }

    func testExpandFromCompactHoverPreviewKeepsPanelOpenAndReturnsToCompactIdleOnCollapse() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettings.minimizeWhenIdleKey)
        let sessionCount = SessionCountBox(0)
        let manager = makeManager(sessionCount: sessionCount, defaults: defaults)

        configureGeometry(for: manager)
        manager.handleCollapsedHoverEntered()
        XCTAssertEqual(manager.collapsedMode, .compactHoverPreview)

        manager.expand()

        XCTAssertTrue(manager.isExpanded)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)

        manager.collapse()

        XCTAssertFalse(manager.isExpanded)
        XCTAssertEqual(manager.collapsedMode, .compactIdle)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "NotchPanelManagerTests-\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func configureGeometry(for manager: NotchPanelManager) {
        manager.setGeometryForTesting(
            notchSize: CGSize(width: 224, height: 38),
            notchRect: CGRect(x: 100, y: 0, width: 274, height: 38),
            panelRect: CGRect(x: 40, y: 0, width: 450, height: 450)
        )
    }

    private func makeManager(
        sessionCount: SessionCountBox,
        defaults: UserDefaults,
        hoverExitDelay: Duration = .milliseconds(10)
    ) -> NotchPanelManager {
        NotchPanelManager(
            notificationCenter: NotificationCenter(),
            userDefaults: defaults,
            hoverExitDelay: hoverExitDelay,
            activeSessionCountProvider: { sessionCount.value },
            startEventMonitors: false,
            observeExternalState: false
        )
    }
}
