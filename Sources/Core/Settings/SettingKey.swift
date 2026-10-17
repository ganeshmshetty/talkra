// SettingKey.swift
// OpenClip
//
// Defines strongly-typed setting keys and default values for central configuration management via the Settings Door.
import Foundation

public struct SettingKey<Value: Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value
    /// Bumped when the stored value's shape changes, so a migration can tell old data from new.
    public let schemaVersion: Int

    public init(_ name: String, defaultValue: Value, schemaVersion: Int = 1) {
        self.name = name
        self.defaultValue = defaultValue
        self.schemaVersion = schemaVersion
    }
}

/// Per-action option namespace: `defaultsKey` and `keychainAccount` yield the same string; secrets never touch UserDefaults.
public enum ActionOptionKey {
    public static func defaultsKey(actionID: String, optionID: String) -> String {
        "action.\(actionID).option.\(optionID)"
    }

    public static func keychainAccount(actionID: String, optionID: String) -> String {
        defaultsKey(actionID: actionID, optionID: optionID)
    }
}

/// Sparkle update feed. Beta uses a separate appcast, so opting in never affects stable users.
public enum UpdateChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case beta
}

public extension SettingKey where Value == [String] {
    static var actionOrder: SettingKey<[String]> { SettingKey<[String]>("action.order", defaultValue: []) }
}

public extension SettingKey where Value == Set<String> {
    static var standaloneAIActionIDs: SettingKey<Set<String>> { SettingKey<Set<String>>("standaloneAIActionIDs", defaultValue: []) }
    static var disabledActionIDs: SettingKey<Set<String>> { SettingKey<Set<String>>("disabledActionIDs", defaultValue: []) }
    static var disabledPackages: SettingKey<Set<String>> { SettingKey<Set<String>>("disabledPackages", defaultValue: []) }
}

public extension SettingKey where Value == [String: [String]] {
    static var extensionGroupMemberOrder: SettingKey<[String: [String]]> { SettingKey<[String: [String]]>("extensionGroupMemberOrder", defaultValue: [:]) }
}

public extension SettingKey where Value == [String: String] {
    /// packageID -> "seen" | "trusted" | "revoked"
    static var extensionTrust: SettingKey<[String: String]> { SettingKey<[String: String]>("extension.trust", defaultValue: [:]) }
    /// packageID -> content hash recorded at enable time (tamper-watch baseline)
    static var extensionTrustHashes: SettingKey<[String: String]> { SettingKey<[String: String]>("extension.trustHashes", defaultValue: [:]) }
    /// packageID -> "store" | "local"
    static var extensionSources: SettingKey<[String: String]> { SettingKey<[String: String]>("extension.sources", defaultValue: [:]) }
    /// actionID -> lowercase exact-match search alias
}

public extension SettingKey where Value == Bool {
    static var isAppEnabled: SettingKey<Bool> { SettingKey<Bool>("isAppEnabled", defaultValue: true) }
    static var isAIEnabled: SettingKey<Bool> { SettingKey<Bool>("aiEnabled", defaultValue: true) }
    static var isMouseHoldEnabled: SettingKey<Bool> { SettingKey<Bool>("isMouseHoldEnabled", defaultValue: true) }
    static var hasCompletedOnboarding: SettingKey<Bool> { SettingKey<Bool>("hasCompletedOnboarding", defaultValue: false) }
    /// Once dismissed by any path, the post-onboarding coach-mark never shows again.
    static var hasDismissedPostOnboardingCoachMark: SettingKey<Bool> { SettingKey<Bool>("hasDismissedPostOnboardingCoachMark", defaultValue: false) }
    static var startAtLogin: SettingKey<Bool> { SettingKey<Bool>("startAtLogin", defaultValue: false) }
    static var captureTextAutoCopy: SettingKey<Bool> { SettingKey<Bool>("captureTextAutoCopy", defaultValue: true) }
    static var completionCopyToClipboard: SettingKey<Bool> { SettingKey<Bool>("completionCopyToClipboard", defaultValue: false) }
    /// True once the one-time migration (auto-trust existing installs) has run.
    static var extensionTrustMigrated: SettingKey<Bool> { SettingKey<Bool>("extension.trustMigrated", defaultValue: false) }
    static var automaticallyChecksForUpdates: SettingKey<Bool> { SettingKey<Bool>("automaticallyChecksForUpdates", defaultValue: true) }
    static var automaticallyDownloadsUpdates: SettingKey<Bool> { SettingKey<Bool>("automaticallyDownloadsUpdates", defaultValue: false) }
    static var automaticallyUpdatesExtensions: SettingKey<Bool> { SettingKey<Bool>("extension.automaticallyUpdates", defaultValue: true) }
    static var notifyOnUpdate: SettingKey<Bool> { SettingKey<Bool>("notifyOnUpdate", defaultValue: true) }
}

