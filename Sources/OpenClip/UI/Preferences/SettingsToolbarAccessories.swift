// SettingsToolbarAccessories.swift
// OpenClip
//
// Trailing toolbar items for the current page: the subject's on/off switch and an ellipsis menu.
// They sit in the toolbar, not the page, so the switch stays in reach while the page scrolls.

import Foundation

/// The subject's on/off switch. `nil` on a page whose subject cannot be switched off.
public struct SettingsToolbarToggle: Equatable, Sendable {
    public var isOn: Bool
    /// Spoken and shown on hover: "Enable JWT".
    public var label: String
    /// False only for a trust-gated package, which can be turned on (re-trusting it) but never off.
    public var isEnabled: Bool

    public init(isOn: Bool, label: String, isEnabled: Bool = true) {
        self.isOn = isOn
        self.label = label
        self.isEnabled = isEnabled
    }
}

/// One entry of the toolbar's ellipsis menu.
public struct SettingsToolbarMenuItem: Identifiable, Equatable, Sendable {
    public enum Role: Sendable, Equatable {
        case normal
        case destructive
        case separator
    }

    public let id: String
    public var title: String
    public var symbol: String
    public var role: Role
    /// False while the command cannot run — a refresh that is already running, for one.
    public var isEnabled: Bool

    public init(id: String, title: String, symbol: String = "", role: Role = .normal, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.role = role
        self.isEnabled = isEnabled
    }

    public static func separator(id: String) -> SettingsToolbarMenuItem {
        SettingsToolbarMenuItem(id: id, title: "", role: .separator)
    }

    /// A separator is only worth drawing between two real entries.
    public var isSeparator: Bool { role == .separator }
}

/// The ids the window listens for. Strings rather than an enum because they travel through the
/// AppKit menu item's `representedObject`.
public enum SettingsToolbarCommand {
    public static let extensionReadme = "extension.readme"
    public static let extensionFinder = "extension.finder"
    public static let extensionUninstall = "extension.uninstall"
    public static let actionDuplicate = "action.duplicate"
    public static let actionDelete = "action.delete"
    public static let storeInstallFile = "store.installFile"
    public static let storeRefresh = "store.refresh"
}

/// Builds the ellipsis menu for a page. Pure, so tests can pin what each page offers.
public enum SettingsToolbarAccessories {
    public struct ExtensionMenuContext: Equatable, Sendable {
        public var hasReadme: Bool
        public var hasFolder: Bool

        public init(hasReadme: Bool, hasFolder: Bool) {
            self.hasReadme = hasReadme
            self.hasFolder = hasFolder
        }
    }

    /// Uninstall sits behind a separator so it is never the click you meant.
    public static func extensionMenuItems(_ context: ExtensionMenuContext) -> [SettingsToolbarMenuItem] {
        var items: [SettingsToolbarMenuItem] = []
        if context.hasReadme {
            items.append(SettingsToolbarMenuItem(
                id: SettingsToolbarCommand.extensionReadme,
                title: String(localized: "View README"),
                symbol: "doc.text"
            ))
        }
        if context.hasFolder {
            items.append(SettingsToolbarMenuItem(
                id: SettingsToolbarCommand.extensionFinder,
                title: String(localized: "Show in Finder"),
                symbol: "folder"
            ))
        }
        if !items.isEmpty {
            items.append(.separator(id: "extension.separator"))
        }
        items.append(SettingsToolbarMenuItem(
            id: SettingsToolbarCommand.extensionUninstall,
            title: String(localized: "Uninstall Extension"),
            symbol: "trash",
            role: .destructive
        ))
        return items
    }

    /// Catalogue-wide actions. Installing from disk lives here because the Store is where extensions come from.
    public static func storeMenuItems(isRefreshing: Bool) -> [SettingsToolbarMenuItem] {
        [
            SettingsToolbarMenuItem(
                id: SettingsToolbarCommand.storeInstallFile,
                title: String(localized: "Install from File…"),
                symbol: "square.and.arrow.down"
            ),
            SettingsToolbarMenuItem(
                id: SettingsToolbarCommand.storeRefresh,
                title: String(localized: "Refresh Catalog"),
                symbol: "arrow.clockwise",
                isEnabled: !isRefreshing
            ),
        ]
    }

    public struct ActionMenuContext: Equatable, Sendable {
        public var canDuplicate: Bool
        public var canDelete: Bool
        public var canUninstall: Bool

        public init(canDuplicate: Bool, canDelete: Bool, canUninstall: Bool = false) {
            self.canDuplicate = canDuplicate
            self.canDelete = canDelete
            self.canUninstall = canUninstall
        }
    }

    /// An action's page-level actions. A builtin has neither, so its menu is empty and the
    /// ellipsis never appears.
    public static func actionMenuItems(_ context: ActionMenuContext) -> [SettingsToolbarMenuItem] {
        var items: [SettingsToolbarMenuItem] = []
        if context.canDuplicate {
            items.append(SettingsToolbarMenuItem(
                id: SettingsToolbarCommand.actionDuplicate,
                title: String(localized: "Duplicate"),
                symbol: "plus.square.on.square"
            ))
        }
        if context.canDelete {
            if !items.isEmpty {
                items.append(.separator(id: "action.separator"))
            }
            items.append(SettingsToolbarMenuItem(
                id: SettingsToolbarCommand.actionDelete,
                title: String(localized: "Delete Action"),
                symbol: "trash",
                role: .destructive
            ))
        }
        if context.canUninstall {
            if !items.isEmpty {
                items.append(.separator(id: "action.uninstall.separator"))
            }
            items.append(SettingsToolbarMenuItem(
                id: SettingsToolbarCommand.extensionUninstall,
                title: String(localized: "Uninstall Extension…"),
                symbol: "trash",
                role: .destructive
            ))
        }
        return items
    }
}
