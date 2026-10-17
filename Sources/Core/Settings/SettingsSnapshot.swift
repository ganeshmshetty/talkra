// SettingsSnapshot.swift
// OpenClip
//
// Portable, versioned snapshot of every catalog setting (JSON string values plus change metadata), the
// unit for backup, export/import and diagnostics. Only catalog keys are read or written.
import Foundation

public struct SettingsSnapshot: Codable, Sendable {
    /// Bump when the snapshot container format changes (independent of individual key versions).
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let createdAt: Date
    public let appVersion: String
    /// setting name -> JSON-encoded value
    public let values: [String: String]
    /// setting name -> change metadata
    public let metadata: [String: SettingMetadata]

    public init(
        schemaVersion: Int = SettingsSnapshot.currentSchemaVersion,
        createdAt: Date,
        appVersion: String,
        values: [String: String],
        metadata: [String: SettingMetadata]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.values = values
        self.metadata = metadata
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SettingsSnapshot {
        try JSONDecoder().decode(SettingsSnapshot.self, from: data)
    }
}

public struct SettingsApplyResult: Sendable, Equatable {
    public let applied: Int
    /// Names present in the snapshot but not applicable to this build (unknown or undecodable).
    public let skipped: [String]

    public init(applied: Int, skipped: [String]) {
        self.applied = applied
        self.skipped = skipped
    }
}

public enum SettingsSnapshotter {
    /// Reads every catalog key, empty values included, so a restore can clear a value as well as set one.
    public static func capture(
        store: SettingsStore,
        keys: [AnySettingKey],
        appVersion: String,
        now: Date = Date()
    ) -> SettingsSnapshot {
        var values: [String: String] = [:]
        var metadata: [String: SettingMetadata] = [:]
        for key in keys {
            if let json = key.readJSON(from: store) {
                values[key.name] = json
            }
            if let meta = key.readMetadata(from: store) {
                metadata[key.name] = meta
            }
        }
        return SettingsSnapshot(
            createdAt: now,
            appVersion: appVersion,
            values: values,
            metadata: metadata
        )
    }

    /// Writes known values into the store; names the catalog does not know are reported as skipped.
    @discardableResult
    public static func apply(
        _ snapshot: SettingsSnapshot,
        to store: SettingsStore,
        keys: [AnySettingKey]
    ) -> SettingsApplyResult {
        var applied = 0
        let known = Set(keys.map(\.name))
        // Names the snapshot carries that this build does not know about (removed/renamed keys).
        var skipped = Set(snapshot.values.keys).subtracting(known)
        for key in keys {
            guard let json = snapshot.values[key.name] else { continue }
            if key.writeJSON(json, to: store) {
                applied += 1
            } else {
                skipped.insert(key.name)
            }
        }
        return SettingsApplyResult(applied: applied, skipped: skipped.sorted())
    }
}