public extension SettingKey where Value == Int {
    /// Visual scaling level for the popup from 1 to 5 (3 = Normal / Default).
    static var popupScale: SettingKey<Int> { SettingKey<Int>("popupScale", defaultValue: 3) }
}

public extension SettingKey where Value == Double {
    /// Duration in seconds the mouse must be held down to trigger the popup (0.0 = disabled).
    static var mouseHoldDuration: SettingKey<Double> { SettingKey<Double>("mouseHoldDuration", defaultValue: 0.3) }
    /// Timestamp (seconds since 1970) until which OpenClip is temporarily paused (0.0 = not paused).
    static var pauseUntilTimestamp: SettingKey<Double> { SettingKey<Double>("pauseUntilTimestamp", defaultValue: 0.0) }
}

public extension SettingKey where Value == Data? {
    static var actionCustomizations: SettingKey<Data?> { SettingKey<Data?>("action.customizations", defaultValue: nil) }
    static var actionGroups: SettingKey<Data?> { SettingKey<Data?>("action.groups", defaultValue: nil) }
    static var customActions: SettingKey<Data?> { SettingKey<Data?>("customActions", defaultValue: nil) }
}

public extension SettingKey where Value == String {
    static var lastAppUpdateNotificationIdentifier: SettingKey<String> { SettingKey<String>("lastAppUpdateNotificationIdentifier", defaultValue: "") }
    static var lastAnnouncedAppUpdateVersion: SettingKey<String> { SettingKey<String>("lastAnnouncedAppUpdateVersion", defaultValue: "") }
    static var calendarProvider: SettingKey<String> { SettingKey<String>("action.calendar.provider", defaultValue: "native") }
    static var searchURL: SettingKey<String> { SettingKey<String>("action.search.url", defaultValue: "https://www.google.com/search?q={query}") }


    /// Default directory where action file outputs are saved. Defaults to empty string (which resolves to ~/Downloads).
    static var fileSaveLocation: SettingKey<String> { SettingKey<String>("fileSaveLocation", defaultValue: "") }

    static var popupThemeColor: SettingKey<String> { SettingKey<String>("popupThemeColor", defaultValue: "system") }

    /// Last launched CFBundleShortVersionString; used to classify launch scenarios.
    static var lastRunVersion: SettingKey<String> { SettingKey<String>("app.lastRunVersion", defaultValue: "") }
    /// The last build number (CFBundleVersion) the app was launched on.
    static var lastRunBuild: SettingKey<String> { SettingKey<String>("app.lastRunBuild", defaultValue: "") }

    /// Which update feed the app follows: `UpdateChannel.stable` (default) or `UpdateChannel.beta`.
    static var updateChannel: SettingKey<String> { SettingKey<String>("updates.channel", defaultValue: UpdateChannel.stable.rawValue) }

    /// Matches the legacy `action.<id>.option.<optID>` key so stored values migrate unchanged.
    static func actionOption(actionID: String, optionID: String, default defaultValue: String = "") -> SettingKey<String> {
        SettingKey<String>("action.\(actionID).option.\(optionID)", defaultValue: defaultValue)
    }
}
