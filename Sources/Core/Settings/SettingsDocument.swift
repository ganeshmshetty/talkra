// SettingsDocument.swift
// OpenClip
//
// Versioned envelope for structured settings blobs (custom actions, groups, per-action overrides).
// Wrapping a payload with its schema version lets the shape change later without losing data, and
// gives list-shaped values an explicit document boundary instead of an anonymous encoded lump.
import Foundation

public struct SettingsDocument<Payload: Codable & Sendable>: Codable, Sendable {
    public let schemaVersion: Int
    public let payload: Payload

    public init(schemaVersion: Int = 1, payload: Payload) {
        self.schemaVersion = schemaVersion
        self.payload = payload
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decodes a document written by `encoded()`, or falls back to decoding `data` as a bare
    /// `Payload` written by a build that predates the envelope. Returns `nil` for empty data.
    public static func decode(from data: Data) throws -> SettingsDocument<Payload>? {
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(SettingsDocument<Payload>.self, from: data) {
            return document
        }
        if let legacy = try? decoder.decode(Payload.self, from: data) {
            return SettingsDocument(schemaVersion: 1, payload: legacy)
        }
        return nil
    }
}
