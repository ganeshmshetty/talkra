// NamedServiceAction.swift
// OpenClip
//
// Implements the `service` extension runtime. With `serviceName`, tries a native sharing service
// by identifier, then falls back to `NSPerformService` on an isolated pasteboard so the global
// clipboard is untouched. Without it, shows the generic share picker (`.showServices`).
import Foundation
import AppKit
import Core

public struct NamedServiceAction: ConfigurableAction, ActionWithRules {
    public let id: String
    public let title: String
    public let icon: ActionIcon
    public let serviceName: String?
    public let chrome: ActionChrome
    public let rules: ExtensionActionRules?
    public var performService: @Sendable (String, NSPasteboard) -> Bool

    public init(
        id: String,
        title: String,
        icon: ActionIcon = .symbol("share"),
        serviceName: String? = nil,
        chrome: ActionChrome? = nil,
        rules: ExtensionActionRules? = nil,
        performService: @escaping @Sendable (String, NSPasteboard) -> Bool = { NSPerformService($0, $1) }
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.serviceName = serviceName
        self.chrome = chrome ?? ActionChrome(badge: .none, rowStyle: .standard, popupBehavior: .perform, source: .extensionPkg(packageID: id))
        self.rules = rules
        self.performService = performService
    }

    @MainActor
    public func isEnabled(for context: ActionContext) -> Bool {
        guard let rules else {
            return !context.selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return rules.resolveVisibility(for: context).enabled
    }

    @MainActor
    public func matchInfo(for context: ActionContext) -> ActionMatchInfo? {
        guard let rules else { return nil }
        return rules.resolveVisibility(for: context).match
    }

    @MainActor
    public func perform(_ context: ActionContext) async throws -> ActionResult {
        let text = context.selection.text
        if let serviceName = serviceName, !serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Native sharing services host their own UI; legacy service-menu names fall back to `performService`.
            if let service = NSSharingService(named: NSSharingService.Name(serviceName)) {
                service.perform(withItems: [text])
                return .none
            }
            // Isolated pasteboard so the global clipboard is not overwritten.
            let pboard = NSPasteboard(name: NSPasteboard.Name("com.openclip.namedService.\(UUID().uuidString)"))
            pboard.clearContents()
            pboard.setString(text, forType: .string)
            if performService(serviceName, pboard) {
                return .none
            } else {
                throw NSError(
                    domain: Constants.actionErrorDomain,
                    code: Int(Constants.actionErrorCode),
                    userInfo: [NSLocalizedDescriptionKey: "Failed to perform system service '\(serviceName)'. Check that the service is enabled in System Settings."]
                )
            }
        }
        return .showServices(text)
    }
}