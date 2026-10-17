import XCTest
import KeyboardShortcuts
@testable import Core
@testable import OpenClip

@MainActor
final class StatusBarControllerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { TestIsolation.reset() }
    }

    override func tearDown() async throws {
        await MainActor.run { TestIsolation.reset() }
        try await super.tearDown()
    }

    func testStartsWithoutStatusItemWhenPreferenceIsDisabled() {
        let store = MemorySettingsStore()
        store.set(.showMenuBarIcon, value: false)
        let notificationCenter = NotificationCenter()
        let controller = StatusBarController(
            settingsStore: store,
            notificationCenter: notificationCenter
        )

        XCTAssertFalse(controller.isMenuBarIconVisible)
    }

    func testCaptureTextMenuItemShowsConfiguredShortcutAndIsGroupedAboveSettings() {
        let controller = StatusBarController(
            settingsStore: MemorySettingsStore(),
            notificationCenter: NotificationCenter()
        )
        guard let captureItem = controller.captureTextMenuItem,
              let settingsItem = controller.settingsMenuItem,
              let items = controller.rootMenu?.items else {
            return XCTFail("Expected the status menu navigation items")
        }

        XCTAssertEqual(captureItem.title, "Capture Text")
        XCTAssertLessThan(items.firstIndex(of: captureItem)!, items.firstIndex(of: settingsItem)!)

        let savedShortcut = KeyboardShortcuts.getShortcut(for: .captureText)
        defer { KeyboardShortcuts.setShortcut(savedShortcut, for: .captureText) }

        KeyboardShortcuts.setShortcut(.init(.x, modifiers: [.command, .option]), for: .captureText)
        XCTAssertEqual(captureItem.keyEquivalent, "x")
        XCTAssertEqual(captureItem.keyEquivalentModifierMask, [.command, .option])

        KeyboardShortcuts.setShortcut(nil, for: .captureText)
        XCTAssertEqual(captureItem.keyEquivalent, "")
    }

    func testVisibilityNotificationRemovesAndRecreatesStatusItem() {
        let store = MemorySettingsStore()
        let notificationCenter = NotificationCenter()
        let controller = StatusBarController(
            settingsStore: store,
            notificationCenter: notificationCenter
        )

        XCTAssertTrue(controller.isMenuBarIconVisible)

        store.set(.showMenuBarIcon, value: false)
        notificationCenter.post(name: .openClipMenuBarVisibilityChanged, object: false)
        XCTAssertFalse(controller.isMenuBarIconVisible)

        store.set(.showMenuBarIcon, value: true)
        notificationCenter.post(name: .openClipMenuBarVisibilityChanged, object: true)
        XCTAssertTrue(controller.isMenuBarIconVisible)

        store.set(.showMenuBarIcon, value: false)
        notificationCenter.post(name: .openClipMenuBarVisibilityChanged, object: false)
    }
}
