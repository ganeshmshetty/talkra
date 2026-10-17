// HotkeyManager.swift
// OpenClip
//
// Manages global keyboard shortcuts using macOS event monitors and KeyboardShortcuts registrations.
import Foundation
import AppKit
import Combine
import KeyboardShortcuts
import Core

extension KeyboardShortcuts.Name {
    public static let pushToTalk = Self("pushToTalk", initial: .init(.space, modifiers: [.option]))
    public static let captureText = Self("captureText", initial: .init(.o, modifiers: [.command, .option]))
    static let cancelCaptureText = Self("cancelCaptureText", initial: .init(.escape))

    static func actionHotkey(_ actionID: String) -> Self {
        Self("actionHotkey.\(actionID)")
    }
}

@MainActor
public final class HotkeyManager {
    public static let shared = HotkeyManager()
    private var lastFallbackClipboard: (changeCount: Int, text: String)?
    private weak var popupController: PopupWindowController?
    private weak var captureTextController: CaptureTextController?
    internal var retriever: SelectionRetrievalCoordinator?
    internal var frontmostPIDProvider: @MainActor @Sendable () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    private var cancellables = Set<AnyCancellable>()
    private var registeredHotkeyIDs: Set<String> = []
    private var popupTriggerTask: Task<Void, Never>?
    private var popupTriggerRequestID: UUID?
    
    /// Pause, app exclusions, and per-app `disabled` rules still apply.
    /// True only while the onboarding playground is on screen, so Talkra's own text can be used to try a command.
    static var allowsOwnApp = false

    internal static func triggerAllowed(
        frontmost: NSRunningApplication?,
        settingsStore: SettingsStore = DefaultSettingsStore.shared
    ) -> Bool {
        if settingsStore.get(.pauseUntilTimestamp) > Date().timeIntervalSince1970 {
            return false
        }
        guard let frontmost else { return false }
        if let bundleID = frontmost.bundleIdentifier, AppFilter.isExcluded(bundleID: bundleID),
           !(allowsOwnApp && bundleID == Bundle.main.bundleIdentifier) {
            return false
        }
        // Bundle-less transient helpers cannot be configured, so never trigger.
        let identity = AppIdentity(frontmost)
        guard identity.ruleIdentifier != nil else { return false }
        return !RuleEngine.shared.resolvePolicies(for: identity).disabled
    }

