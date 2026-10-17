// ActionGroupIntegrationTests.swift
// OpenClip
//
// Integration tests covering custom action group lifecycle and extension uninstallation within groups.
import XCTest
import SwiftUI
@testable import Core
@testable import OpenClip

@MainActor
final class ActionGroupIntegrationTests: XCTestCase {
    private var settingsStore: MemorySettingsStore!
    private var coordinator: ActionCoordinator!
    private var registry: ActionRegistry!

    override func setUp() {
        super.setUp()
        settingsStore = MemorySettingsStore()
        registry = ActionRegistry(settingsStore: settingsStore)
        coordinator = ActionCoordinator(registry: registry, settingsStore: settingsStore)
    }

    func testUnregisterAndReinstallExtensionInsideGroupPreservesGroupMembership() async throws {
        let extAction1 = CustomAction(id: "com.custom.ext1", title: "Ext 1", iconName: "star", type: .textSnippet(template: "1"))
        let extAction2 = CustomAction(id: "com.custom.ext2", title: "Ext 2", iconName: "star", type: .textSnippet(template: "2"))
        coordinator.register(action: extAction1)
        coordinator.register(action: extAction2)

        coordinator.createGroup(title: "My Custom Exts", iconName: "folder", memberActionIDs: ["com.custom.ext1", "com.custom.ext2"])
        XCTAssertEqual(coordinator.actionGroupDefs.count, 1)

        // Simulating reload / reinstall unregister of canonical ID
        coordinator.unregister(actionID: "com.custom.ext1")

        XCTAssertEqual(coordinator.actionGroupDefs.count, 1)
        XCTAssertEqual(coordinator.actionGroupDefs[0].memberActionIDs, ["com.custom.ext1", "com.custom.ext2"])

        // Simulating re-registration upon reinstallation
        coordinator.register(action: extAction1)

        let groupID = coordinator.actionGroupDefs[0].id
        XCTAssertEqual(coordinator.actions.first?.id, groupID)
        XCTAssertEqual(Set(coordinator.actions.dropFirst().map(\.id)), Set(["com.custom.ext1", "com.custom.ext2"]))
    }

    func testMoveCustomGroupExpandsMembersAtomically() {
        let a1 = DummyAction(id: "action.1", title: "Action 1")
        let a2 = DummyAction(id: "action.2", title: "Action 2")
        let a3 = DummyAction(id: "action.3", title: "Action 3")
        let a4 = DummyAction(id: "action.4", title: "Action 4")
        coordinator.register(action: a1)
        coordinator.register(action: a2)
        coordinator.register(action: a3)
        coordinator.register(action: a4)

        coordinator.createGroup(title: "Group 1", iconName: "folder", memberActionIDs: ["action.1", "action.2"])
        XCTAssertEqual(coordinator.actions.count, 5)
        let groupID = coordinator.actionGroupDefs[0].id
        XCTAssertEqual(coordinator.actions.map(\.id), [groupID, "action.1", "action.2", "action.3", "action.4"])

        // Move group (index 0, 1, 2) after action.3 (destination 4)
        let sourceIndices = IndexSet([0, 1, 2])
        coordinator.moveActions(from: sourceIndices, to: 4)

        XCTAssertEqual(coordinator.actions.map(\.id), ["action.3", groupID, "action.1", "action.2", "action.4"])
    }

    func testUngroupRestoresMembersToTopLevel() {
        let a1 = DummyAction(id: "action.1", title: "Action 1")
        let a2 = DummyAction(id: "action.2", title: "Action 2")
        coordinator.register(action: a1)
        coordinator.register(action: a2)

        coordinator.createGroup(title: "Group 1", iconName: "folder", memberActionIDs: ["action.1", "action.2"])
        XCTAssertEqual(coordinator.actionGroupDefs.count, 1)
        let groupID = coordinator.actionGroupDefs[0].id

        coordinator.ungroup(groupID: groupID)
        XCTAssertTrue(coordinator.actionGroupDefs.isEmpty)
        XCTAssertEqual(coordinator.actions.map(\.id), ["action.1", "action.2"])
    }

