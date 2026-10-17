import XCTest
@testable import Core

final class SettingsSnapshotTests: XCTestCase {
    func testStandaloneAIPreferencesSurviveExportAndImport() {
        let source = MemorySettingsStore()
        XCTAssertTrue(source.get(.standaloneAIActionIDs).isEmpty)
        source.set(.standaloneAIActionIDs, value: ["ai.preset.rewrite"])
        source.set(.actionOrder, value: ["ai.preset.rewrite", "builtin.copy", "builtin.aiTools"])
        let snapshot = SettingsSnapshotter.capture(store: source, keys: SettingsCatalog.coreKeys, appVersion: "test")
        let destination = MemorySettingsStore()
        SettingsSnapshotter.apply(snapshot, to: destination, keys: SettingsCatalog.coreKeys)
        XCTAssertEqual(destination.get(.standaloneAIActionIDs), ["ai.preset.rewrite"])
        XCTAssertEqual(destination.get(.actionOrder), source.get(.actionOrder))
    }

    private let nameKey = SettingKey<String>("test.snapshot.name", defaultValue: "")
    private let countKey = SettingKey<Int>("test.snapshot.count", defaultValue: 0)
    private let setKey = SettingKey<Set<String>>("test.snapshot.set", defaultValue: [])
    private let dataKey = SettingKey<Data?>("test.snapshot.data", defaultValue: nil)

    private var keys: [AnySettingKey] {
        [nameKey.erased, countKey.erased, setKey.erased, dataKey.erased]
    }

