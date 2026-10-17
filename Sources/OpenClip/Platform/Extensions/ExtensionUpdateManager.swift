// ExtensionUpdateManager.swift
// OpenClip
//
// Manual and automatic update checks for store-sourced extensions. Fetches the store listing, compares
// versions via ExtensionUpdatePlanner, and applies updates through RemoteExtensionInstaller
// (which re-installs the package under the same id — a store action that re-trusts).
import Foundation
import Core
import Combine

@MainActor
public final class ExtensionUpdateManager: ObservableObject {
    public static let shared = ExtensionUpdateManager()

    @Published public private(set) var updatablePackageIDs: [String] = []
    @Published public private(set) var isChecking = false
    /// Result of the latest `updateAll` batch; nil until one runs.
    @Published public private(set) var lastBatchResult: ExtensionUpdateBatchResult?

    private let settings: any SettingsStore
    private var automaticUpdateTask: Task<Void, Never>?
    private var isUpdating = false
    private var updatingPackageIDs: Set<String> = []

    @Published public var automaticallyUpdatesExtensions: Bool {
        didSet {
            settings.set(.automaticallyUpdatesExtensions, value: automaticallyUpdatesExtensions)
        }
    }

    init(settings: any SettingsStore = DefaultSettingsStore.shared) {
        self.settings = settings
        automaticallyUpdatesExtensions = settings.get(.automaticallyUpdatesExtensions)
    }

    /// Checks at launch and every six hours while the app is running.
    public func startAutomaticUpdates() {
        guard automaticUpdateTask == nil else { return }
        automaticUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.performAutomaticUpdate()
                do {
                    try await Task.sleep(for: .seconds(6 * 60 * 60))
                } catch { return }
            }
        }
    }

    public func stopAutomaticUpdates() {
        automaticUpdateTask?.cancel()
        automaticUpdateTask = nil
    }

    func performAutomaticUpdate() async {
        guard automaticallyUpdatesExtensions, !isChecking, !isUpdating else { return }
        await checkForUpdates()
        guard automaticallyUpdatesExtensions, !Task.isCancelled else { return }
        isUpdating = true
        defer { isUpdating = false }
        for id in updatablePackageIDs {
            guard automaticallyUpdatesExtensions, !Task.isCancelled else { break }
            // Never replace developer or sideloaded packages, even if their id is in the store.
            guard settings.get(.extensionSources)[id] == "store" else { continue }
            do {
                try await update(packageID: id)
            } catch {
                Log.extensions.error("Failed to automatically update extension '\(id, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Idempotent; safe to call from the Reload button and Store tab.
    public func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let sources = settings.get(.extensionSources)

        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: Constants.extensionsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var candidateIDs = Set<String>()
        for item in items {
            guard !item.lastPathComponent.hasPrefix(".") else { continue }
            if let manifest = ExtensionManifestStore.readManifest(at: item.appendingPathComponent(Constants.manifestFileName)) ??
                              ExtensionManifestStore.readManifest(at: item.appendingPathComponent("extension.json")) {
                candidateIDs.insert(manifest.identifier)
            } else {
                candidateIDs.insert("\(Constants.customIdentifierPrefix)\(item.lastPathComponent)")
            }
        }
        for packageID in sources.keys where sources[packageID] == "store" {
            candidateIDs.insert(packageID)
        }

        var installed: [InstalledPackageVersion] = []
        for packageID in candidateIDs.sorted() {
            let version = ExtensionManifestStore.manifest(forPackageID: packageID, in: Constants.extensionsDirectory)?.version
            installed.append(InstalledPackageVersion(packageID: packageID, installedVersion: version, source: "store"))
        }

        var allItems: [ExtensionItem] = []
        let maxPages = 100
        var page = 1
        var totalPages = 1
        while page <= totalPages {
            // Bounds the loop against a pathological server-reported totalPages.
            guard page <= maxPages,
                  let response = try? await ExtensionsAPIClient.shared.fetchExtensions(page: page, limit: 50) else { break }
            allItems.append(contentsOf: response.extensions)
            totalPages = response.totalPages
            page += 1
        }
        // Keep the previous updatable set rather than computing from partial data.
        guard page > totalPages else { return }
        updatablePackageIDs = ExtensionUpdatePlanner.updatablePackageIDs(storeItems: allItems, installed: installed)
    }

    /// Re-installs from the store URL and re-trusts the package, except a revoked package stays revoked.
    /// Restores the prior trust state and hash if the install fails.
    public func update(packageID: String) async throws {
        guard updatingPackageIDs.insert(packageID).inserted else {
            throw NSError(domain: "ExtensionUpdateManager", code: 409,
                          userInfo: [NSLocalizedDescriptionKey: "An update is already in progress for \(packageID)."])
        }
        defer { updatingPackageIDs.remove(packageID) }
        guard let item = await storeItem(for: packageID), let url = URL(string: item.downloadURL) else {
            throw NSError(domain: "ExtensionUpdateManager", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No store listing for \(packageID)."])
        }
        let wasRevoked = settings.get(.extensionTrust)[packageID] == ExtensionTrustState.revoked.rawValue
        let originalTrust = settings.get(.extensionTrust)[packageID]
        let originalHash = settings.get(.extensionTrustHashes)[packageID]
        if !wasRevoked {
            // Mark seen and drop the hash so the intermediate load doesn't raise a tamper event.
            var trust = settings.get(.extensionTrust)
            trust[packageID] = ExtensionTrustState.seen.rawValue
            settings.set(.extensionTrust, value: trust)
            var hashes = settings.get(.extensionTrustHashes)
            hashes.removeValue(forKey: packageID)
            settings.set(.extensionTrustHashes, value: hashes)
        }
        ExtensionManager.shared.prepareInstall(source: "store", packageID: packageID)
        do {
            _ = try await RemoteExtensionInstaller.shared.installFromRemoteURL(url, extensionID: packageID)
        } catch {
            if !wasRevoked {
                if let originalTrust {
                    var trust = settings.get(.extensionTrust)
                    trust[packageID] = originalTrust
                    settings.set(.extensionTrust, value: trust)
                }
                if let originalHash {
                    var hashes = settings.get(.extensionTrustHashes)
                    hashes[packageID] = originalHash
                    settings.set(.extensionTrustHashes, value: hashes)
                }
            }
            throw error
        }
        if !wasRevoked {
            await ExtensionManager.shared.enablePackage(packageID: packageID)
        }
        await checkForUpdates()
    }

    /// Failures are logged and collected, not allowed to abort the batch.
    @discardableResult
    public func updateAll() async -> ExtensionUpdateBatchResult {
        var succeeded: [String] = []
        var failed: [String: String] = [:]
        for id in updatablePackageIDs {
            do {
                try await update(packageID: id)
                succeeded.append(id)
            } catch {
                failed[id] = error.localizedDescription
                Log.extensions.error("Failed to update extension '\(id, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }
        let result = ExtensionUpdateBatchResult(succeeded: succeeded, failed: failed)
        lastBatchResult = result
        await checkForUpdates()
        return result
    }

    private func storeItem(for packageID: String) async -> ExtensionItem? {
        var page = 1
        var totalPages = 1
        while page <= totalPages {
            guard let response = try? await ExtensionsAPIClient.shared.fetchExtensions(page: page, limit: 50) else { break }
            if let match = response.extensions.first(where: { $0.id == packageID }) { return match }
            totalPages = response.totalPages
            page += 1
        }
        return nil
    }
}