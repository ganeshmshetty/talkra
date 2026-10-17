// SettingMetadata.swift
// OpenClip
//
// Change-tracking metadata stored alongside each setting: the schema version the value was
// written under, and when it was last written. Lets the store evolve setting shapes over time and
// tell which of two writes is newer, without changing the value format itself.
import Foundation

public struct SettingMetadata: Codable, Sendable, Equatable {
    /// The `SettingKey.schemaVersion` this value was written under.
    public let version: Int
    /// When the value was last written.
    public let lastModified: Date

    public init(version: Int, lastModified: Date) {
        self.version = version
        self.lastModified = lastModified
    }

    /// Reserved backend key holding the `[settingName: SettingMetadata]` map. Never surfaced as a
    /// user setting; callers enumerating stored keys must skip it.
    public static let storageKey = "__openclip.settings.metadata"
}
