// AIAction.swift
// OpenClip
//
// Bridges an `AIActionPreset` into the Action registry. The title is snapshotted at registration
// (AIActionSync); enabled state and prompt are read live from AIServiceManager.
import Foundation
import Core

/// Registry action for one AI preset. Voice and per-action hotkey runs route through the popup's AI flow, not `perform`.
public struct AIAction: ConfigurableAction {
    public let presetID: String

    public var id: String { "ai.preset.\(presetID)" }
    public let title: String
    public var preferenceIconName: String { Constants.defaultAIIconSymbol }
    public var icon: ActionIcon { Self.iconForPreset(presetID: presetID, title: title) }

    public static func iconForPreset(presetID: String, title: String? = nil) -> ActionIcon {
        if let title, !title.isEmpty {
            return .text(title)
        }
        switch presetID {
        case "proofread": return .text(String(localized: "Proofread"))
        case "rewrite": return .text(String(localized: "Rewrite"))
        case "summarize": return .text(String(localized: "Summarize"))
        case "explain": return .text(String(localized: "Explain"))
        case "translate": return .text(String(localized: "Translate"))
        case "fix_code": return .text(String(localized: "Fix Code"))
        case "make_shorter": return .text(String(localized: "Make Shorter"))
        case "formal_tone": return .text(String(localized: "Formal Tone"))
        default: return .text(presetID)
        }
    }

    public var chrome: ActionChrome {
        ActionChrome(badge: .none, rowStyle: .standard, popupBehavior: .perform, source: .ai)
    }

    public init(presetID: String, title: String) {
        self.presetID = presetID
        self.title = title
    }

    /// Off when AI is disabled globally or this preset is toggled off; every surface gates on this.
    @MainActor
    public func isEnabled(for context: ActionContext) -> Bool {
        guard AIServiceManager.shared.isAIEnabled else { return false }
        return preset()?.isEnabled ?? false
    }

    /// Defensive fallback; preset runs are routed into the popup's AI flow instead.
    @MainActor
    public func perform(_ context: ActionContext) async throws -> ActionResult {
        .success
    }

    @MainActor
    private func preset() -> AIActionPreset? {
        AIServiceManager.shared.presets.first { $0.id == presetID }
    }
}