    func testRemoveMemberViaCoordinatorKeepsGroupDefWithRemainingMembers() {
        let a1 = DummyAction(id: "action.1", title: "Action 1")
        let a2 = DummyAction(id: "action.2", title: "Action 2")
        coordinator.register(action: a1)
        coordinator.register(action: a2)

        coordinator.createGroup(title: "Group 1", iconName: "folder", memberActionIDs: ["action.1", "action.2"])
        XCTAssertEqual(coordinator.actionGroupDefs.count, 1)
        let groupID = coordinator.actionGroupDefs[0].id

        coordinator.removeFromGroup(actionID: "action.1", groupID: groupID)
        XCTAssertEqual(coordinator.actionGroupDefs.count, 1)
        XCTAssertEqual(coordinator.actionGroupDefs[0].memberActionIDs, ["action.2"])
    }

    func testDisabledGroupHidesMembersFromAvailableActions() {
        let a1 = DummyAction(id: "action.1", title: "Action 1")
        let a2 = DummyAction(id: "action.2", title: "Action 2")
        coordinator.register(action: a1)
        coordinator.register(action: a2)

        coordinator.createGroup(title: "Group 1", iconName: "folder", memberActionIDs: ["action.1", "action.2"])
        let groupID = coordinator.actionGroupDefs[0].id

        settingsStore.set(.disabledActionIDs, value: [groupID])

        let context = ActionContext(
            selection: SelectionContext(
                text: "test text",
                sourceApp: AppIdentity(bundleIdentifier: "com.test", localizedName: "Test"),
                cursorPosition: .zero,
                timestamp: Date(),
                appPolicy: .default
            )
        )
        let available = coordinator.resolveActions(for: context)
        XCTAssertFalse(available.contains(where: { $0.id == groupID }))
        XCTAssertFalse(available.contains(where: { $0.id == "action.1" }))
        XCTAssertFalse(available.contains(where: { $0.id == "action.2" }))
    }

    func testReorderingGroupMembersUpdatesActionsOrderAndGroupDefPersistedOrder() throws {
        let a1 = DummyAction(id: "action.1", title: "Action 1")
        let a2 = DummyAction(id: "action.2", title: "Action 2")
        let a3 = DummyAction(id: "action.3", title: "Action 3")
        coordinator.register(action: a1)
        coordinator.register(action: a2)
        coordinator.register(action: a3)

        coordinator.createGroup(title: "Group 1", iconName: "folder", memberActionIDs: ["action.1", "action.2", "action.3"])
        XCTAssertEqual(coordinator.actionGroupDefs.count, 1)
        let groupID = coordinator.actionGroupDefs[0].id
        XCTAssertEqual(coordinator.actionGroupDefs[0].memberActionIDs, ["action.1", "action.2", "action.3"])
        XCTAssertEqual(coordinator.actions.map(\.id), [groupID, "action.1", "action.2", "action.3"])

        // Move action.3 (index 3) before action.1 (destination 1)
        coordinator.moveActions(from: IndexSet(integer: 3), to: 1)

        XCTAssertEqual(coordinator.actions.map(\.id), [groupID, "action.3", "action.1", "action.2"])
        XCTAssertEqual(coordinator.actionGroupDefs[0].memberActionIDs, ["action.3", "action.1", "action.2"])

        let persistedData = settingsStore.get(.actionGroups)
        let decoded = try ActionGroupDef.decode(from: XCTUnwrap(persistedData))
        XCTAssertEqual(decoded.first?.memberActionIDs, ["action.3", "action.1", "action.2"])
    }

