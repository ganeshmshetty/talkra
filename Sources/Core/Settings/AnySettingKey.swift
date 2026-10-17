// AnySettingKey.swift
// OpenClip
//
// Type-erased handle to a `SettingKey`, so settings can be enumerated without knowing their value
// types. Powers snapshot/export/import and diagnostics: each value crosses the erasure boundary as
// a JSON string, which the concrete `SettingKey` decodes back into its typed value.
import Foundation

/// Boxes an optional so `nil` can be encoded inside a keyed container.
private struct Box<Wrapped: Codable>: Codable {
    let value: Wrapped
}

public struct AnySettingKey: @unchecked Sendable {
    public let name: String
    public let schemaVersion: Int

    private let readJSONBody: @Sendable (SettingsStore) -> String?
    private let writeJSONBody: @Sendable (SettingsStore, String) -> Bool
    private let readMetadataBody: @Sendable (SettingsStore) -> SettingMetadata?

    init(
        name: String,
        schemaVersion: Int,
        readJSON: @escaping @Sendable (SettingsStore) -> String?,
        writeJSON: @escaping @Sendable (SettingsStore, String) -> Bool,
        readMetadata: @escaping @Sendable (SettingsStore) -> SettingMetadata?
    ) {
        self.name = name
        self.schemaVersion = schemaVersion
        self.readJSONBody = readJSON
        self.writeJSONBody = writeJSON
        self.readMetadataBody = readMetadata
    }

    /// The current value as a JSON string, or `nil` if it cannot be encoded.
    public func readJSON(from store: SettingsStore) -> String? {
        readJSONBody(store)
    }

    /// Writes a JSON string produced by `readJSON` back into the store. Returns `false` if the
    /// payload does not decode to this key's type.
    @discardableResult
    public func writeJSON(_ json: String, to store: SettingsStore) -> Bool {
        writeJSONBody(store, json)
    }

    public func readMetadata(from store: SettingsStore) -> SettingMetadata? {
        readMetadataBody(store)
    }
}

/// A raw stored value that may be a String, a Bool (e.g. `false` meaning "disabled"), or absent.
private enum StringOrBool: Codable {
    case string(String)
    case bool(Bool)
    case none

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.typeMismatch(
                StringOrBool.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "expected String, Bool, or null")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .none: try container.encodeNil()
        }
    }
}

private struct StringOrBoolBox: Codable {
    let value: StringOrBool
}

public extension AnySettingKey {
    /// Key for third-party values stored as a raw String or Bool (a shortcut is a String, or Bool `false` when disabled).
    /// Keeping the Bool stops a restore from re-enabling a shortcut the user turned off.
    static func stringOrBoolKey(named name: String) -> AnySettingKey {
        AnySettingKey(
            name: name,
            schemaVersion: 1,
            readJSON: { store in
                guard let raw = store.rawObject(forKey: name) else {
                    return #"{"value":null}"#
                }
                if let bool = raw as? Bool {
                    return bool ? #"{"value":true}"# : #"{"value":false}"#
                }
                if let string = raw as? String,
                   let data = try? JSONEncoder().encode(string) {
                    return "{\"value\":\(String(data: data, encoding: .utf8) ?? "null")}"
                }
                return nil
            },
            writeJSON: { store, json in
                guard let data = json.data(using: .utf8),
                      let box = try? JSONDecoder().decode(StringOrBoolBox.self, from: data) else {
                    return false
                }
                switch box.value {
                case .string(let value): store.setRawObject(value, forKey: name)
                case .bool(let value): store.setRawObject(value, forKey: name)
                case .none: store.setRawObject(nil, forKey: name)
                }
                return true
            },
            readMetadata: { _ in nil }
        )
    }
}

public extension SettingKey where Value: Codable {
    /// Type-erased view of this key for cataloging.
    var erased: AnySettingKey {
        AnySettingKey(
            name: name,
            schemaVersion: schemaVersion,
            readJSON: { store in
                guard let data = try? JSONEncoder().encode(Box(value: store.get(self))) else { return nil }
                return String(data: data, encoding: .utf8)
            },
            writeJSON: { store, json in
                guard let data = json.data(using: .utf8),
                      let box = try? JSONDecoder().decode(Box<Value>.self, from: data) else { return false }
                store.set(self, value: box.value)
                return true
            },
            readMetadata: { store in store.metadata(for: self) }
        )
    }
}
