// ExtensionsModels.swift
// OpenClip
//
// Defines data transfer objects and models for extension store listings, categories, and download responses.
import Foundation

public struct ExtensionItem: Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let author: String
    public let icon: String
    public let downloadCount: Int
    public let downloadURL: String
    public let version: String?
    /// Normalized currentColor icon SVG URL from the publish pipeline; nil for older snapshots.
    public let iconURL: String?
    /// Last-touch timestamp from catalog.json (moves every release); nil if unavailable.
    public let publishedAt: String?
    /// First-appearance timestamp, stable across releases; nil in older snapshots.
    public let addedAt: String?

    public init(
        id: String,
        name: String,
        description: String,
        author: String,
        icon: String,
        downloadCount: Int,
        downloadURL: String,
        version: String? = nil,
        iconURL: String? = nil,
        publishedAt: String? = nil,
        addedAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.author = author
        self.icon = icon
        self.downloadCount = downloadCount
        self.downloadURL = downloadURL
        self.version = version
        self.iconURL = iconURL
        self.publishedAt = publishedAt
        self.addedAt = addedAt
    }

    public var publishedDate: Date? {
        Self.parsePublishedAt(publishedAt)
    }

    public var addedDate: Date? {
        Self.parsePublishedAt(addedAt)
    }

    /// Accepts ISO 8601 with offset or date-only; anything else is nil rather than a guess.
    public static func parsePublishedAt(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = try? Date(trimmed, strategy: .iso8601) { return date }
        if let date = try? Date(trimmed, strategy: .iso8601.year().month().day()) { return date }
        return nil
    }
}

public struct ExtensionsPageResponse: Sendable, Codable {
    public let extensions: [ExtensionItem]
    public let featured: [ExtensionItem]?
    public let new: [ExtensionItem]?
    public let page: Int
    public let totalPages: Int
    public let totalCount: Int
    
    public init(extensions: [ExtensionItem], featured: [ExtensionItem]? = nil, new: [ExtensionItem]? = nil, page: Int, totalPages: Int, totalCount: Int) {
        self.extensions = extensions
        self.featured = featured
        self.new = new
        self.page = page
        self.totalPages = totalPages
        self.totalCount = totalCount
    }
}
