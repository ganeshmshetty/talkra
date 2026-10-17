// SettingsStore.swift
// OpenClip
//
// Defines the central SettingsStore protocol and DefaultSettingsStore adapter for typed application configuration management through the Settings Door.
import Foundation
import Combine

public protocol SettingsStore: AnyObject, Sendable {
    func get<T>(_ key: SettingKey<T>) -> T
    func set<T>(_ key: SettingKey<T>, value: T)
    func publisher<T>(for key: SettingKey<T>) -> AnyPublisher<T, Never>
    /// Change-tracking info, or `nil` if never written through this store.
    func metadata<T>(for key: SettingKey<T>) -> SettingMetadata?
    /// Raw stored value, bypassing typed decoding. Escape hatch for third-party-owned keys only;
    /// prefer typed `get`/`set`.
    func rawObject(forKey name: String) -> Any?
    /// Writes a raw value, or removes the key when `nil`.
    func setRawObject(_ value: Any?, forKey name: String)
}

public final class DefaultSettingsStore: SettingsStore, @unchecked Sendable {
    public static let shared = DefaultSettingsStore(backend: UserDefaultsBackend())
    private let backend: SettingsBackend
    // PassthroughSubject is not thread-safe, so sends are serialized under a recursive `lock`
    // (subscribers may call `set` during dispatch). The backend is thread-safe and stays unlocked.
    private let lock = NSRecursiveLock()
    private let subject = PassthroughSubject<String, Never>()

    public init(backend: SettingsBackend) {
        self.backend = backend
    }

    public convenience init(userDefaults: UserDefaults = .standard) {
        self.init(backend: UserDefaultsBackend(userDefaults: userDefaults))
    }

    public func get<T>(_ key: SettingKey<T>) -> T {
        // Conditional casts with defaultValue fallback: stored prefs may be corrupt; never crash.
        if T.self == Set<String>.self {
            let array = backend.stringArray(forKey: key.name) ?? []
            return (Set(array) as? T) ?? key.defaultValue
        }
        if T.self == Data?.self {
            return (backend.data(forKey: key.name) as? T) ?? key.defaultValue
        }
        return (backend.object(forKey: key.name) as? T) ?? key.defaultValue
    }

    public func set<T>(_ key: SettingKey<T>, value: T) {
        lock.lock()
        defer { lock.unlock() }
        if let setVal = value as? Set<String> {
            backend.set(Array(setVal), forKey: key.name)
        } else {
            backend.set(value, forKey: key.name)
        }
        var metadata = loadMetadataLocked()
        metadata[key.name] = SettingMetadata(version: key.schemaVersion, lastModified: Date())
        saveMetadataLocked(metadata)
        subject.send(key.name)
    }

    public func metadata<T>(for key: SettingKey<T>) -> SettingMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return loadMetadataLocked()[key.name]
    }

    public func rawObject(forKey name: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return backend.object(forKey: name)
    }

    public func setRawObject(_ value: Any?, forKey name: String) {
        lock.lock()
        defer { lock.unlock() }
        backend.set(value, forKey: name)
    }

    private func loadMetadataLocked() -> [String: SettingMetadata] {
        guard let data = backend.data(forKey: SettingMetadata.storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: SettingMetadata].self, from: data)) ?? [:]
    }

    private func saveMetadataLocked(_ metadata: [String: SettingMetadata]) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        backend.set(data, forKey: SettingMetadata.storageKey)
    }

    public func publisher<T>(for key: SettingKey<T>) -> AnyPublisher<T, Never> {
        subject
            .filter { $0 == key.name }
            .map { [weak self] _ in self?.get(key) ?? key.defaultValue }
            .eraseToAnyPublisher()
    }
}
