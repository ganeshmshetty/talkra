import XCTest
import AppKit
import KeyboardShortcuts
@testable import OpenClip
@testable import Core

/// Hotkey trigger gating: ⌥⌘C obeys Pause, app exclusion, per-app `disabled` rules and the text
/// length contract. "Appear Automatically" does not gate it.
@MainActor
final class HotkeyManagerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            TestIsolation.reset()
            HotkeyManager.shared.retriever = nil
            HotkeyManager.shared.frontmostPIDProvider = { 1001 }
        }
    }

    override func tearDown() async throws {
        HotkeyManager.shared.frontmostPIDProvider = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        HotkeyManager.shared.retriever = nil
        try await super.tearDown()
    }

    func testPerActionRetrievalRejectsChangedTargetWithoutRequestedPID() async {
        let manager = HotkeyManager.shared
        manager.frontmostPIDProvider = { 2002 }
        let result = await manager.collectTrigger(frontmostApp: MockFrontmostApp(bundleID: "com.apple.TextEdit"))
        XCTAssertNil(result)
    }

    func testPerActionRetrievalRejectsSwitchDuringFreshRetrieval() async {
        let manager = HotkeyManager.shared
        manager.retriever = SelectionRetrievalCoordinator(
            inspect: { _ in AXElementInspector.Target() },
            copyCapture: { _ in
                await MainActor.run { manager.frontmostPIDProvider = { 2002 } }
                return Core.TextResult(text: "stale text")
            }
        )
        let result = await manager.collectTrigger(frontmostApp: MockFrontmostApp(bundleID: "com.sublimetext.4"))
        XCTAssertNil(result)
    }

    func testStructuredOutcomeExplainsTargetSwitchDuringRetrieval() async {
        let manager = HotkeyManager.shared
        manager.retriever = SelectionRetrievalCoordinator(
            inspect: { _ in AXElementInspector.Target() },
            copyCapture: { _ in
                await MainActor.run { manager.frontmostPIDProvider = { 2002 } }
                return Core.TextResult(text: "old selection")
            })
        let response = await manager.collectTriggerResponse(frontmostApp: MockFrontmostApp(bundleID: "com.sublimetext.4"))
        XCTAssertEqual(response.status, .targetChanged)
        XCTAssertNil(response.context)
    }

    func testClipboardFallbackRetainsReadFailure() async {
        let manager = HotkeyManager.shared
        let board = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(board)
        defer { snapshot.restore(to: board) }
        board.clearContents()
        board.setString("fallback text", forType: .string)
        manager.retriever = SelectionRetrievalCoordinator(
            inspect: { _ in AXElementInspector.Target() },
            detailedCopyCapture: { _ in SelectionReadResponse(status: .copyBlocked) })
        let response = await manager.collectTriggerResponse(frontmostApp: MockFrontmostApp(bundleID: "com.sublimetext.4"))
        XCTAssertEqual(response.status, .clipboardFallback)
        XCTAssertEqual(response.retrievalStatus, .copyBlocked)
        XCTAssertEqual(response.context?.text, "fallback text")
    }

    func testAutomaticAppearanceOffStillAllowsTheHotkey() {
        let store = MemorySettingsStore()
        store.set(.isAppEnabled, value: false)
        let app = MockFrontmostApp(bundleID: "com.apple.TextEdit")
        XCTAssertTrue(HotkeyManager.triggerAllowed(frontmost: app, settingsStore: store))
    }

    func testNoIdentifiableTargetNeverTriggers() {
        // Covers a nil app and a nil bundle ID; neither may fall back to OpenClip itself.
        XCTAssertFalse(HotkeyManager.triggerAllowed(frontmost: nil))
        XCTAssertFalse(HotkeyManager.triggerAllowed(frontmost: MockFrontmostApp(bundleID: nil)))
    }

    func testExcludedAppsNeverTrigger() {
        // A bundle from AppFilter's exclusion list must be rejected even when enabled.
        let excluded = MockFrontmostApp(bundleID: "com.adobe.photoshop")
        XCTAssertFalse(HotkeyManager.triggerAllowed(frontmost: excluded))
    }

    func testAppWithDisabledRuleNeverTriggers() {
        RuleEngine.shared.addOrUpdateRule(AppRule(bundleIdentifiers: ["com.test.disabled"], disabled: true))
        let app = MockFrontmostApp(bundleID: "com.test.disabled")
        XCTAssertFalse(HotkeyManager.triggerAllowed(frontmost: app))
    }

    func testAppWithHotkeyOnlyRuleTriggers() {
        RuleEngine.shared.addOrUpdateRule(AppRule(bundleIdentifiers: ["com.test.hotkeyonly"], hotkeyOnly: true))
        let app = MockFrontmostApp(bundleID: "com.test.hotkeyonly")
        XCTAssertTrue(HotkeyManager.triggerAllowed(frontmost: app))
    }

    func testOrdinaryForegroundAppTriggers() {
        let ordinary = MockFrontmostApp(bundleID: "com.apple.TextEdit")
        XCTAssertTrue(HotkeyManager.triggerAllowed(frontmost: ordinary))
    }

    func testPauseUntilTimestampBlocksTrigger() {
        let store = MemorySettingsStore()
        let app = MockFrontmostApp(bundleID: "com.apple.TextEdit")

        // Unpaused: allowed
        store.set(.pauseUntilTimestamp, value: 0.0)
        XCTAssertTrue(HotkeyManager.triggerAllowed(frontmost: app, settingsStore: store))

        // Paused in future: blocked
        store.set(.pauseUntilTimestamp, value: Date().timeIntervalSince1970 + 1800)
        XCTAssertFalse(HotkeyManager.triggerAllowed(frontmost: app, settingsStore: store))

        // Expired pause in past: allowed
        store.set(.pauseUntilTimestamp, value: Date().timeIntervalSince1970 - 10)
        XCTAssertTrue(HotkeyManager.triggerAllowed(frontmost: app, settingsStore: store))
    }

    func testActionHotkeyNameIsDeterministicAndUnique() {
        let nameA = KeyboardShortcuts.Name.actionHotkey("com.example.one")
        let nameA2 = KeyboardShortcuts.Name.actionHotkey("com.example.one")
        let nameB = KeyboardShortcuts.Name.actionHotkey("com.example.two")
        XCTAssertEqual(nameA, nameA2)
        XCTAssertNotEqual(nameA, nameB)
    }

    func testRunBoundActionPerformsActionOnController() async throws {
        let controller = PopupWindowController()
        let performedExpectation = expectation(description: "Bound action performed")
        let action = BoundTestAction(id: "test.bound") {
            performedExpectation.fulfill()
        }
        let app = AppIdentity(NSRunningApplication.current)
        let selection = SelectionContext(
            text: "sample text",
            sourceApp: app,
            cursorPosition: .zero,
            selectionBounds: nil,
            timestamp: Date(),
            appPolicy: .default
        )
        let context = ActionContext(selection: selection, modifiers: [])
        controller.runBoundAction(action, with: context)
        await fulfillment(of: [performedExpectation], timeout: 2.0)
    }

    func testHandleActionHotkeyExecutesWhenEnabled() async throws {
        let manager = HotkeyManager.shared
        let controller = PopupWindowController()
        manager.setup(popupController: controller)

        let performedExpectation = expectation(description: "Action executed")
        let action = BoundTestAction(id: "test.enabled.hotkey") {
            performedExpectation.fulfill()
        }
        ActionCoordinator.shared.register(action: action)

        let app = AppIdentity(NSRunningApplication.current)
        let selection = SelectionContext(
            text: "sample text",
            sourceApp: app,
            cursorPosition: .zero,
            selectionBounds: nil,
            timestamp: Date(),
            appPolicy: .default
        )
        controller.startTestSession(for: selection)

        let store = MemorySettingsStore()
        manager.handleActionHotkey("test.enabled.hotkey", settingsStore: store)
        await fulfillment(of: [performedExpectation], timeout: 2.0)
    }

    func testHandleActionHotkeyRejectsDisabledAction() async throws {
        let manager = HotkeyManager.shared
        let controller = PopupWindowController()
        manager.setup(popupController: controller)

        var performed = false
        let action = BoundTestAction(id: "test.disabled.hotkey") {
            performed = true
        }
        ActionCoordinator.shared.register(action: action)

        let app = AppIdentity(NSRunningApplication.current)
        let selection = SelectionContext(
            text: "sample text",
            sourceApp: app,
            cursorPosition: .zero,
            selectionBounds: nil,
            timestamp: Date(),
            appPolicy: .default
        )
        controller.startTestSession(for: selection)

        let store = MemorySettingsStore()
        store.set(.disabledActionIDs, value: ["test.disabled.hotkey"])

        manager.handleActionHotkey("test.disabled.hotkey", settingsStore: store)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(performed)
    }

    func testHandleActionHotkeyRejectsDisabledPackage() async throws {
        let manager = HotkeyManager.shared
        let controller = PopupWindowController()
        manager.setup(popupController: controller)

        var performed = false
        let action = BoundTestAction(
            id: "pkg123.action",
            chrome: ActionChrome(source: .extensionPkg(packageID: "pkg123"))
        ) {
            performed = true
        }
        ActionCoordinator.shared.register(action: action)

        let app = AppIdentity(NSRunningApplication.current)
        let selection = SelectionContext(
            text: "sample text",
            sourceApp: app,
            cursorPosition: .zero,
            selectionBounds: nil,
            timestamp: Date(),
            appPolicy: .default
        )
        controller.startTestSession(for: selection)

        let store = MemorySettingsStore()
        store.set(.disabledPackages, value: ["pkg123"])

        manager.handleActionHotkey("pkg123.action", settingsStore: store)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(performed)
    }

    func testHandleActionHotkeyRejectsDisabledExtensionGroupParent() async throws {
        let manager = HotkeyManager.shared
        let controller = PopupWindowController()
        manager.setup(popupController: controller)

        var performed = false
        let parentGroup = BoundTestAction(
            id: "pkg123.group",
            chrome: ActionChrome(popupBehavior: .showSubActions)
        ) {}
        let childAction = BoundTestAction(
            id: "pkg123.group.child",
            chrome: ActionChrome()
        ) {
            performed = true
        }
        ActionCoordinator.shared.register(action: parentGroup)
        ActionCoordinator.shared.register(action: childAction)

        let app = AppIdentity(NSRunningApplication.current)
        let selection = SelectionContext(
            text: "sample text",
            sourceApp: app,
            cursorPosition: .zero,
            selectionBounds: nil,
            timestamp: Date(),
            appPolicy: .default
        )
        controller.startTestSession(for: selection)

        let store = MemorySettingsStore()
        store.set(.disabledActionIDs, value: ["pkg123.group"])

        manager.handleActionHotkey("pkg123.group.child", settingsStore: store)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(performed)
    }

    func testCollectTriggerPreservesCompletePayloadInFreshPath() async throws {
        let manager = HotkeyManager.shared

        let app = MockFrontmostApp(bundleID: "com.sublimetext.4")
        let sampleFlavors = [
            RichPasteboardFlavor(type: "public.html", data: Data("<p>Fresh text</p>".utf8)),
            RichPasteboardFlavor(type: "com.apple.custom", data: Data([10, 20, 30]))
        ]

        manager.retriever = SelectionRetrievalCoordinator(
            inspect: { _ in
                AXElementInspector.Target()
            },
            copyCapture: { _ in
                Core.TextResult(
                    text: "Fresh text",
                    bounds: CGRect(x: 10, y: 20, width: 30, height: 40),
                    html: "<p>Fresh text</p>",
                    rtf: "{\\rtf1 Fresh text}",
                    flavors: sampleFlavors
                )
            }
        )

        let trigger = await manager.collectTrigger(frontmostApp: app)
        let resolved = try XCTUnwrap(trigger)
        XCTAssertEqual(resolved.context.text, "Fresh text")
        XCTAssertEqual(resolved.context.html, "<p>Fresh text</p>")
        XCTAssertEqual(resolved.context.rtf, "{\\rtf1 Fresh text}")
        XCTAssertEqual(resolved.context.flavors, sampleFlavors)
    }

    func testCollectTriggerRejectsMismatchedRequestedPID() async {
        let frontmost = MockFrontmostApp(bundleID: "com.apple.TextEdit", pid: 99999)
        let trigger = await HotkeyManager.shared.collectTrigger(frontmostApp: frontmost, requestID: nil, requestedPID: 99999)
        XCTAssertNil(trigger)
    }

    func testCollectTriggerRejectsMismatchedRequestID() async {
        let frontmost = MockFrontmostApp(bundleID: "com.apple.TextEdit")
        let trigger = await HotkeyManager.shared.collectTrigger(frontmostApp: frontmost, requestID: UUID())
        XCTAssertNil(trigger)
    }
}


private struct BoundTestAction: Action {
    let id: String
    var title: String = "Test Bound"
    var icon = ActionIcon.symbol("star")
    var chrome: ActionChrome = ActionChrome()
    let onPerform: @MainActor () -> Void

    @MainActor func isEnabled(for context: ActionContext) -> Bool { true }
    @MainActor func matchInfo(for context: ActionContext) -> ActionMatchInfo? { nil }
    @MainActor func perform(_ context: ActionContext) async throws -> ActionResult {
        onPerform()
        return .success
    }
}

/// `NSRunningApplication` can't take an arbitrary bundle ID, so this stand-in subclasses it for hermetic tests.
private final class MockFrontmostApp: NSRunningApplication {
    private let bundleID: String?
    private let pid: pid_t

    init(bundleID: String?, pid: pid_t = 1001) {
        self.bundleID = bundleID
        self.pid = pid
        super.init()
    }

    override var bundleIdentifier: String? { bundleID }
    override var processIdentifier: pid_t { pid }
}
