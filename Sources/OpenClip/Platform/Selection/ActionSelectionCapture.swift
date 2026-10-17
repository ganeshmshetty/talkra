import AppKit
import Core

/// Explicit action-time enrichment; discovery remains free of extra clipboard operations.
@MainActor
struct ActionSelectionCapture {
    var isSelectionCurrent: @MainActor @Sendable (SelectionContext) -> Bool = { _ in true }
    var frontmostPID: @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var activateSource: @MainActor (pid_t) async -> Bool = { pid in
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        app.activate()
        return await SelectionReplacer.defaultTargetActiveChecker(app)
    }
    var pasteboard: NSPasteboard = .general
    var postCopy: @MainActor () -> Void = {
        KeyboardEventPoster.postKey(keyCode: Constants.copyVirtualKey, flags: .maskCommand)
    }

    func capture(_ selection: SelectionContext) async throws -> SelectionContext {
        guard selection.source == .selection else { return selection }
        guard let pid = selection.sourceApp.processIdentifier, pid > 0,
              isSelectionCurrent(selection),
              frontmostPID() == pid || frontmostPID() == ProcessInfo.processInfo.processIdentifier else {
            throw failure(String(localized: "The source selection is no longer available."))
        }
        guard await activateSource(pid) else {
            throw failure(String(localized: "The source selection is no longer available."))
        }
        let current: @MainActor () -> Bool = {
            isSelectionCurrent(selection) && frontmostPID() == pid && !Task.isCancelled
        }
        let authorized: @MainActor () -> Bool = {
            current() && !CopyTriggerGate.isForeignOverlayPresent(at: NSEvent.mouseLocation, intent: .explicitUserCopy)
        }
        guard current() else { throw failure(String(localized: "The source selection is no longer available.")) }
        guard authorized() else { throw failure(String(localized: "Finish the screen capture before copying.")) }
        let engine = PasteboardCopyEngine(authorizationFailure: {
            current() ? .copyBlocked : .targetChanged
        }, isCopyAuthorized: authorized)
        var commandFailure: (any Error)?
        let response = await engine.captureResponse(
            pasteboard: pasteboard,
            timeout: PasteboardCopyEngine.pollingTimeout(for: selection.sourceApp.bundleIdentifier),
            priority: .userAction,
            asyncTrigger: {
                guard authorized() else { return }
                if selection.appPolicy.useMenuCopy || selection.appPolicy.retrievalMode == .menuCopy {
                    do {
                        try await NativeCopyOperation.pressMenuCopy(processIdentifier: pid, timeout: 0.5,
                                                                  isAuthorized: authorized)
                    } catch { commandFailure = error }
                } else {
                    postCopy()
                }
            }
        )
        try Task.checkCancellation()
        guard current() else { throw failure(String(localized: "The source selection is no longer available.")) }
        if commandFailure != nil { throw failure(String(localized: "The application's Copy command is unavailable.")) }
        guard let content = response.result else {
            if response.status == .copyBlocked, !authorized() {
                throw failure(String(localized: "Finish the screen capture before copying."))
            }
            if response.status == .copyBlocked {
                throw failure(String(localized: "The application's Copy command is unavailable."))
            }
            throw failure(String(localized: "The application did not confirm Copy in time."))
        }
        return selection.withRichContent(html: content.html, rtf: content.rtf,
                                         flavors: content.flavors.map { Core.RichPasteboardFlavor($0) })
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: Constants.actionErrorDomain, code: Int(Constants.actionErrorCode),
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