    func testAddToGroupViaCoordinatorAddsActionAndUpdatesCatalogAndPersistence() throws {
        let a1 = DummyAction(id: "action.1", title: "Action 1")
        let a2 = DummyAction(id: "action.2", title: "Action 2")
        let a3 = DummyAction(id: "action.3", title: "Action 3")
        coordinator.register(action: a1)
        coordinator.register(action: a2)
        coordinator.register(action: a3)

        coordinator.createGroup(title: "Group 1", iconName: "folder", memberActionIDs: ["action.1", "action.2"])
        let groupID = coordinator.actionGroupDefs[0].id

        coordinator.addToGroup(actionID: "action.3", groupID: groupID)

        XCTAssertEqual(coordinator.actionGroupDefs[0].memberActionIDs, ["action.1", "action.2", "action.3"])
        XCTAssertEqual(coordinator.actions.map(\.id), [groupID, "action.1", "action.2", "action.3"])

        let persistedData = settingsStore.get(.actionGroups)
        let decoded = try ActionGroupDef.decode(from: XCTUnwrap(persistedData))
        XCTAssertEqual(decoded.first?.memberActionIDs, ["action.1", "action.2", "action.3"])
    }

    /// A group lasts exactly as long as it holds something; a removal that empties it dissolves it.
    func testAGroupLastsExactlyAsLongAsItHoldsSomething() throws {
        let a1 = DummyAction(id: "action.1", title: "Action 1")
        let a2 = DummyAction(id: "action.2", title: "Action 2")
        coordinator.register(action: a1)
        coordinator.register(action: a2)

        let emptyID = try XCTUnwrap(coordinator.createGroup(title: "Empty Group", iconName: "folder", memberActionIDs: []))
        XCTAssertEqual(coordinator.actionGroupDefs.count, 1, "an explicitly created empty group is kept")
        XCTAssertEqual(coordinator.actionGroupDefs[0].memberActionIDs, [])
        XCTAssertTrue(coordinator.actions.contains { $0.id == emptyID }, "and its row is on the bar")

        // Made from two actions — which is what dropping one onto the other does — it is real.
        let groupID = try XCTUnwrap(
            coordinator.createGroup(title: "Pair", iconName: "folder", memberActionIDs: ["action.1", "action.2"])
        )
        XCTAssertEqual(coordinator.actionGroupDefs.count, 2)
        XCTAssertTrue(coordinator.actions.contains { $0.id == groupID })

        let context = ActionContext(
            selection: SelectionContext(
                text: "test text",
                sourceApp: AppIdentity(bundleIdentifier: "com.test", localizedName: "Test"),
                cursorPosition: .zero,
                timestamp: Date(),
                appPolicy: .default
            )
        )
        var available = coordinator.resolveActions(for: context)
        XCTAssertTrue(available.contains { $0.id == groupID }, "a group with members belongs on the bar")

        // Drag one out: the group holds the other, so it stays.
        coordinator.removeFromGroup(actionID: "action.1", groupID: groupID)
        XCTAssertEqual(coordinator.actionGroupDefs.count, 2)
        XCTAssertEqual(coordinator.actionGroupDefs.first { $0.id == groupID }?.memberActionIDs, ["action.2"])

        // Drag the last one out: the group goes with it, and so does its row on the bar.
        coordinator.removeFromGroup(actionID: "action.2", groupID: groupID)
        XCTAssertFalse(coordinator.actionGroupDefs.contains { $0.id == groupID })
        XCTAssertEqual(coordinator.actionGroupDefs.count, 1, "the deliberately empty group is untouched")
        XCTAssertFalse(coordinator.actions.contains { $0.id == groupID })

        available = coordinator.resolveActions(for: context)
        XCTAssertFalse(available.contains { $0.id == groupID }, "and its row on the bar goes with it")
        XCTAssertTrue(available.contains { $0.id == "action.1" })
        XCTAssertTrue(available.contains { $0.id == "action.2" })
    }

