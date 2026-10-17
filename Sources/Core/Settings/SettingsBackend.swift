// SettingsBackend.swift
// OpenClip
//
// Defines the physical storage seam behind DefaultSettingsStore. All typed value encoding
// happens against this interface, so where settings physically live is an implementation
// detail — swapping the backend changes nothing at any call site or SettingKey declaration.
import Foundation

/// Storage primitives a `SettingsStore` implementation needs. Mirrors the subset of the
/// `UserDefaults` API the store relies on (typed accessors, mutation, enumeration) so a
/// non-UserDefaults backend can be dropped in without changing store logic.
public protocol SettingsBackend: AnyObject, Sendable {
    func object(forKey key: String) -> Any?
    func stringArray(forKey key: String) -> [String]?
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func allKeys() -> [String]
    func dictionaryRepresentation() -> [String: Any]
}

/// The default backend: an app-wide `UserDefaults` domain (production uses `.standard`).
public final class UserDefaultsBackend: SettingsBackend, @unchecked Sendable {
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func object(forKey key: String) -> Any? {
        userDefaults.object(forKey: key)
    }

    public func stringArray(forKey key: String) -> [String]? {
        userDefaults.stringArray(forKey: key)
    }

    public func data(forKey key: String) -> Data? {
        userDefaults.data(forKey: key)
    }

    /// Writing `nil` removes the key (matching `UserDefaults.set(nil, forKey:)`).
    public func set(_ value: Any?, forKey key: String) {
        if let value {
            userDefaults.set(value, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    public func removeObject(forKey key: String) {
        userDefaults.removeObject(forKey: key)
    }

    public func allKeys() -> [String] {
        Array(userDefaults.dictionaryRepresentation().keys)
    }

    public func dictionaryRepresentation() -> [String: Any] {
        userDefaults.dictionaryRepresentation()
    }
}
