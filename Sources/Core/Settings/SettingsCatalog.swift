// SettingsCatalog.swift
// OpenClip
//
// Every known setting in erased form, so snapshot/export/diagnostics can walk them without knowing
// their types. Dynamic per-action keys (`action.<id>.option.<id>`) are not enumerated here.
import Foundation

public enum SettingsCatalog {
    /// Every setting declared in Core.
    public static var coreKeys: [AnySettingKey] {
        [
            // Action ordering / enablement
            SettingKey.actionOrder.erased,
            SettingKey.standaloneAIActionIDs.erased,
            SettingKey.disabledActionIDs.erased,
            SettingKey.disabledPackages.erased,
            SettingKey.extensionGroupMemberOrder.erased,

            // Extensions
            SettingKey.extensionTrust.erased,
            SettingKey.extensionTrustHashes.erased,
            SettingKey.extensionSources.erased,
            SettingKey.extensionTrustMigrated.erased,

            // App / behavior toggles
            SettingKey.isAppEnabled.erased,
            SettingKey.isAIEnabled.erased,
            SettingKey.isMouseHoldEnabled.erased,
            SettingKey.hasCompletedOnboarding.erased,
            SettingKey.hasDismissedPostOnboardingCoachMark.erased,
            SettingKey.startAtLogin.erased,
            SettingKey.completionCopyToClipboard.erased,
            SettingKey.captureTextAutoCopy.erased,

            // Updates
            SettingKey.automaticallyChecksForUpdates.erased,
            SettingKey.automaticallyDownloadsUpdates.erased,
            SettingKey.notifyOnUpdate.erased,
            SettingKey.updateChannel.erased,

            // Popup presentation
            SettingKey.popupScale.erased,
            SettingKey.popupThemeColor.erased,

            // Gesture / lifecycle
            SettingKey.mouseHoldDuration.erased,
            SettingKey.pauseUntilTimestamp.erased,
            SettingKey.lastRunVersion.erased,
            SettingKey.lastRunBuild.erased,

            // Builtin action config
            SettingKey.calendarProvider.erased,
            SettingKey.searchURL.erased,
            SettingKey.fileSaveLocation.erased,

            // Structured blobs
            SettingKey.actionCustomizations.erased,
            SettingKey.actionGroups.erased,
            SettingKey.customActions.erased
        ]
    }
}
