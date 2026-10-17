import XCTest
import KeyboardShortcuts
@testable import OpenClip
@testable import Core

@MainActor
final class AIPresetDraftTests: XCTestCase {
    func testNewPresetDefaultsToTextWithDefaultOrChosenIcon() throws {
        for icon in [Constants.defaultAIIconSymbol, "pencil"] {
            let store = MemorySettingsStore()
                let customizations = ActionCustomizationManager(settingsStore: store)
            var draft = AIPresetDraft(title: "  Simplify  ", prompt: "  Use simpler words.  ")
            draft.iconSymbol = icon
            var saved: AIActionPreset?

            let preset = try XCTUnwrap(draft.createPreset(
                customizations: customizations,
                saveShortcut: { _, _ in XCTFail("No shortcut was chosen") },
                savePreset: { saved = $0 }
            ))
            let action = AIAction(presetID: preset.id, title: preset.title)
            let reloaded = ActionCustomizationManager(settingsStore: store)
            XCTAssertEqual(saved, preset)
            XCTAssertEqual(preset.title, "Simplify")
            XCTAssertEqual(preset.prompt, "Use simpler words.")
            XCTAssertEqual(reloaded.popupIcon(for: action), .text("Simplify"))
            XCTAssertEqual(reloaded.tableIcon(for: action), .symbol(icon))
            XCTAssertEqual(ActionEditorPage.initialDisplayMode(
                override: reloaded.override(for: action.id), actionIcon: action.icon
            ), 1)
        }
    }

    func testExplicitIconModePersistsAtCreation() throws {
        let store = MemorySettingsStore()
        let customizations = ActionCustomizationManager(settingsStore: store)
        let draft = AIPresetDraft(title: "Simplify", prompt: "Use simpler words.", iconSymbol: "pencil", displayMode: 0)
        let preset = try XCTUnwrap(draft.createPreset(
                customizations: customizations,
            saveShortcut: { _, _ in XCTFail("No shortcut was chosen") }, savePreset: { _ in }
        ))
        let action = AIAction(presetID: preset.id, title: preset.title)
        let reloaded = ActionCustomizationManager(settingsStore: store)
        XCTAssertEqual(reloaded.popupIcon(for: action), .symbol("pencil"))
        XCTAssertEqual(ActionEditorPage.initialDisplayMode(
            override: reloaded.override(for: action.id), actionIcon: action.icon
        ), 0)
    }

    func testCreationSavesTriggersUnderTheRegisteredPresetID() throws {
        let store = MemorySettingsStore()
        let customizations = ActionCustomizationManager(settingsStore: store)
        let shortcut = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])
        let draft = AIPresetDraft(title: "Simplify", prompt: "Use simpler words.", shortcut: shortcut)
        var savedShortcut: KeyboardShortcuts.Shortcut?
        var savedShortcutName: KeyboardShortcuts.Name?
        let preset = try XCTUnwrap(draft.createPreset(
                customizations: customizations,
            saveShortcut: { savedShortcut = $0; savedShortcutName = $1 },
            savePreset: { preset in
                let action = AIAction(presetID: preset.id, title: preset.title)
                XCTAssertEqual(savedShortcutName, .actionHotkey(action.id))
                XCTAssertEqual(customizations.popupIcon(for: action), .text("Simplify"))
            }
        ))
        _ = preset
        XCTAssertEqual(savedShortcut, shortcut)
    }

    func testInvalidDraftsDoNotPersistAnyPartOfAnAction() {
        let store = MemorySettingsStore()
        let customizations = ActionCustomizationManager(settingsStore: store)

        let drafts = [
            AIPresetDraft(title: " \n", prompt: "Prompt"),
            AIPresetDraft(title: "Title", prompt: " \n")
        ]
        for draft in drafts {
            XCTAssertFalse(draft.canCreate())
            XCTAssertNil(draft.createPreset(
                customizations: customizations,
                saveShortcut: { _, _ in XCTFail("Invalid draft must not save a shortcut") },
                savePreset: { _ in XCTFail("Invalid draft must not create a preset") }
            ))
        }
        XCTAssertTrue(customizations.overrides.isEmpty)
    }
}
