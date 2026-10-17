// StatusBarController.swift
// OpenClip
//
// Menu bar status item, its dropdown menu, and Preferences presentation.
import AppKit
import SwiftUI
import Combine
import Core
import KeyboardShortcuts

@MainActor
class StatusBarController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let settingsStore: any SettingsStore
    private let notificationCenter: NotificationCenter
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private var preferencesToolbarController: PreferencesToolbarController?
    internal var rootMenu: NSMenu?
    internal var captureTextMenuItem: NSMenuItem?
    internal var settingsMenuItem: NSMenuItem?
    internal var updateMenuItem: NSMenuItem?
    internal var targetAppOverride: NSRunningApplication?
    var onCaptureText: ((NSRunningApplication?) -> Void)?
    private var lastActiveApp: NSRunningApplication?
    internal var currentTargetApp: NSRunningApplication? {
        get { targetAppOverride ?? resolveFrontmostApp() }
        set { targetAppOverride = newValue }
    }
    private var cancellables = Set<AnyCancellable>()

    var isMenuBarIconVisible: Bool { statusItem != nil }

    init(
        settingsStore: any SettingsStore = DefaultSettingsStore.shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.settingsStore = settingsStore
        self.notificationCenter = notificationCenter
        super.init()
        
        notificationCenter.addObserver(
            self,
            selector: #selector(handleStateChanged(_:)),
            name: .openClipEnabledStateChanged,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleMenuBarVisibilityChanged(_:)),
            name: .openClipMenuBarVisibilityChanged,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleOpenConfiguration(_:)),
            name: .openClipOpenActionConfiguration,
            object: nil
        )

        setMenuBarIconVisible(settingsStore.get(.showMenuBarIcon))

        AppUpdateManager.shared.$availableUpdateVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] version in
                self?.updateUpdateMenuItem(version: version)
            }
            .store(in: &cancellables)

        AppUpdateManager.shared.$isUpdateStagedForQuitInstall
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateUpdateMenuItem(version: AppUpdateManager.shared.availableUpdateVersion)
            }
            .store(in: &cancellables)

        AppUpdateManager.shared.$hasUpdateReminder
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusIcon(isEnabled: self.settingsStore.get(.isAppEnabled))
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        if let front = NSWorkspace.shared.frontmostApplication, isValidTargetApp(front) {
            self.lastActiveApp = front
        }
    }

    deinit {
        notificationCenter.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        self.rootMenu = menu

        let isEnabled = settingsStore.get(.isAppEnabled)

        let captureItem = menuItem(title: String(localized: "Capture Text"), action: #selector(captureText))
        captureItem.setShortcut(for: .captureText)
        self.captureTextMenuItem = captureItem
        menu.addItem(captureItem)

        let prefsItem = menuItem(title: String(localized: "Settings…"), action: #selector(showPreferences as () -> Void), keyEquivalent: ",")
        self.settingsMenuItem = prefsItem
        menu.addItem(prefsItem)
        menu.addItem(NSMenuItem.separator())

        let updateItem = menuItem(title: String(localized: "Check for Updates…"), action: #selector(checkForUpdates))
        menu.addItem(updateItem)
        self.updateMenuItem = updateItem
        updateUpdateMenuItem(version: AppUpdateManager.shared.availableUpdateVersion)

        menu.addItem(menuItem(title: String(localized: "Report Issue…"), action: #selector(openReportIssue)))

        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
        updateStatusIcon(isEnabled: isEnabled)
    }

    private func updateUpdateMenuItem(version: String?) {
        guard let updateMenuItem else { return }
        if let version {
            if AppUpdateManager.shared.isUpdateStagedForQuitInstall {
                updateMenuItem.title = String(localized: "Update Ready on Quit (v\(version))…")
            } else {
                updateMenuItem.title = String(localized: "Update Available (v\(version))…")
            }
        } else {
            updateMenuItem.title = String(localized: "Check for Updates…")
        }
        updateMenuItem.image = nil
        updateMenuItem.isEnabled = AppUpdateManager.shared.updatesEnabled
    }

    var updateMenuItemTitle: String? {
        updateMenuItem?.title
    }
    
    private func menuSymbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        img?.size = NSSize(width: 14, height: 14)
        img?.isTemplate = true
        return img
    }

    /// Targets self explicitly: status-item menus don't resolve actions via the responder chain.
    private func menuItem(title: String, action: Selector, keyEquivalent: String = "", iconName: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if let iconName {
            item.image = menuSymbolImage(iconName)
        }
        return item
    }


    @objc private func captureText() {
        let app = currentTargetApp
        DispatchQueue.main.async { [weak self] in self?.onCaptureText?(app) }
    }

    // MARK: - NSMenuDelegate

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return AppUpdateManager.shared.updatesEnabled
        }
        return menuItem.isEnabled
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === rootMenu {
            KeyboardShortcuts.disable(.captureText)
            updateRootMenuDynamicItems()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === rootMenu {
            KeyboardShortcuts.enable(.captureText)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === rootMenu { updateRootMenuDynamicItems() }
    }

    internal func updateRootMenuDynamicItems() {
        updateStatusIcon(isEnabled: settingsStore.get(.isAppEnabled))
    }

    @objc private func handleWorkspaceAppActivated(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           isValidTargetApp(app) {
            lastActiveApp = app
        }
    }

    private func isValidTargetApp(_ app: NSRunningApplication?) -> Bool {
        guard let app,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.activationPolicy == .regular else {
            return false
        }
        // Bundle-less processes (CLI tools such as scrcpy) are targetable via name/path.
        return app.bundleIdentifier.map { !AppFilter.isExcluded(bundleID: $0) }
            ?? (AppIdentity(app).ruleIdentifier != nil)
    }

    private func resolveFrontmostApp() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, isValidTargetApp(front) {
            lastActiveApp = front
            return front
        }
        return lastActiveApp
    }

    @objc private func handleStateChanged(_ notification: Notification) {
        let isEnabled = (notification.object as? Bool) ?? settingsStore.get(.isAppEnabled)
        updateStatusItem(isEnabled: isEnabled)
    }

    @objc private func handleMenuBarVisibilityChanged(_ notification: Notification) {
        let isVisible = (notification.object as? Bool) ?? settingsStore.get(.showMenuBarIcon)
        setMenuBarIconVisible(isVisible)
    }

    @objc private func openReportIssue() {
        if let url = URL(string: "https://github.com/ganeshmshetty/talkra/issues") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdates() {
        AppUpdateManager.shared.checkForUpdates()
    }
    
    /// An action asked to be configured: open Preferences, which presents its editor.
    @objc private func handleOpenConfiguration(_ notification: Notification) {
        showPreferences()
    }
    
    public func updateStatusItem(isEnabled: Bool) {
        updateStatusIcon(isEnabled: isEnabled)
    }

    /// Screen frame of the status item button; nil until it has joined a window.
    var statusItemButtonFrame: NSRect? {
        statusItem?.button?.window?.frame
    }
    
    private func updateStatusIcon(isEnabled: Bool) {
        let effectiveEnabled = isEnabled
        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Talkra")
            button.image?.isTemplate = true
            let hasReminder = AppUpdateManager.shared.hasUpdateReminder
            button.title = hasReminder ? "•" : ""
            button.font = .systemFont(ofSize: 9, weight: .bold)
            button.imagePosition = .imageLeft
            button.toolTip = hasReminder ? String(localized: "Talkra Update Available") : "Talkra"
            button.alphaValue = effectiveEnabled ? 1.0 : 0.45
            button.setAccessibilityLabel(hasReminder ? String(localized: "Talkra Update Available") : "Talkra")
        }
    }

    private func setMenuBarIconVisible(_ isVisible: Bool) {
        if isVisible {
            guard statusItem == nil else { return }
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            setupMenu()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            rootMenu = nil
        }
    }
    
    /// Opens Settings on the last-shown pane and drill-down; resetting here would lose the router path.
    @objc public func showPreferences() {
        presentPreferences(tab: nil)
    }

    /// Opens Settings on a named pane, overriding the last-shown one.
    public func showPreferences(tab: PreferenceTab) {
        presentPreferences(tab: tab)
    }

    private func presentPreferences(tab: PreferenceTab?) {
        SettingsWindowController.show(tab: tab)
    }
}
