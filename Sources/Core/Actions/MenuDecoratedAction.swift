// MenuDecoratedAction.swift
// OpenClip
//
// Pure Core wrapper that stamps an optional menu relevance regex onto an action without changing its
// identity: id, chrome, enablement and perform forward to the base, so registry sorting is unaffected.
import Foundation

public struct MenuDecoratedAction: Action, RelevanceProviding {
    public let base: any Action
    public let menuRelevanceRegex: String?

    public init(
        base: any Action,
        menuRelevanceRegex: String? = nil
    ) {
        self.base = base
        self.menuRelevanceRegex = menuRelevanceRegex
    }

    // MARK: - Action (forwarded to base)

    public var id: String { base.id }
    public var title: String { base.title }
    public var icon: ActionIcon { base.icon }
    public var chrome: ActionChrome { base.chrome }
    public var actionOptions: [ExtensionOption] { base.actionOptions }

    /// Forwards the base's delivery so this decorator never shadows it with the protocol's nil default.
    public var delivery: ActionDelivery? { base.delivery }
    public var keywords: [String] { base.keywords }

    @MainActor
    public func isEnabled(for context: ActionContext) -> Bool {
        base.isEnabled(for: context)
    }

    @MainActor
    public func matchInfo(for context: ActionContext) -> ActionMatchInfo? {
        base.matchInfo(for: context)
    }

    @MainActor
    public func perform(_ context: ActionContext) async throws -> ActionResult {
        try await base.perform(context)
    }

    // MARK: - RelevanceProviding

    /// Relevant unless the trimmed selection misses the regex; a malformed regex counts as relevant.
    public func isRelevant(for text: String) -> Bool {
        guard let regex = menuRelevanceRegex, !regex.isEmpty else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let pattern = try? NSRegularExpression(
                  pattern: regex,
                  options: [.dotMatchesLineSeparators, .caseInsensitive]
              ) else {
            return true
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return pattern.firstMatch(in: trimmed, options: [], range: range) != nil
    }
}

extension MenuDecoratedAction: ConfigurableAction {
    public var preferenceIconName: String {
        if let configurable = base as? any ConfigurableAction {
            return configurable.preferenceIconName
        }
        switch base.icon {
        case .symbol(let name):
            return name
        case .local(let url):
            return url.lastPathComponent
        case .url(let url):
            return url.absoluteString
        case .text(let txt):
            return txt
        }
    }
}