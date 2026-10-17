import XCTest
import SwiftUI
@testable import OpenClip
@testable import Core

/// Minimal fake action with a configurable chrome source, for AIToolsAction's children resolution.
private struct FakeAIAction: Action {
    let id: String
    var title: String { id }
    var icon: ActionIcon { .symbol("sparkles") }
    var chrome: ActionChrome
    var enabled: Bool
    init(id: String, source: ActionChrome.Source = .ai, enabled: Bool = true) {
        self.id = id
        self.chrome = ActionChrome(source: source)
        self.enabled = enabled
    }
    @MainActor func isEnabled(for context: ActionContext) -> Bool { enabled }
    @MainActor func perform(_ context: ActionContext) async throws -> ActionResult { .success }
}

@MainActor
final class AIToolsActionSubActionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.reset()
    }

    func testStandalonePresetsAreNotDuplicatedInAITools() {
        let store = MemorySettingsStore()
        let tools = AIToolsAction(settingsStore: store)
        let presets = [FakeAIAction(id: "ai.preset.1"), FakeAIAction(id: "ai.preset.2")]
        store.set(.standaloneAIActionIDs, value: ["ai.preset.1"])
        XCTAssertEqual(tools.subActions(in: presets).map(\.id), ["ai.preset.2"])
        store.set(.standaloneAIActionIDs, value: Set(presets.map(\.id)))
        XCTAssertTrue(tools.subActions(in: presets).isEmpty, "An empty group must not resurrect presets via the fallback.")
    }

    @MainActor
    func testAIToolsResolvesAIPresets() {
        let tools = AIToolsAction(settingsStore: MemorySettingsStore())
        let preset1 = FakeAIAction(id: "ai.preset.1")
        let preset2 = FakeAIAction(id: "ai.preset.2")
        let other = FakeAIAction(id: "builtin.copy", source: .builtin)
        let ids = tools.subActions(in: [preset1, preset2, other]).map(\.id)
        XCTAssertEqual(ids, ["ai.preset.1", "ai.preset.2"])
    }

    @MainActor
    func testEmptyCatalogDoesNotResurrectFilteredPresets() {
        let tools = AIToolsAction(settingsStore: MemorySettingsStore())
        let other = FakeAIAction(id: "builtin.copy", source: .builtin)
        let subActions = tools.subActions(in: [other])
        XCTAssertTrue(subActions.isEmpty)
    }

    private var context: ActionContext {
        ActionContext(selection: SelectionContext(
            text: "Example", sourceApp: AppIdentity(bundleIdentifier: "com.test", localizedName: "Test"),
            cursorPosition: .zero, timestamp: Date(), appPolicy: .default
        ))
    }

    func testHidingAIGroupDoesNotDisableStandalonePresetsOrAIService() {
        let store = MemorySettingsStore()
        let registry = ActionRegistry(settingsStore: store)
        let tools = AIToolsAction(settingsStore: store)
        store.set(.standaloneAIActionIDs, value: ["ai.preset.2"])
        registry.register(builtIns: [tools, FakeAIAction(id: "ai.preset.1"), FakeAIAction(id: "ai.preset.2")])
        let toggle = ActionEnablement.binding(
            for: tools,
            disabledActionIDs: Binding(get: { store.get(.disabledActionIDs) }, set: { store.set(.disabledActionIDs, value: $0) }),
            disabledPackages: .constant([])
        )
        let globalAIEnabled = AIServiceManager.shared.isAIEnabled
        toggle.wrappedValue = false
        XCTAssertFalse(toggle.wrappedValue)
        XCTAssertEqual(store.get(.disabledActionIDs), [tools.id])
        XCTAssertEqual(AIServiceManager.shared.isAIEnabled, globalAIEnabled)
        XCTAssertEqual(registry.availableActions(for: context).map(\.id), ["ai.preset.2"])
        XCTAssertEqual(registry.searchCatalog(for: context).map(\.id), ["ai.preset.2"])
        toggle.wrappedValue = true
        XCTAssertEqual(tools.subActions(in: registry.availableActions(for: context)).map(\.id), ["ai.preset.1"])
    }

    func testGroupDisappearsWhenAllRemainingPresetsAreDisabled() {
        let store = MemorySettingsStore()
        let registry = ActionRegistry(settingsStore: store)
        let tools = AIToolsAction(settingsStore: store)
        registry.register(builtIns: [tools, FakeAIAction(id: "ai.preset.1", enabled: false)])
        let available = registry.availableActions(for: context)
        XCTAssertTrue(tools.subActions(in: available).isEmpty)
    }
}