    func testExtensionGroupMemberResolutionAndCustomization() {
        let customizationManager = ActionCustomizationManager(settingsStore: settingsStore)
        let groupAction = GroupAction(
            id: "com.pkg.leafy",
            title: "Leafy",
            icon: .symbol("leaf.fill"),
            chrome: ActionChrome(
                rowStyle: .actionGroup,
                popupBehavior: .showSubActions,
                source: .extensionPkg(packageID: "com.pkg.leafy")
            )
        )
        let subAction1 = DummyAction(
            id: "com.pkg.leafy.lookup",
            title: "Look up"
        )
        let subAction2 = DummyAction(
            id: "com.pkg.leafy.translate",
            title: "Translate"
        )
        coordinator.register(action: groupAction)
        coordinator.register(action: subAction1)
        coordinator.register(action: subAction2)

        // Member resolution returns sub-actions for extension groups
        let memberIDs = coordinator.memberActionIDs(for: groupAction.id)
        XCTAssertEqual(memberIDs, ["com.pkg.leafy.lookup", "com.pkg.leafy.translate"])

        // Customization override sets custom title and icon
        customizationManager.setOverride(for: groupAction.id, title: "My Leafy", symbol: "sparkles", text: nil)
        let presentation = customizationManager.presented(groupAction, surface: .table)
        XCTAssertEqual(presentation.title, "My Leafy")
        XCTAssertEqual(presentation.icon, .symbol("sparkles"))
    }

    func testSetExtensionGroupMemberOrderPersistsAndReordersInCoordinator() {
        let groupID = "com.pkg.extgroup"
        let groupAction = GroupAction(
            id: groupID,
            title: "Ext Group",
            icon: .symbol("folder"),
            chrome: ActionChrome(rowStyle: .actionGroup, popupBehavior: .showSubActions, source: .extensionPkg(packageID: "com.pkg"))
        )
        let s1 = DummyAction(id: "\(groupID).s1", title: "Sub 1")
        let s2 = DummyAction(id: "\(groupID).s2", title: "Sub 2")
        let s3 = DummyAction(id: "\(groupID).s3", title: "Sub 3")

        coordinator.register(action: groupAction)
        coordinator.register(action: s1)
        coordinator.register(action: s2)
        coordinator.register(action: s3)

        XCTAssertEqual(coordinator.memberActionIDs(for: groupID), ["\(groupID).s1", "\(groupID).s2", "\(groupID).s3"])

        coordinator.setExtensionGroupMemberOrder(groupID: groupID, memberIDs: ["\(groupID).s3", "\(groupID).s1", "\(groupID).s2"])

        XCTAssertEqual(coordinator.memberActionIDs(for: groupID), ["\(groupID).s3", "\(groupID).s1", "\(groupID).s2"])
        XCTAssertEqual(coordinator.actions.map(\.id), [groupID, "\(groupID).s3", "\(groupID).s1", "\(groupID).s2"])
        XCTAssertEqual(settingsStore.get(.extensionGroupMemberOrder)[groupID], ["\(groupID).s3", "\(groupID).s1", "\(groupID).s2"])
    }

    func testMoveExtensionGroupAtomicallyPreservesSubactionsAndOrder() {
        let groupID = "com.pkg.extgroup"
        let groupAction = GroupAction(
            id: groupID,
            title: "Ext Group",
            icon: .symbol("folder"),
            chrome: ActionChrome(rowStyle: .actionGroup, popupBehavior: .showSubActions, source: .extensionPkg(packageID: "com.pkg"))
        )
        let s1 = DummyAction(id: "\(groupID).s1", title: "Sub 1")
        let s2 = DummyAction(id: "\(groupID).s2", title: "Sub 2")
        let other = DummyAction(id: "com.pkg.other", title: "Other")

        coordinator.register(action: groupAction)
        coordinator.register(action: s1)
        coordinator.register(action: s2)
        coordinator.register(action: other)

        settingsStore.set(.actionOrder, value: [groupID, "com.pkg.other"])
        XCTAssertEqual(coordinator.actions.map(\.id), [groupID, "\(groupID).s1", "\(groupID).s2", "com.pkg.other"])

        // Move the group to after "com.pkg.other"
        coordinator.moveActions(from: IndexSet(integer: 0), to: 4)

        XCTAssertEqual(coordinator.actions.map(\.id), ["com.pkg.other", groupID, "\(groupID).s1", "\(groupID).s2"])
        XCTAssertEqual(settingsStore.get(.actionOrder), ["com.pkg.other", groupID])
    }
}

private struct DummyAction: Action, Sendable {
    let id: String
    let title: String
    var icon: ActionIcon { .symbol("star") }
    var chrome: ActionChrome { _chrome }
    private let _chrome: ActionChrome

