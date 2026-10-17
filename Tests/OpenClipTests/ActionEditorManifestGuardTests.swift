// ActionEditorManifestGuardTests.swift
// OpenClip
//
// Pins the action editor's guard against rewriting the parent group's manifest entry when the
// editor was opened for a nested sub-action.
import XCTest
@testable import Core
@testable import OpenClip

@MainActor
final class ActionEditorManifestGuardTests: XCTestCase {
    private let packageID = "io.appwrite.openclip.function-runner"
    private var groupID: String { "\(packageID).appwrite" }

    private func endpointOption() -> ExtensionOption {
        ExtensionOption(identifier: "endpoint", label: "Endpoint", defaultValue: "https://cloud.appwrite.io/v1")
    }

    // MARK: - Action editor manifest-save guard

    private func groupManifest() -> ExtensionMetadata {
        let sub = ExtensionActionMetadata(id: "execute", title: "Execute Function", script: "main.js", type: "javascript")
        let group = ExtensionActionMetadata(id: "appwrite", title: "Appwrite", type: "group", subActions: [sub])
        return ExtensionMetadata(identifier: packageID, name: "Appwrite Function Runner", actions: [group], options: nil)
    }


    func testLocatedEntryBacksTopLevelAction() {
        let state = LocatedManifest(manifestURL: URL(fileURLWithPath: "/tmp/openclip.json"), manifest: groupManifest(), targetIndex: 0)
        XCTAssertTrue(ActionEditorPage.locatedEntryBacks(actionID: groupID, in: state))
    }

    func testLocatedEntryDoesNotBackNestedSubAction() {
        // The locator resolves a sub-action to its parent's index; saving there would rename the group.
        let state = LocatedManifest(manifestURL: URL(fileURLWithPath: "/tmp/openclip.json"), manifest: groupManifest(), targetIndex: 0)
        XCTAssertFalse(ActionEditorPage.locatedEntryBacks(actionID: "\(groupID).execute", in: state))
    }

    func testLocateManifestResolvesSubActionToParentEntryThatDoesNotBackIt() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let packageDir = tempDir.appendingPathComponent("AppwriteFunctionRunner.openclipext")
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try ExtensionManifestStore.writeManifest(groupManifest(), to: packageDir.appendingPathComponent(Constants.manifestFileName))

        let subAction = OptionedAction(id: "\(groupID).execute", packageID: packageID, options: [endpointOption()])
        let located = try XCTUnwrap(ActionEditorPage.locateManifest(for: subAction, in: tempDir))
        XCTAssertEqual(located.targetIndex, 0)
        XCTAssertFalse(ActionEditorPage.locatedEntryBacks(actionID: subAction.id, in: located))
    }

    func testDeveloperAndStorePackagesAreNotLogicEditable() {
        XCTAssertFalse(ActionEditorPage.isLogicEditable(manifestIdentifier: "easydict.openclip.deskangel.2026"))
        XCTAssertFalse(ActionEditorPage.isLogicEditable(manifestIdentifier: "io.appwrite.openclip.function-runner"))
        XCTAssertFalse(ActionEditorPage.isLogicEditable(manifestIdentifier: "com.example.extension"))
    }

    func testCustomActionsAreLogicEditable() {
        XCTAssertTrue(ActionEditorPage.isLogicEditable(manifestIdentifier: "\(Constants.customIdentifierPrefix)my-custom-action"))
    }
}

/// A sub-action-shaped test double that declares options, mirroring a `javascript` command inside
/// an extension `group` (the factory stamps `.standard` chrome sourced from the package).
private struct OptionedAction: Action, Sendable {
    let id: String
    let title: String = "Execute Function"
    var icon: ActionIcon { .symbol("bolt") }
    let chrome: ActionChrome
    let actionOptions: [ExtensionOption]

    init(id: String, packageID: String, options: [ExtensionOption]) {
        self.id = id
        self.chrome = ActionChrome(badge: .none, rowStyle: .standard, popupBehavior: .perform, source: .extensionPkg(packageID: packageID))
        self.actionOptions = options
    }

    @MainActor func isEnabled(for context: ActionContext) -> Bool { true }
    @MainActor func perform(_ context: ActionContext) async throws -> ActionResult { .none }
}
