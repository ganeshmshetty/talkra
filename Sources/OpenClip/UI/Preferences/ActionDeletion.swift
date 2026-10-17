// ActionDeletion.swift
// OpenClip
//
// Deletes a custom action, installed extension, or custom group from the Customize list's context
// menu. A custom action also removes its generated manifest package so it cannot re-register.

import Foundation
import Core
import KeyboardShortcuts

enum ActionDeletion {
    /// Custom actions, extensions, groups and AI presets are deletable; built-ins are not.
    static func canDelete(_ action: any Action) -> Bool {
        if action.chrome.rowStyle == .actionGroup { return true }
        switch action.chrome.source {
        case .custom, .extensionPkg: return true
        case .ai: return ActionIdentity.isAIPreset(action)
        case .builtin: return false
        }
    }

    /// Deletes the action with `id`, reporting failures in the settings window.
    @MainActor
    static func delete(actionID id: String) async {
        guard let action = ActionCoordinator.shared.actions.first(where: { $0.id == id }) else { return }

        if action.chrome.rowStyle == .actionGroup {
            if case .extensionPkg = action.chrome.source {
                await uninstall(actionID: ActionIdentity.extensionPackageID(of: action) ?? id)
            } else {
                ActionCoordinator.shared.ungroup(groupID: id)
            }
            return
        }

        switch action.chrome.source {
        case .custom:
            KeyboardShortcuts.reset(.actionHotkey(id))
            ActionCoordinator.shared.deleteCustomAction(actionID: id)
            ActionCustomizationManager.shared.resetOverride(for: id)
            SettingsRouter.shared.clearConfigurationRequest(for: id)
            // Remove the manifest package so it does not reload on the next scan; a legacy store-only action has none (404 is fine).
            await removeManifest(actionID: id)
        case .extensionPkg:
            // Uninstall by package identifier: a command id need not carry the package prefix.
            await uninstall(actionID: ActionIdentity.extensionPackageID(of: action) ?? id)
        case .ai:
            guard let preset = AIServiceManager.shared.preset(forActionID: id) else { return }
            KeyboardShortcuts.reset(.actionHotkey(id))
            ActionCustomizationManager.shared.resetOverride(for: id)
            ActionCoordinator.shared.setAIActionPlacement(actionIDs: [id], standalone: false)
            AIServiceManager.shared.presets.removeAll { $0.id == preset.id }
            AIActionSync.shared.sync()
            SettingsRouter.shared.clearConfigurationRequest(for: id)
        case .builtin:
            break
        }
    }

    @MainActor
    private static func uninstall(actionID id: String) async {
        do {
            try await ExtensionManager.shared.uninstallExtension(actionID: id)
            NotificationCenter.default.post(name: .openClipExtensionsDidChange, object: nil)
        } catch {
            Log.extensions.error("Failed to uninstall extension '\(id, privacy: .public)': \(error.localizedDescription)")
            SettingsRouter.shared.notifyError(
                title: String(localized: "Remove Failed"),
                message: String(localized: "Talkra could not remove extension: \(error.localizedDescription)")
            )
        }
    }

    @MainActor
    private static func removeManifest(actionID id: String) async {
        do {
            try await ExtensionManager.shared.uninstallExtension(actionID: id)
            NotificationCenter.default.post(name: .openClipExtensionsDidChange, object: nil)
        } catch {
            let nsError = error as NSError
            if nsError.domain == "ExtensionManager" && nsError.code == 404 { return }
            Log.extensions.error("Failed to remove custom action on disk '\(id, privacy: .public)': \(error.localizedDescription)")
        }
    }
}