    init(
        id: String,
        title: String,
        chrome: ActionChrome = ActionChrome(badge: .none, rowStyle: .standard, popupBehavior: .perform, source: .extensionPkg(packageID: "com.pkg.leafy"))
    ) {
        self.id = id
        self.title = title
        self._chrome = chrome
    }

    @MainActor func isEnabled(for context: ActionContext) -> Bool { true }
    @MainActor func perform(_ context: ActionContext) async throws -> ActionResult { .none }
}

@MainActor
final class ActionEnablementTests: XCTestCase {
    private var settingsStore: MemorySettingsStore!
    private var registry: ActionRegistry!
    private var coordinator: ActionCoordinator!

    override func setUp() {
        super.setUp()
        TestIsolation.reset()
        settingsStore = MemorySettingsStore()
        registry = ActionRegistry(settingsStore: settingsStore)
        coordinator = ActionCoordinator(registry: registry, settingsStore: settingsStore)
        for index in 1...4 {
            coordinator.register(action: DummyAction(id: "action.\(index)", title: "Action \(index)"))
        }
    }

    func testActionEnablementToggleIndividualActionInsideDisabledPackage() {
        var disabledPackages: Set<String> = ["com.pkg.leafy"]
        var disabledActionIDs: Set<String> = []

        let action1 = DummyAction(id: "action.1", title: "Action 1")
        let binding1 = ActionEnablement.binding(
            for: action1,
            disabledActionIDs: Binding(get: { disabledActionIDs }, set: { disabledActionIDs = $0 }),
            disabledPackages: Binding(get: { disabledPackages }, set: { disabledPackages = $0 }),
            coordinator: coordinator
        )

        XCTAssertFalse(binding1.wrappedValue)

        // Turn action 1 on: package should be removed from disabledPackages, and siblings should be disabled
        binding1.wrappedValue = true

        XCTAssertFalse(disabledPackages.contains("com.pkg.leafy"))
        XCTAssertFalse(disabledActionIDs.contains("action.1"))
        // Siblings (action.2, action.3, action.4 from setUp) should now be in disabledActionIDs
        XCTAssertTrue(disabledActionIDs.contains("action.2"))
        XCTAssertTrue(disabledActionIDs.contains("action.3"))
        XCTAssertTrue(disabledActionIDs.contains("action.4"))

        XCTAssertTrue(binding1.wrappedValue)

        binding1.wrappedValue = false
        XCTAssertTrue(disabledActionIDs.contains("action.1"))
        XCTAssertFalse(binding1.wrappedValue)
    }

    func testPackageBindingEnableAndDisable() {
        var disabledPackages: Set<String> = []
        var disabledActionIDs: Set<String> = ["action.1", "action.2", "action.3", "action.4"]

        let pkgBinding = ActionEnablement.packageBinding(
            packageID: "com.pkg.leafy",
            gatedReason: nil,
            disabledPackages: Binding(get: { disabledPackages }, set: { disabledPackages = $0 }),
            disabledActionIDs: Binding(get: { disabledActionIDs }, set: { disabledActionIDs = $0 }),
            coordinator: coordinator
        )

        // When all actions are disabled, package reads as false
        XCTAssertFalse(pkgBinding.wrappedValue)

        // Turn package on: clears all action disables and clears disabledPackages
        pkgBinding.wrappedValue = true
        XCTAssertFalse(disabledPackages.contains("com.pkg.leafy"))
        XCTAssertTrue(disabledActionIDs.isEmpty)
        XCTAssertTrue(pkgBinding.wrappedValue)

        // Turn package off: adds to disabledPackages
        pkgBinding.wrappedValue = false
        XCTAssertTrue(disabledPackages.contains("com.pkg.leafy"))
        XCTAssertFalse(pkgBinding.wrappedValue)
    }

