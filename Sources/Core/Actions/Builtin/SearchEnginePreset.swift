// SearchEnginePreset.swift
// OpenClip
//
// Curated one-click search engine presets for the built-in Search action. The configured value stays
// the `{query}` URL template, so a template matching no preset renders as "Custom" with no migration.
import Foundation

public struct SearchEnginePreset: Sendable, Equatable, Identifiable {
    /// Stable identifier used as the picker tag (e.g. "google", "kagi").
    public let id: String
    public let displayName: String
    /// The `{query}` URL template that SearchAction resolves against selected text.
    public let urlTemplate: String

    public init(id: String, displayName: String, urlTemplate: String) {
        self.id = id
        self.displayName = displayName
        self.urlTemplate = urlTemplate
    }

    // MARK: - Curated presets

    public static let google = SearchEnginePreset(
        id: "google",
        displayName: String(localized: "Google"),
        urlTemplate: "https://www.google.com/search?q={query}"
    )
    public static let duckduckgo = SearchEnginePreset(
        id: "duckduckgo",
        displayName: String(localized: "DuckDuckGo"),
        urlTemplate: "https://duckduckgo.com/?q={query}"
    )
    public static let kagi = SearchEnginePreset(
        id: "kagi",
        displayName: String(localized: "Kagi"),
        urlTemplate: "https://kagi.com/search?q={query}"
    )
    public static let brave = SearchEnginePreset(
        id: "brave",
        displayName: String(localized: "Brave Search"),
        urlTemplate: "https://search.brave.com/search?q={query}"
    )
    public static let bing = SearchEnginePreset(
        id: "bing",
        displayName: String(localized: "Bing"),
        urlTemplate: "https://www.bing.com/search?q={query}"
    )
    public static let ecosia = SearchEnginePreset(
        id: "ecosia",
        displayName: String(localized: "Ecosia"),
        urlTemplate: "https://www.ecosia.org/search?q={query}"
    )
    public static let baidu = SearchEnginePreset(
        id: "baidu",
        displayName: String(localized: "Baidu"),
        urlTemplate: "https://www.baidu.com/s?wd={query}"
    )
    public static let yahooJapan = SearchEnginePreset(
        id: "yahoojapan",
        displayName: String(localized: "Yahoo! JAPAN"),
        urlTemplate: "https://search.yahoo.co.jp/search?p={query}"
    )

    /// All curated presets, in picker order.
    public static let all: [SearchEnginePreset] = [google, duckduckgo, kagi, brave, bing, ecosia, baidu, yahooJapan]

    /// Default `{query}` template (Google). Single source of truth for the Search action's default.
    public static let defaultURLTemplate = google.urlTemplate

    // MARK: - Lookup

    /// Exact match only: a hand-edited variant (e.g. appending `&hl=en`) is Custom, not snapped back to the preset.
    public static func preset(matching template: String) -> SearchEnginePreset? {
        all.first { $0.urlTemplate == template }
    }

    public static func preset(id: String) -> SearchEnginePreset? {
        all.first { $0.id == id }
    }
}
