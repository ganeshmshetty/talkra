// AIToolsAction.swift
// OpenClip
//
// The "AI Tools" launcher, modeled as a normal reorderable builtin action so users can position
// it among their other actions. Its group holds the registered AI presets; voice matching,
// per-action hotkeys, and the flat catalog all exclude it (`chrome.launchesAI`). Its enable state
// is single-sourced to `AIServiceManager.isAIEnabled`, which the AI-tab and Actions-tab toggles share.
import Foundation
import Core

public struct AIToolsAction: Action, SubActionProviding {
    private let settingsStore: any SettingsStore

    public init(settingsStore: any SettingsStore = DefaultSettingsStore.shared) {
        self.settingsStore = settingsStore
    }

    public var id: String { "builtin.aiTools" }
    public var title: String { String(localized: "AI Tools") }
    public var icon: ActionIcon { .symbol(Constants.defaultAIIconSymbol) }
    public var chrome: ActionChrome {
        ActionChrome(badge: .none, rowStyle: .standard, popupBehavior: .perform, source: .builtin, launchesAI: true)
    }

    @MainActor
    public func isEnabled(for context: ActionContext) -> Bool {
        settingsStore.get(.isAIEnabled)
    }

    /// Defensive fallback: voice, hotkeys, and the flat catalog exclude this launcher, so `perform`
    /// is never the entry point (same contract as `AIAction`).
    @MainActor
    public func perform(_ context: ActionContext) async throws -> ActionResult {
        .success
    }

    // The AI Tools launcher's sub-actions are the registered AI presets (chrome source `.ai`).
    @MainActor
    public func subActions(in catalog: [any Action]) -> [any Action] {
        let standaloneIDs = settingsStore.get(.standaloneAIActionIDs)
        return catalog.filter { action in
            ActionIdentity.isAIPreset(action) && !standaloneIDs.contains(action.id)
        }
    }
}
