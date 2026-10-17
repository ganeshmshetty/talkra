// ExtensionActionRules.swift
// OpenClip
//
// Declarative visibility rules the factory attaches to each extension action; consumed by
// ActionVisibility. Codable and Equatable so rules can ride on CustomAction for the shellInline path.
import Foundation

public struct ExtensionActionRules: Codable, Sendable, Equatable {
    public let requirements: ActionRequirements?
    public let legacyRegex: String?
    /// Compiled from `requirements.expression` by the factory; skipped by Codable. nil means no expression gate.
    public let compiledExpression: ValidateExpression?

    public init(
        requirements: ActionRequirements? = nil,
        legacyRegex: String? = nil,
        compiledExpression: ValidateExpression? = nil
    ) {
        self.requirements = requirements
        self.legacyRegex = legacyRegex
        self.compiledExpression = compiledExpression
    }

    /// Shared enablement entry point for extension actions.
    @MainActor
    public func resolveVisibility(for context: ActionContext) -> (enabled: Bool, match: ActionMatchInfo) {
        ActionVisibility.isEnabled(
            requirements: requirements,
            legacyRegex: legacyRegex,
            expression: compiledExpression,
            context: context
        )
    }

    private enum CodingKeys: String, CodingKey {
        case requirements, legacyRegex
    }

    // Encode only the declarative fields; the factory recompiles `compiledExpression` from its source.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requirements = try container.decodeIfPresent(ActionRequirements.self, forKey: .requirements)
        self.legacyRegex = try container.decodeIfPresent(String.self, forKey: .legacyRegex)
        self.compiledExpression = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(requirements, forKey: .requirements)
        try container.encodeIfPresent(legacyRegex, forKey: .legacyRegex)
    }
}
