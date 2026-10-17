// Notification.Name+OpenClip.swift
// OpenClip
//
// Central registry of OpenClip-specific Notification.Name values, replacing scattered inline string
// literals so presentation and composition code share one source of truth.
import Foundation

extension Notification.Name {
    /// Posted to open an action's configuration UI. Payload `ConfigurationRequest` is in `userInfo["request"]`.
    static let openClipOpenActionConfiguration = Notification.Name("OpenClipOpenActionConfiguration")

    /// Posted when extension packages are installed, uninstalled, enabled, or disabled.
    static let openClipExtensionsDidChange = Notification.Name("OpenClipExtensionsDidChange")

    /// Posted when the master app enabled state changes.
    static let openClipEnabledStateChanged = Notification.Name("OpenClipEnabledStateChanged")

    /// Posted when the user changes whether OpenClip appears in the menu bar.
    static let openClipMenuBarVisibilityChanged = Notification.Name("OpenClipMenuBarVisibilityChanged")

    /// Posted when accessibility authorization changes. The new `Bool` status travels in `object`.
    static let openClipAccessibilityChanged = Notification.Name("OpenClipAccessibilityChanged")

    /// Posted when selection inside onboarding sandbox triggers a popup.

    /// Posted to switch the active tab in the Preferences window. The target `PreferenceTab` travels in `object`.
    static let openClipSelectPreferencesTab = Notification.Name("OpenClipSelectPreferencesTab")

    /// Posted each time the Settings window is shown. Reused windows skip `onAppear`, so the sidebar scrolls on this.
    static let openClipPreferencesWindowDidShow = Notification.Name("OpenClipPreferencesWindowDidShow")
}
