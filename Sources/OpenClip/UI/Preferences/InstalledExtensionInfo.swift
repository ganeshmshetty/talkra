// InstalledExtensionInfo.swift
// OpenClip
//
// One installed extension package as the Settings window sees it: its name, icon, contributed actions,
// and whether the trust gate holds it back. Built from the action catalog, which knows what is loaded.

import Foundation
import Core

/// The package folder's details beyond its registered actions: manifest, directory and README. Read off the main thread.
struct ExtensionPackageDetails: Equatable {
    let packageID: String
    let manifest: ExtensionMetadata?
    let directoryURL: URL?
    let readmeURL: URL?

    /// Filenames treated as the package's README, in the order they are looked for.
    static let readmeNames = ["README.md", "readme.md", "README.markdown", "README.txt", "README"]

    static func empty(packageID: String) -> ExtensionPackageDetails {
        ExtensionPackageDetails(packageID: packageID, manifest: nil, directoryURL: nil, readmeURL: nil)
    }

    /// Finds the package folder by walking the extensions directory, off the main actor.
    static func load(
        packageID: String,
        in directory: URL = Constants.extensionsDirectory
    ) async -> ExtensionPackageDetails {
        await Task.detached(priority: .utility) { () -> ExtensionPackageDetails in
            let fileManager = FileManager.default
            guard let items = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { return .empty(packageID: packageID) }

            for item in items where !item.lastPathComponent.hasPrefix(".") {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      let manifestURL = ExtensionManifestStore.manifestFileURL(in: item),
                      let manifest = ExtensionManifestStore.readManifest(at: manifestURL),
                      manifest.identifier == packageID else { continue }

                let readme = readmeNames
                    .map(item.appendingPathComponent)
                    .first { fileManager.fileExists(atPath: $0.path) }

                return ExtensionPackageDetails(
                    packageID: packageID,
                    manifest: manifest,
                    directoryURL: item,
                    readmeURL: readme
                )
            }
            return .empty(packageID: packageID)
        }.value
    }
}

struct InstalledExtensionInfo: Identifiable {
    let packageID: String
    let name: String
    let icon: ActionIcon
    /// The group action that carries the package's sub-actions, when the package is a group.
    let containerActionID: String?
    /// Runnable actions in catalog order, excluding the group container and the trust gate's placeholder.
    let commands: [any Action]
    let gatedReason: ExtensionGateReason?

    var id: String { packageID }

    var isGroup: Bool { containerActionID != nil }

    /// The id `ExtensionManager.uninstallExtension` matches the package by.
    var uninstallActionID: String {
        containerActionID ?? commands.first?.id ?? packageID
    }

    /// Every installed package present in `actions`, sorted by name.
    static func all(from actions: [any Action]) -> [InstalledExtensionInfo] {
        var order: [String] = []
        var buckets: [String: [any Action]] = [:]
        for action in actions {
            guard case .extensionPkg(let packageID) = action.chrome.source else { continue }
            guard !ActionIdentity.isAIPreset(action), !isCustomPackage(packageID) else { continue }
            if buckets[packageID] == nil {
                order.append(packageID)
            }
            buckets[packageID, default: []].append(action)
        }
        return order
            .compactMap { make(packageID: $0, actions: buckets[$0] ?? []) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func info(for packageID: String, in actions: [any Action]) -> InstalledExtensionInfo? {
        let members = actions.filter { action in
            guard case .extensionPkg(let id) = action.chrome.source else { return false }
            return id == packageID && !ActionIdentity.isAIPreset(action)
        }
        return make(packageID: packageID, actions: members)
    }

    /// GUI-authored custom actions are single-action manifest packages too; they belong to the Actions list, not Extensions.
    static func isCustomPackage(_ packageID: String) -> Bool {
        packageID.hasPrefix(Constants.customIdentifierPrefix) || packageID.hasPrefix("custom.")
    }

    private static func make(packageID: String, actions: [any Action]) -> InstalledExtensionInfo? {
        guard let first = actions.first else { return nil }
        let container = actions.first { $0.chrome.popupBehavior == .showSubActions }
        let gated = actions.lazy.compactMap { $0 as? GatedExtensionAction }.first
        let representative: any Action = container ?? gated.map { $0 as any Action } ?? first

        let name: String
        if case .extensionPkg(let badgeName) = representative.chrome.badge, !badgeName.isEmpty {
            name = badgeName
        } else {
            name = representative.title
        }

        let commands = actions.filter { $0.id != container?.id && !($0 is GatedExtensionAction) }

        return InstalledExtensionInfo(
            packageID: packageID,
            name: name,
            icon: representative.icon,
            containerActionID: container?.id,
            commands: commands,
            gatedReason: gated?.reason
        )
    }
}

/// The gate state in the user's words. Nil for revoked packages; the enable switch already explains those.
func extensionGateDescription(for reason: ExtensionGateReason) -> String? {
    switch reason {
    case .filesChanged:
        return String(localized: "This extension was modified externally. Toggle on to verify and re-enable.")
    case .notEnabled:
        return String(localized: "New extension found in folder. Toggle on to enable.")
    case .needsNewerApp(let required):
        return String(localized: "This extension requires Talkra \(required) or newer.")
    case .revoked:
        return nil
    }
}
