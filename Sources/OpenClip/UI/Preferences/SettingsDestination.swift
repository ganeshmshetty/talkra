// SettingsDestination.swift
// OpenClip
//
// Where an action's settings live in the Settings window, as a router path. Every surface that
// points at an action asks here, so the answer is the same everywhere.

import Core

enum SettingsDestination {
    /// True for user-created actions (Open URL, Text Snippet, Shell Script).
    static func isCustomAction(_ action: any Action) -> Bool {
        guard action.chrome.rowStyle != .actionGroup else { return false }
        if case .custom = action.chrome.source { return true }
        if let packageID = ActionIdentity.extensionPackageID(of: action),
           InstalledExtensionInfo.isCustomPackage(packageID) {
            return true
        }
        return action is CustomAction
    }

    /// The path that shows `action`'s settings.
    /// AI prompts live under AI; extension commands under their extension's page; custom groups
    /// and custom actions under Shortcuts and Custom Actions; built-ins have their own row.
    @MainActor
    static func path(for action: any Action) -> [SettingsPage] {
        if action.chrome.launchesAI {
            return [.ai]
        }
        if ActionIdentity.isAIPreset(action) {
            if let preset = AIServiceManager.shared.preset(forActionID: action.id) {
                return [.ai, .aiPreset(id: preset.id)]
            }
            return [.ai]
        }
        if let gated = action as? GatedExtensionAction {
            return [.extensionPackage(id: gated.packageID)]
        }
        if let packageID = ActionIdentity.extensionPackageID(of: action),
           case .extensionPkg = action.chrome.source,
           !InstalledExtensionInfo.isCustomPackage(packageID) {
            if action.chrome.popupBehavior == .showSubActions {
                return [.extensionPackage(id: packageID)]
            }
            if let info = InstalledExtensionInfo.info(for: packageID, in: ActionCoordinator.shared.actions),
               info.commands.count == 1,
               !info.isGroup {
                return [.extensionPackage(id: packageID)]
            }
            return [.extensionPackage(id: packageID), .action(id: action.id)]
        }
        if action.chrome.rowStyle == .actionGroup {
            return [.shortcuts, .action(id: action.id)]
        }
        if isCustomAction(action) {
            return [.customActions, .action(id: action.id)]
        }
        if ActionIdentity.isBuiltin(action) {
            return [.builtinAction(id: action.id)]
        }
        return [.shortcuts, .action(id: action.id)]
    }

    static func path(forPackage packageID: String) -> [SettingsPage] {
        [.extensionPackage(id: packageID)]
    }

    @MainActor
    static func open(_ action: any Action) {
        SettingsRouter.shared.show(path: path(for: action))
    }
}
