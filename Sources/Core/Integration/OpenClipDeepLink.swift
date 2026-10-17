// OpenClipDeepLink.swift
// OpenClip
//
// Pure parser for the inbound `openclip://` grammar (fire-and-forget, no return value). The router
// that performs side effects stays in the app target.
//
// Routes (host-based, matching the existing `openclip://install`):
//
//   openclip://install?id=<id>&url=<https-url>[&name=<name>]   install a store extension
//   openclip://command/<name>                                  run an app-level command
//
// No settings read/write route and no x-callback reply: URL schemes are unauthenticated, and
// replies need scheme registration. Values belong in the CLI or App Intents.
import Foundation

/// An app-level verb the integration can invoke. Side effects only, no return value.
public enum IntegrationCommand: String, CaseIterable, Sendable, Equatable {
    case openSettings = "open-settings"
    case pause
    case resume
}

public enum OpenClipDeepLink: Equatable, Sendable {
    case install(id: String, name: String?, downloadURL: URL)
    case command(IntegrationCommand)

    public static let scheme = "talkra"
    /// `openclip` stays accepted so extension catalog install links keep working.
    public static let acceptedSchemes: Set<String> = [scheme, "talkra-dev", "openclip"]

    /// Parses `url`, or returns `nil` when the scheme, host, or required parameters are missing.
    public static func parse(_ url: URL) -> OpenClipDeepLink? {
        guard let urlScheme = url.scheme?.lowercased(), acceptedSchemes.contains(urlScheme),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let items = components.queryItems ?? []

        func value(_ name: String) -> String? {
            items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        switch components.host?.lowercased() {
        case "install":
            guard let id = value("id"), !id.isEmpty,
                  let rawURL = value("url"), let downloadURL = URL(string: rawURL) else {
                return nil
            }
            return .install(id: id, name: value("name"), downloadURL: downloadURL)

        case "command":
            let raw = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let command = IntegrationCommand(rawValue: raw.lowercased()) else { return nil }
            return .command(command)

        default:
            return nil
        }
    }
}
