// Setting.swift
// OpenClip
//
// SwiftUI property wrapper that binds a view to a SettingKey through SettingsStore. Replaces
// direct @AppStorage access so every read and write goes through the same door as the rest of
// the app (and, later, through whatever backend that door is pointed at).
import SwiftUI
import Combine
import Core

/// Change trigger between one `SettingKey` and a SwiftUI view. The value is always read live from
/// the store; this object exists only to invalidate the view when the store publishes a change for
/// the key, so a write made anywhere in the app refreshes every observer of that key.
final class SettingsObservation<T: Sendable>: ObservableObject {
    @Published private(set) var revision: Int = 0
    private let key: SettingKey<T>
    private let store: SettingsStore
    private var cancellable: AnyCancellable?

    init(key: SettingKey<T>, store: SettingsStore = DefaultSettingsStore.shared) {
        self.key = key
        self.store = store
        self.cancellable = store.publisher(for: key)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.revision &+= 1
            }
    }

    func current() -> T {
        store.get(key)
    }

    func setValue(_ newValue: T) {
        store.set(key, value: newValue)
        revision &+= 1
    }
}

/// Binds a view property to a `SettingKey`, reading and writing through `SettingsStore`.
///
///     @Setting(SettingKey.popupTheme) private var theme
///
/// Use `$theme` for a `Binding`, matching `@AppStorage`'s ergonomics.
@propertyWrapper
struct Setting<T: Sendable>: DynamicProperty {
    @StateObject private var observation: SettingsObservation<T>

    init(_ key: SettingKey<T>, store: SettingsStore = DefaultSettingsStore.shared) {
        _observation = StateObject(wrappedValue: SettingsObservation(key: key, store: store))
    }

    var wrappedValue: T {
        get { observation.current() }
        nonmutating set { observation.setValue(newValue) }
    }

    var projectedValue: Binding<T> {
        Binding(get: { observation.current() }, set: { observation.setValue($0) })
    }
}