    func testAnySettingKeyRoundTripsTypedValuesIncludingSetAndOptionalData() {
        let store = MemorySettingsStore()
        let payload = Data([1, 2, 3])

        XCTAssertTrue(nameKey.erased.writeJSON(#"{"value":"hello"}"#, to: store))
        XCTAssertTrue(countKey.erased.writeJSON(#"{"value":42}"#, to: store))
        XCTAssertTrue(setKey.erased.writeJSON(#"{"value":["a","b"]}"#, to: store))
        XCTAssertTrue(dataKey.erased.writeJSON(#"{"value":"AQID"}"#, to: store))

        XCTAssertEqual(store.get(nameKey), "hello")
        XCTAssertEqual(store.get(countKey), 42)
        XCTAssertEqual(store.get(setKey), ["a", "b"])
        XCTAssertEqual(store.get(dataKey), payload)
    }

    func testAnySettingKeyRejectsPayloadForWrongType() {
        let store = MemorySettingsStore()
        XCTAssertFalse(countKey.erased.writeJSON(#"{"value":"not-a-number"}"#, to: store))
        XCTAssertEqual(store.get(countKey), 0)
    }

    func testCaptureRetainsEmptyValuesSoRestoreCanClearThem() {
        let store = MemorySettingsStore()
        store.set(nameKey, value: "kept")
        store.set(countKey, value: 0)          // 0 is meaningful
        store.set(setKey, value: [])           // empty set encodes as []
        store.set(dataKey, value: nil)         // nil retained as {"value":null}

        let snapshot = SettingsSnapshotter.capture(
            store: store, keys: keys, appVersion: "test", now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(snapshot.values[nameKey.name], #"{"value":"kept"}"#)
        XCTAssertEqual(snapshot.values[countKey.name], #"{"value":0}"#)
        XCTAssertNotNil(snapshot.values[setKey.name])
        XCTAssertEqual(snapshot.values[dataKey.name], #"{"value":null}"#)
        XCTAssertEqual(snapshot.appVersion, "test")
        XCTAssertEqual(snapshot.schemaVersion, SettingsSnapshot.currentSchemaVersion)
    }

    func testApplyClearsDestinationValuesTheSnapshotHoldsEmpty() {
        let source = MemorySettingsStore()
        source.set(dataKey, value: nil)
        let snapshot = SettingsSnapshotter.capture(store: source, keys: keys, appVersion: "test")

        let destination = MemorySettingsStore()
        destination.set(dataKey, value: Data([1, 2]))
        destination.set(nameKey, value: "old")

        SettingsSnapshotter.apply(snapshot, to: destination, keys: keys)

        XCTAssertNil(destination.get(dataKey), "empty snapshot value must clear the destination")
        XCTAssertEqual(destination.get(nameKey), "")
    }

    func testStringOrBoolKeyPreservesDisabledSentinel() {
        let store = MemorySettingsStore()
        let key = AnySettingKey.stringOrBoolKey(named: "KeyboardShortcuts_test")

        XCTAssertEqual(key.readJSON(from: store), #"{"value":null}"#)

        XCTAssertTrue(key.writeJSON(#"{"value":false}"#, to: store))
        XCTAssertEqual(store.rawObject(forKey: "KeyboardShortcuts_test") as? Bool, false)
        XCTAssertEqual(key.readJSON(from: store), #"{"value":false}"#)

        XCTAssertTrue(key.writeJSON(#"{"value":"{\"carbonKeyCode\":18}"}"#, to: store))
        XCTAssertEqual(store.rawObject(forKey: "KeyboardShortcuts_test") as? String, #"{"carbonKeyCode":18}"#)

        XCTAssertTrue(key.writeJSON(#"{"value":null}"#, to: store))
        XCTAssertNil(store.rawObject(forKey: "KeyboardShortcuts_test"))
    }

    func testApplyRestoresValuesIntoAFreshStore() {
        let source = MemorySettingsStore()
        source.set(nameKey, value: "hello")
        source.set(countKey, value: 7)
        source.set(setKey, value: ["x", "y"])
        source.set(dataKey, value: Data([9, 9]))

        let snapshot = SettingsSnapshotter.capture(store: source, keys: keys, appVersion: "test")

        let destination = MemorySettingsStore()
        let result = SettingsSnapshotter.apply(snapshot, to: destination, keys: keys)

        XCTAssertEqual(result.applied, 4)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertEqual(destination.get(nameKey), "hello")
        XCTAssertEqual(destination.get(countKey), 7)
        XCTAssertEqual(destination.get(setKey), ["x", "y"])
        XCTAssertEqual(destination.get(dataKey), Data([9, 9]))
    }

    func testApplyReportsUnknownSnapshotKeysAndSkipsThem() {
        let store = MemorySettingsStore()
        let snapshot = SettingsSnapshot(createdAt: Date(), appVersion: "test",
                                        values: ["test.snapshot.name": #"{"value":"kept"}"#,
                                                 "some.removed.key": #"{"value":1}"#],
                                        metadata: [:])

        let result = SettingsSnapshotter.apply(snapshot, to: store, keys: keys)

        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.skipped, ["some.removed.key"])
        XCTAssertEqual(store.get(nameKey), "kept")
    }

    func testSnapshotEncodesAndDecodesThroughJSON() throws {
        let store = MemorySettingsStore()
        store.set(nameKey, value: "round-trip")
        let snapshot = SettingsSnapshotter.capture(store: store, keys: keys, appVersion: "test")

        let data = try snapshot.encoded()
        let decoded = try SettingsSnapshot.decode(data)

        XCTAssertEqual(decoded.values, snapshot.values)
        XCTAssertEqual(decoded.appVersion, "test")
    }

    func testAppEnabledSurvivesExportAndImport() {
        let source = MemorySettingsStore()
        XCTAssertTrue(source.get(.isAppEnabled))
        source.set(.isAppEnabled, value: false)
        let snapshot = SettingsSnapshotter.capture(store: source, keys: SettingsCatalog.coreKeys, appVersion: "test")
        let destination = MemorySettingsStore()
        SettingsSnapshotter.apply(snapshot, to: destination, keys: SettingsCatalog.coreKeys)
        XCTAssertFalse(destination.get(.isAppEnabled))
    }

    func testCoreCatalogNamesAreUnique() {
        let names = SettingsCatalog.coreKeys.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "duplicate key names in SettingsCatalog.coreKeys")
        XCTAssertFalse(names.contains { $0.hasPrefix("__openclip.settings.metadata") })
    }
}
