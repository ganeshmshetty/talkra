import XCTest
@testable import Core
@testable import OpenClip

final class ActionCoordinatorStartupTests: XCTestCase {
    let packageID = "com.custom.startup.test"
    var tempDir: URL!
    /// `ActionRegistry.shared` is built on `DefaultSettingsStore.shared`, i.e. the *real* app
    /// preferences domain — the test host shares its bundle id with OpenClip. `unregister` prunes
    /// `action.order` against whatever the registry currently holds, so unregistering here used to
    /// rewrite (and with a near-empty test registry, wipe) the developer's own action order.
    /// Snapshot the key and put it back.
    private var savedActionOrder: [String] = []
    
    override func setUp() async throws {
        try await super.setUp()
        savedActionOrder = await MainActor.run { () -> [String] in
            let saved = DefaultSettingsStore.shared.get(.actionOrder)
            TestIsolation.reset()
            ExtensionManager.shared.actionFactory = DefaultActionFactory()
            return saved
        }
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() async throws {
        let pid = packageID
        let restoredOrder = savedActionOrder
        await MainActor.run {
            ActionRegistry.shared.unregister(actionID: pid)
            ExtensionManager.shared.actionFactory = nil
            DefaultSettingsStore.shared.set(.actionOrder, value: restoredOrder)
        }
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    @MainActor
    func testLoadInitialStateLoadsManifestPackage() async throws {
        let action = CustomAction(
            id: packageID,
            title: "Startup Action",
            iconName: "star",
            type: .textSnippet(template: "hello")
        )
        // The manifest is the only canonical action definition: write a single-action package
        // into a temp extensions directory (exactly what the Add sheet writes, just isolated from
        // the real ~/.openclip/extensions) and let the coordinator's startup scan pick it up.
        try CustomActionManifestWriter.write(action: action, to: tempDir)
        
        // Empty rules file so loadInitialState never reads the real ~/.openclip/rules.json.
        let rulesURL = tempDir.appendingPathComponent("rules.json")
        try #"{"rules":[]}"#.data(using: .utf8)?.write(to: rulesURL)
        
        // Clear registry to simulate startup state before coordinator loadInitialState
        ActionRegistry.shared.unregister(actionID: packageID)
        XCTAssertFalse(ActionRegistry.shared.actions.contains(where: { $0.id == packageID }))

        let coordinator = ActionCoordinator()
        await coordinator.loadInitialState(extensionsDirectory: tempDir, rulesURL: rulesURL)
        
        let registeredActions = ActionRegistry.shared.actions
        XCTAssertTrue(registeredActions.contains(where: { $0.id == packageID }))
    }
}
