// AppUpdateManager.swift
// OpenClip
//
// Sparkle updater wrapper. Updates are fetched from the Info.plist SUFeedURL appcast and verified
// with Ed25519, so no Apple Developer ID or notarization is needed.
import Foundation
import AppKit
import Sparkle
import Combine
@preconcurrency import UserNotifications
import Core

@MainActor
public final class AppUpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    public static let shared = AppUpdateManager()

    public static let defaultFeedURL = "https://github.com/ganeshmshetty/talkra/releases/latest/download/appcast.xml"

    public static let updateNotificationCategory = "OPENCLIP_UPDATE_CATEGORY"

    /// Background schedule comes from `SUScheduledCheckInterval` in Info.plist.
    private var controller: SPUStandardUpdaterController?
    private let settingsStore: any SettingsStore
    public let updatesEnabled: Bool
    public var canPresentUpdate: Bool {
        updatesEnabled && (canCheckForUpdates || controller?.updater.sessionInProgress == true)
    }
    @Published public private(set) var hasUpdateReminder = false

    @Published public private(set) var availableUpdateVersion: String?

    @Published public private(set) var availableUpdateReleaseNotes: String?

    /// markdown, html, or plain-text.
    @Published public private(set) var availableUpdateReleaseNotesFormat: String?

    @Published public private(set) var isUpdateStagedForQuitInstall: Bool = false

    @Published public private(set) var canCheckForUpdates = false

    @Published public var automaticallyChecksForUpdates: Bool {
        didSet {
            settingsStore.set(.automaticallyChecksForUpdates, value: automaticallyChecksForUpdates)
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            if !automaticallyChecksForUpdates && automaticallyDownloadsUpdates {
                automaticallyDownloadsUpdates = false
            }
        }
    }

    @Published public var automaticallyDownloadsUpdates: Bool {
        didSet {
            settingsStore.set(.automaticallyDownloadsUpdates, value: automaticallyDownloadsUpdates)
            controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            if automaticallyDownloadsUpdates && !automaticallyChecksForUpdates {
                automaticallyChecksForUpdates = true
            }
        }
    }

    @Published public var notifyOnUpdate: Bool {
        didSet {
            settingsStore.set(.notifyOnUpdate, value: notifyOnUpdate)
            if !notifyOnUpdate { clearUpdateNotification() }
        }
    }

    /// Always targets the stable feed; kept for settings persistence.
    @Published public var updateChannel: UpdateChannel {
        didSet {
            guard updateChannel != oldValue else { return }
            settingsStore.set(.updateChannel, value: updateChannel.rawValue)
            controller?.updater.resetUpdateCycleAfterShortDelay()
            Log.updates.info("Update channel changed to \(self.updateChannel.rawValue, privacy: .public)")
        }
    }

    private var isInteractiveUpdatePresented = false
    private var cancellables = Set<AnyCancellable>()
    private var notificationTask: Task<Void, Never>?
    private var activeNotificationIdentifier: String?
    private let notificationClient: UpdateNotificationClient

    init(settingsStore: any SettingsStore = DefaultSettingsStore.shared,
         bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         notificationClient: UpdateNotificationClient? = nil) {
        self.settingsStore = settingsStore
        let notificationIdentifier = settingsStore.get(.lastAppUpdateNotificationIdentifier)
        self.activeNotificationIdentifier = notificationIdentifier.isEmpty ? nil : notificationIdentifier
        self.notificationClient = notificationClient ?? (NSClassFromString("XCTestCase") == nil ? .live : .disabled)
        self.updatesEnabled = Self.supportsUpdates(bundleIdentifier: bundleIdentifier)
        let autoCheck = settingsStore.get(.automaticallyChecksForUpdates)
        let autoDownload = settingsStore.get(.automaticallyDownloadsUpdates)
        let notify = settingsStore.get(.notifyOnUpdate)
        let channel = UpdateChannel(rawValue: settingsStore.get(.updateChannel)) ?? .stable

        self.automaticallyChecksForUpdates = autoCheck
        self.automaticallyDownloadsUpdates = autoDownload
        self.notifyOnUpdate = notify
        self.updateChannel = channel

        super.init()

        guard updatesEnabled else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: NSClassFromString("XCTestCase") == nil,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        controller.updater.automaticallyChecksForUpdates = autoCheck
        controller.updater.automaticallyDownloadsUpdates = autoDownload

        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)
    }

    static func supportsUpdates(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.talkra.Talkra"
    }

    public var supportsGentleScheduledUpdateReminders: Bool { true }

    public func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        handleUpdatePresentation(showsWindow: handleShowingUpdate, userInitiated: state.userInitiated,
                                 version: update.displayVersionString ?? update.versionString)
    }

    func handleUpdatePresentation(showsWindow: Bool, userInitiated: Bool, version: String) {
        if showsWindow { beginInteractiveUpdatePresentation() }
        hasUpdateReminder = !userInitiated
        if !userInitiated && notifyOnUpdate { postUpdateNotification(version: version) }
    }

    public func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        acknowledgeUpdateReminder()
    }

    func acknowledgeUpdateReminder() {
        hasUpdateReminder = false
        clearUpdateNotification()
    }

    public func standardUserDriverWillFinishUpdateSession() {
        hasUpdateReminder = false
        clearUpdateNotification()
        if !isUpdateStagedForQuitInstall { clearAvailableUpdate() }
        finishInteractiveUpdatePresentation()
    }

    private func clearAvailableUpdate() {
        availableUpdateVersion = nil
        availableUpdateReleaseNotes = nil
        availableUpdateReleaseNotesFormat = nil
        isUpdateStagedForQuitInstall = false
    }

    // MARK: - SPUUpdaterDelegate

    public func feedURLString(for updater: SPUUpdater) -> String? {
        currentFeedURL
    }

    public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowedChannelNames
    }

    public var currentFeedURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? Self.defaultFeedURL
    }

    public var allowedChannelNames: Set<String> {
        []
    }

    /// Interactive check; shows Sparkle's update UI.
    public func checkForUpdates() {
        guard canPresentUpdate, let controller else { return }
        beginInteractiveUpdatePresentation()
        controller.checkForUpdates(nil)
    }

    /// Shares the activation lease with the Settings window.
    func beginInteractiveUpdatePresentation() {
        guard !isInteractiveUpdatePresented else { return }
        isInteractiveUpdatePresented = true
        AppActivationPolicy.enter()
    }

    func finishInteractiveUpdatePresentation() {
        guard isInteractiveUpdatePresented else { return }
        isInteractiveUpdatePresented = false
        AppActivationPolicy.leave()
    }

    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // Fires after the driver finishes, including cancel, no-update, and error.
        finishInteractiveUpdatePresentation()
    }

    /// Opens Sparkle's flow, including updates staged for install.
    public func installUpdateNow() {
        checkForUpdates()
    }

    public var lastUpdateCheckDate: Date? {
        controller?.updater.lastUpdateCheckDate
    }

    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString ?? item.versionString
        Log.updates.info("Sparkle found valid update: v\(version, privacy: .public)")
        self.availableUpdateVersion = version
        self.availableUpdateReleaseNotes = item.itemDescription
        self.availableUpdateReleaseNotesFormat = item.itemDescriptionFormat
    }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Log.updates.info("Sparkle: no update found or up to date: \(error.localizedDescription, privacy: .public)")
        clearAvailableUpdate()
        hasUpdateReminder = false
        clearUpdateNotification()
    }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.updates.info("Sparkle: no update found or up to date")
        clearAvailableUpdate()
        hasUpdateReminder = false
        clearUpdateNotification()
    }

    public func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        clearAvailableUpdate()
        hasUpdateReminder = false
        clearUpdateNotification()
    }

    public func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString ?? item.versionString
        Log.updates.info("Sparkle: update v\(version, privacy: .public) downloaded and staged for install on quit")
        self.availableUpdateVersion = version
        self.availableUpdateReleaseNotes = item.itemDescription
        self.availableUpdateReleaseNotesFormat = item.itemDescriptionFormat
        self.isUpdateStagedForQuitInstall = true
        hasUpdateReminder = true
        if notifyOnUpdate { postUpdateNotification(version: version) }
        return false // Let Sparkle continue its normal scheduler and install automatically on quit
    }

    public func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        // 1001 (no update) and 4001 (check canceled) are expected control flow, not failures.
        if nsError.code == 1001 || nsError.code == 4001 {
            if nsError.code == 1001 {
                Log.updates.info("Sparkle update check completed: app is up to date")
            } else {
                Log.updates.info("Sparkle update check canceled by user")
            }
            return
        }
        Log.updates.error("Sparkle update error (\(nsError.code)): \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - User Notifications

    static let notificationIdentifier = "com.talkra.update.available"

    func shouldNotify(version: String) -> Bool {
        notifyOnUpdate && settingsStore.get(.lastAnnouncedAppUpdateVersion) != version
    }

    func recordNotificationDelivery(version: String) {
        settingsStore.set(.lastAnnouncedAppUpdateVersion, value: version)
        if let identifier = activeNotificationIdentifier {
            settingsStore.set(.lastAppUpdateNotificationIdentifier, value: identifier)
        }
    }

    private func clearUpdateNotification() {
        notificationTask?.cancel()
        notificationTask = nil
        if let identifier = activeNotificationIdentifier {
            notificationClient.remove([identifier])
        }
        activeNotificationIdentifier = nil
        settingsStore.set(.lastAppUpdateNotificationIdentifier, value: "")
    }

    func postUpdateNotification(version: String) {
        guard updatesEnabled, shouldNotify(version: version) else { return }
        clearUpdateNotification()
        // Unique ID so a late, canceled delivery can't replace a newer one.
        let identifier = "\(Self.notificationIdentifier).\(UUID().uuidString)"
        activeNotificationIdentifier = identifier
        notificationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let authorized = try await notificationClient.authorize()
                guard !Task.isCancelled, activeNotificationIdentifier == identifier,
                      authorized, hasUpdateReminder, shouldNotify(version: version) else { return }
                try await notificationClient.add(identifier, version)
                guard !Task.isCancelled, activeNotificationIdentifier == identifier,
                      hasUpdateReminder, notifyOnUpdate else {
                    notificationClient.remove([identifier])
                    return
                }
                recordNotificationDelivery(version: version)
            } catch {
                Log.updates.error("Failed to post update notification: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // MARK: - Testing Hooks

    public func setAvailableUpdateVersionForTesting(
        _ version: String?,
        releaseNotes: String? = nil,
        releaseNotesFormat: String? = nil,
        isStagedForQuit: Bool = false
    ) {
        self.hasUpdateReminder = version != nil
        self.availableUpdateVersion = version
        self.availableUpdateReleaseNotes = releaseNotes
        self.availableUpdateReleaseNotesFormat = releaseNotesFormat ?? (releaseNotes == nil ? nil : "markdown")
        self.isUpdateStagedForQuitInstall = isStagedForQuit
    }
}

/// Injectable so tests avoid system notifications.
@MainActor
struct UpdateNotificationClient {
    var authorize: () async throws -> Bool
    var add: (_ identifier: String, _ version: String) async throws -> Void
    var remove: (_ identifiers: [String]) -> Void

    static let disabled = UpdateNotificationClient(authorize: { false }, add: { _, _ in }, remove: { _ in })

    static var live: UpdateNotificationClient {
        let center = UNUserNotificationCenter.current()
        return UpdateNotificationClient(
            authorize: {
                let settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    return try await center.requestAuthorization(options: [.alert])
                }
                return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            },
            add: { identifier, version in
                let content = UNMutableNotificationContent()
                content.title = String(localized: "Talkra Update Available")
                content.body = String(localized: "Version \(version) is available. Click to install the update.")
                content.categoryIdentifier = AppUpdateManager.updateNotificationCategory
                content.userInfo = ["type": "app_update", "version": version]
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            },
            remove: { identifiers in
                center.removePendingNotificationRequests(withIdentifiers: identifiers)
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        )
    }
}