    func setup(
        popupController: PopupWindowController,
        captureTextController: CaptureTextController? = nil
    ) {
        self.popupController = popupController
        self.captureTextController = captureTextController
        KeyboardShortcuts.onKeyDown(for: .captureText) { [weak self] in
            MainActor.assumeIsolated { self?.captureTextController?.toggleCapture() }
        }
        KeyboardShortcuts.onKeyDown(for: .cancelCaptureText) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.captureTextController?.isCapturing == true else { return }
                self.captureTextController?.cancel()
            }
        }
        KeyboardShortcuts.disable(.cancelCaptureText)

        ActionCoordinator.shared.$actions
            .sink { [weak self] actions in
                self?.registerActionHotkeys(actions)
            }
            .store(in: &cancellables)
        registerActionHotkeys(ActionCoordinator.shared.actions)

        // Electron apps only build their AX tree after being asked, so ask as each one comes forward.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { ElectronAccessibilityEnabler.shared.enableIfNeeded(for: app) }
        }
    }

    func enableCaptureCancellation() { KeyboardShortcuts.enable(.cancelCaptureText) }
    func disableCaptureCancellation() { KeyboardShortcuts.disable(.cancelCaptureText) }

    private func registerActionHotkeys(_ actions: [any Action]) {
        for action in actions where ActionIdentity.isBindable(action) {
            let actionID = action.id
            guard registeredHotkeyIDs.insert(actionID).inserted else { continue }
            KeyboardShortcuts.onKeyUp(for: .actionHotkey(actionID)) { [weak self] in
                Task { @MainActor in
                    self?.handleActionHotkey(actionID)
                }
            }
        }
    }

    internal func handleActionHotkey(_ actionID: String, settingsStore: SettingsStore = DefaultSettingsStore.shared) {
        guard let popupController else { return }
        guard let action = ActionCoordinator.shared.actions.first(where: { $0.id == actionID }),
              ActionIdentity.isBindable(action),
              !(action is GatedExtensionAction) else { return }

        let disabledIDs = settingsStore.get(.disabledActionIDs)
        let disabledPackages = settingsStore.get(.disabledPackages)
        guard !disabledIDs.contains(action.id) else { return }
        if let pkgID = ActionIdentity.extensionPackageID(of: action), disabledPackages.contains(pkgID) {
            return
        }
        if action.chrome.launchesAI, !AIServiceManager.shared.isAIEnabled {
            return
        }
        if ActionIdentity.isAIPreset(action) {
            guard AIServiceManager.shared.isAIEnabled,
                  AIServiceManager.shared.preset(forActionID: action.id)?.isEnabled == true else {
                return
            }
        }
        let groupDefs = ActionCoordinator.shared.actionGroupDefs
        if let parentGroup = groupDefs.first(where: { $0.memberActionIDs.contains(action.id) }),
           disabledIDs.contains(parentGroup.id) {
            return
        }
        if let parentExtensionGroup = ActionCoordinator.shared.actions.first(where: {
            $0.chrome.popupBehavior == .showSubActions && action.id != $0.id && action.id.hasPrefix($0.id + ".")
        }), disabledIDs.contains(parentExtensionGroup.id) {
            return
        }

        if popupController.isVisible, let context = popupController.currentActionContext {
            popupController.runBoundAction(action, with: context)
            return
        }

        Task { @MainActor in
            guard let trigger = await self.collectTrigger() else { return }
            let context = ActionContext(selection: trigger.context, modifiers: [])
            popupController.runBoundAction(action, with: context, pasteAvailable: trigger.canPaste)
        }
    }

    /// Shared retrieve path for push-to-talk and per-action hotkeys.
    internal private(set) var lastTriggerResponse: SelectionTriggerResponse?
    internal var onTriggerOutcome: ((SelectionTriggerResponse) -> Void)?

    internal func collectTrigger(
        frontmostApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
        allowsEmptyText: Bool = false, requestID: UUID? = nil, requestedPID: pid_t? = nil
    ) async -> (context: SelectionContext, canPaste: Bool?)? {
        let response = await collectTriggerResponse(frontmostApp: frontmostApp,
            allowsEmptyText: allowsEmptyText, requestID: requestID, requestedPID: requestedPID)
        guard let context = response.context else { return nil }
        return (context, response.canPaste)
    }

    internal func collectTriggerResponse(
        frontmostApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
        allowsEmptyText: Bool = false,
        requestID: UUID? = nil,
        requestedPID: pid_t? = nil
    ) async -> SelectionTriggerResponse {
        func finish(_ response: SelectionTriggerResponse) -> SelectionTriggerResponse {
            lastTriggerResponse = response
            onTriggerOutcome?(response)
            if let traceID = response.traceID, [.clipboardFallback, .targetChanged, .cancelled, .tooLarge].contains(response.status) {
                Log.selection.debug("[Trace#\(traceID, privacy: .public)] hotkey delivery outcome: \(response.status.rawValue, privacy: .public); readOutcome=\(response.retrievalStatus?.rawValue ?? "unknown", privacy: .public)")
            }
            return response
        }
        guard !Task.isCancelled,
              Self.triggerAllowed(frontmost: frontmostApp),
              let frontApp = frontmostApp else { return finish(.init(status: Task.isCancelled ? .cancelled : .policyBlocked)) }

        let requiredPID = requestedPID ?? frontApp.processIdentifier
        let isTriggerAuthorized: PasteboardCopyEngine.CopyAuthorization = { [weak self] in
            guard !Task.isCancelled,
                  Self.triggerAllowed(frontmost: frontApp) else { return false }
            if let requestID, self?.popupTriggerRequestID != requestID { return false }
            guard self?.frontmostPIDProvider() == requiredPID else { return false }
            return true
        }

        var retrievalTraceID: UInt64?
        func denied() -> SelectionTriggerResponse {
            let status: SelectionReadStatus = Task.isCancelled || (requestID != nil && popupTriggerRequestID != requestID)
                ? .cancelled : (!Self.triggerAllowed(frontmost: frontApp) ? .policyBlocked : .targetChanged)
            return finish(.init(status: status, traceID: retrievalTraceID))
        }

        let appIdentity = AppIdentity(frontApp)
        guard isTriggerAuthorized() else { return denied() }
        let policy = RuleEngine.shared.resolvePolicies(for: appIdentity)
        let probeTask = popupController?.preparePasteProbe(for: frontApp, policy: policy)

        var retrievedText = ""
        var selectionBounds: CGRect? = nil
        var selectionHTML: String?
        var selectionRTF: String?
        var selectionFlavors: [RichPasteboardFlavor] = []

        let copyCapture: SelectionRetrievalCoordinator.DetailedCopyCapture = { request in
            await PasteboardCopyEngine(authorizationFailure: {
                if Task.isCancelled { return .cancelled }
                return isTriggerAuthorized() ? nil : .targetChanged
            }, isCopyAuthorized: isTriggerAuthorized).captureResponse(trigger: request.trigger)
        }

        let coordinator = retriever ?? SelectionRetrievalCoordinator(detailedCopyCapture: copyCapture)
        let read = await coordinator.retrieveResponse(
            for: appIdentity,
            policy: policy,
            cursor: CursorClassifier.current.asCore,
            allowCopyFallback: true,
            requireCopyEvidence: false,
            trigger: .keyboardShortcut
        )
        retrievalTraceID = read.traceID
        if let result = read.result {
            retrievedText = result.text
            selectionBounds = result.bounds
            selectionHTML = result.html
            selectionRTF = result.rtf
            selectionFlavors = result.flavors
        }

        guard isTriggerAuthorized() else { return denied() }

        if read.status == .cancelled || read.status == .targetChanged || read.status == .policyBlocked || read.status == .busy {
            return finish(.init(status: read.status))
        }
        var isClipboardFallback = false
        if retrievedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let pasteboard = NSPasteboard.general
            let currentChangeCount = pasteboard.changeCount
            if let clipboard = pasteboard.string(forType: .string),
               !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                retrievedText = clipboard
                isClipboardFallback = true
                lastFallbackClipboard = (currentChangeCount, clipboard)
                selectionHTML = pasteboard.string(forType: .html)
                selectionRTF = pasteboard.string(forType: .rtf)
                selectionFlavors = []
            }
        }

        if Task.isCancelled { return denied() }
        guard retrievedText.utf8.count <= Constants.maxTextLength else {
            return finish(.init(status: .tooLarge, retrievalStatus: read.status, traceID: read.traceID))
        }
        if !TextSanitizer.isSubstantial(retrievedText) {
            guard allowsEmptyText else { return finish(.init(status: read.status, retrievalStatus: read.status, traceID: read.traceID)) }
            retrievedText = ""
            isClipboardFallback = false
            selectionHTML = nil
            selectionRTF = nil
            selectionFlavors = []
        }

        var context = SelectionContext(
            text: retrievedText,
            sourceApp: appIdentity,
            cursorPosition: NSEvent.mouseLocation,
            selectionBounds: selectionBounds,
            timestamp: Date(),
            appPolicy: policy,
            isClipboardFallback: isClipboardFallback,
            html: selectionHTML,
            rtf: selectionRTF,
            flavors: selectionFlavors,
            isEditable: isClipboardFallback ? false : read.isEditable,
            traceID: read.traceID
        )
        let canPaste = await probeTask?.value
        context = context.with(pasteTargetAvailable: canPaste)
        guard isTriggerAuthorized() else { return denied() }
        return finish(.init(context: context, canPaste: canPaste,
            status: isClipboardFallback ? .clipboardFallback : (retrievedText.isEmpty ? .noSelection : .selection),
            retrievalStatus: read.status, traceID: read.traceID))
    }
}