    func testActionEnablementToggleChildOfExtensionGroupEnablesParentGroup() {
        let group1 = DummyAction(
            id: "com.pkg.leafy.g1",
            title: "Group 1",
            chrome: ActionChrome(rowStyle: .actionGroup, popupBehavior: .showSubActions, source: .extensionPkg(packageID: "com.pkg.leafy"))
        )
        let group2 = DummyAction(
            id: "com.pkg.leafy.g2",
            title: "Group 2",
            chrome: ActionChrome(rowStyle: .actionGroup, popupBehavior: .showSubActions, source: .extensionPkg(packageID: "com.pkg.leafy"))
        )
        let child2 = DummyAction(
            id: "com.pkg.leafy.g2.child",
            title: "Child 2",
            chrome: ActionChrome(source: .extensionPkg(packageID: "com.pkg.leafy"))
        )
        coordinator.register(action: group1)
        coordinator.register(action: group2)
        coordinator.register(action: child2)

        var disabledPackages: Set<String> = []
        var disabledActionIDs: Set<String> = ["com.pkg.leafy.g1", "com.pkg.leafy.g2", "com.pkg.leafy.g2.child"]

        let childBinding = ActionEnablement.binding(
            for: child2,
            disabledActionIDs: Binding(get: { disabledActionIDs }, set: { disabledActionIDs = $0 }),
            disabledPackages: Binding(get: { disabledPackages }, set: { disabledPackages = $0 }),
            coordinator: coordinator
        )

        XCTAssertFalse(childBinding.wrappedValue)
        childBinding.wrappedValue = true

        // Child's specific parent group (g2) must be un-disabled
        XCTAssertFalse(disabledActionIDs.contains("com.pkg.leafy.g2"))
        XCTAssertFalse(disabledActionIDs.contains("com.pkg.leafy.g2.child"))
        // Other group (g1) remains disabled
        XCTAssertTrue(disabledActionIDs.contains("com.pkg.leafy.g1"))
        XCTAssertTrue(childBinding.wrappedValue)
    }

    func testActionEnablementToggleGroupContainerKeepsChildCommandsEnabled() {
        let group = DummyAction(
            id: "com.pkg.leafy.g1",
            title: "Group 1",
            chrome: ActionChrome(rowStyle: .actionGroup, popupBehavior: .showSubActions, source: .extensionPkg(packageID: "com.pkg.leafy"))
        )
        let child1 = DummyAction(
            id: "com.pkg.leafy.g1.c1",
            title: "Child 1",
            chrome: ActionChrome(source: .extensionPkg(packageID: "com.pkg.leafy"))
        )
        let child2 = DummyAction(
            id: "com.pkg.leafy.g1.c2",
            title: "Child 2",
            chrome: ActionChrome(source: .extensionPkg(packageID: "com.pkg.leafy"))
        )
        let standalone = DummyAction(
            id: "com.pkg.leafy.standalone",
            title: "Standalone",
            chrome: ActionChrome(source: .extensionPkg(packageID: "com.pkg.leafy"))
        )
        coordinator.register(action: group)
        coordinator.register(action: child1)
        coordinator.register(action: child2)
        coordinator.register(action: standalone)

        var disabledPackages: Set<String> = ["com.pkg.leafy"]
        var disabledActionIDs: Set<String> = []

        let groupBinding = ActionEnablement.binding(
            for: group,
            disabledActionIDs: Binding(get: { disabledActionIDs }, set: { disabledActionIDs = $0 }),
            disabledPackages: Binding(get: { disabledPackages }, set: { disabledPackages = $0 }),
            coordinator: coordinator
        )

        XCTAssertFalse(groupBinding.wrappedValue)
        groupBinding.wrappedValue = true

        XCTAssertFalse(disabledPackages.contains("com.pkg.leafy"))
        XCTAssertFalse(disabledActionIDs.contains("com.pkg.leafy.g1"))
        // Group children must NOT be disabled
        XCTAssertFalse(disabledActionIDs.contains("com.pkg.leafy.g1.c1"))
        XCTAssertFalse(disabledActionIDs.contains("com.pkg.leafy.g1.c2"))
        // Sibling outside the group is disabled
        XCTAssertTrue(disabledActionIDs.contains("com.pkg.leafy.standalone"))
        XCTAssertTrue(groupBinding.wrappedValue)
    }
}
