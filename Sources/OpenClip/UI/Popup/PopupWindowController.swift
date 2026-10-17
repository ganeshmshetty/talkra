// PopupWindowController.swift
// OpenClip
//
// Manages the popup panel's lifecycle, event tracking, placement, and animation.
// The session is headless until a result card appears; showing one makes the panel key and restores
// focus to the previous app on exit. Esc is owned by the SwiftUI card while the panel is key.
// `cardIsModal` suppresses automatic dismissal until the user answers (Copy, Paste, or Esc).
// Result trees are walked by handleActionResult: presentation renders here, leaf effects route to
// DefaultActionResultHandler, and dismissal is decided once via ActionResult.dismissesPopup.
import AppKit
import SwiftUI
import Combine
import Core

@MainActor
public class PopupWindowController {
    var panel: PopupPanel?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var currentContext: SelectionContext?
    public var sourceAppBundleID: String? { currentContext?.sourceApp.bundleIdentifier }
    var currentActionContext: ActionContext?
    private var cardAbove = false
    /// Whether the panel is idle or showing the result card.
    public let modeStore = PopupModeStore()
    private var cancellables = Set<AnyCancellable>()

    /// Frontmost app before the panel became key (the result card); captured once per session in
    /// beginSession(for:), reactivated on exitKeyMode/hide, cleared only by hide().
    var previousFrontmostApp: NSRunningApplication?

    /// Session start time. `workspaceDidActivateApp` ignores activations within ~300 ms, when a clipboard manager's queued activation can arrive.
    var sessionShowTime: TimeInterval = 0

    private var isMenuTracking = false

    /// Tracks whether a right-click mouse-down originated within the popup, so dismissal waits for the click to complete.
    private var isRightClickInProgress = false

    /// Click intent (left vs right/⇧) snapshotted into a `DeliveryContext` when an action performs.
    private var pendingClickIntent: ActionResultDelivery.ClickIntent = .primary

    /// Declared delivery of the latest action. Set just before it runs; consumed once by the next `deliverResult`.
    var pendingDelivery: ActionDelivery? = nil

    /// Latest action's title for the card header. Same lifecycle as `pendingDelivery`.
    var pendingActionTitle: String? = nil

    /// Latest action's display icon for the card header. Same lifecycle as `pendingActionTitle`.
    var pendingActionIcon: ActionIcon? = nil

    /// Latest action's ID for delivery preference resolution. Same lifecycle as `pendingActionTitle`.
    var pendingActionID: String? = nil

    /// Latest action's recommended result. Same lifecycle as `pendingActionTitle`.
    var pendingActionRecommendedResult: ActionResultDeliveryMode? = nil

    /// Latest action's output kind. Same lifecycle as `pendingActionTitle`.
    var pendingActionOutputKind: ActionOutputKind? = nil

    /// Delivery context snapshotted before an action performs. Kept across hide() so async actions deliver with it.
    var inFlightDeliveryContext: DeliveryContext? = nil

    /// Frontmost-app provider; injectable for app-switching tests.
    var frontmostApplicationProvider: @MainActor () -> NSRunningApplication? = {
        NSWorkspace.shared.frontmostApplication
    }

    /// Paste-support probe; injectable for tests.
    private let pasteProbe: PasteAvailabilityProbing

    /// Toast surface for statuses and the paste→copy notice. Independent of the panel, so it shows after hide().
    let toastController: ToastPanelController
    private var captureToastPresentationID: UUID?
    private var isCaptureToastCurrent: Bool {
        guard let captureToastPresentationID else { return false }
        return toastController.presentationID == captureToastPresentationID
    }

    /// Last on-screen popup frame (screen coords), kept after hide() so toasts stay where the popup was.
    var lastPopupFrame: NSRect?

    /// Where the voice pill was, so cards and toasts take over its spot instead of jumping elsewhere.
    /// Expires so later hotkey-driven actions anchor to their own selection again.
    private var voiceAnchor: (frame: NSRect, expires: Date)?

    func setVoiceAnchor(_ frame: NSRect?) {
        voiceAnchor = frame.map { ($0, Date().addingTimeInterval(15)) }
    }

    private var activeVoiceAnchor: NSRect? {
        guard let voiceAnchor, voiceAnchor.expires > Date() else { return nil }
        return voiceAnchor.frame
    }

    /// Frame toasts centre on: the card while it is up, else the voice pill's spot, else the last popup frame.
    private var toastAnchorFrame: NSRect? {
        if panel?.isVisible == true { return panel?.frame }
        return activeVoiceAnchor ?? panel?.frame ?? lastPopupFrame
    }

    /// Settings store for the per-click result-delivery preference.
    private let settingsStore: SettingsStore

    /// Session token for AI streaming, bumped by hide() and beginSession(for:). Chunks from an abandoned stream are dropped on mismatch.
    public private(set) var aiSessionID = UUID()

    /// Live AI stream for the session, cancelled directly by hide() rather than via SwiftUI teardown, which can race AppKit's hide().
    var activeStreamingTask: Task<Void, Never>?

    /// Active loading action task reference so clicking the loading toast can cancel in-flight execution.
    var activeLoadingTask: Task<Void, Never>?
    private var activeLoadingID: UUID?

    /// Suppresses distance-based auto-dismiss during the onboarding sandbox.
    public var isOnboardingVisible: Bool = false

    /// Whether global event monitoring (and therefore shadow-ring click-through) is available this session.
    private var usesGlobalMouseMonitoring = false

    /// True while a detached interactive surface is open (`ActionResult.suspendsScrollDismissal`). Cleared when the session ends.
    private var isScrollDismissalSuspended = false
    private var distanceDismissGraceUntil: TimeInterval?

    public init(resultHandler: ActionResultHandler = DefaultActionResultHandler(),
                 pasteProbe: PasteAvailabilityProbing = PasteAvailabilityProbe(),
                 toastController: ToastPanelController = ToastPanelController(),
                 settingsStore: SettingsStore = DefaultSettingsStore.shared) {
        self.resultHandler = resultHandler
        self.pasteProbe = pasteProbe
        self.toastController = toastController
        self.settingsStore = settingsStore
    }

    /// Starts the paste-availability probe (rules first, then AX), run in parallel with selection retrieval. Not cached,
    /// since paste depends on focus context, unless a per-app rule answers definitively.
    public func preparePasteProbe(for app: NSRunningApplication?, policy: AppPolicyContext) -> Task<Bool?, Never> {
        Task { @MainActor in
            await pasteProbe.canPaste(in: app, policy: policy)
        }
    }

    /// Starts a result session for `context` without putting anything on screen. The panel appears
    /// only when a result card is shown; toasts and in-place delivery never need it.
    public func beginSession(for context: SelectionContext, pasteAvailable: Bool? = nil) {
        if panel?.isVisible == true { hide() }
        activeStreamingTask?.cancel()
        activeStreamingTask = nil
        activeLoadingTask?.cancel()
        activeLoadingTask = nil
        aiSessionID = UUID()
        prepareSession(for: context, pasteAvailable: pasteAvailable)
    }

    /// Rebuilds the card host for `context` while an AI stream started in the current session keeps running.
    func reopenSession(for context: SelectionContext, pasteAvailable: Bool?) {
        prepareSession(for: context, pasteAvailable: pasteAvailable)
    }

    private func prepareSession(for context: SelectionContext, pasteAvailable: Bool?) {
        isMenuTracking = false

        let selectionContext = context.with(
            pasteTargetAvailable: PasteAvailability.effective(policy: context.appPolicy, probe: pasteAvailable)
        )
        currentContext = selectionContext
        sessionShowTime = ProcessInfo.processInfo.systemUptime
        distanceDismissGraceUntil = context.source == .ocr
            ? sessionShowTime + PopupMetrics.ocrArrivalDismissalGrace
            : nil
        captureFrontmostAppIfNeeded()
        currentActionContext = ActionContext(selection: selectionContext, modifiers: [])

        let panel = self.panel ?? PopupPanel()
        self.panel = panel
        panel.pinBottomEdgeOnResize = false
        panel.horizontalAnchor = .none
        modeStore.mode = .actions
        modeStore.resultCard = nil
        modeStore.resultCardSize = nil
        modeStore.isSurfaceUserSized = false
        modeStore.canPaste = pasteAvailable
        isScrollDismissalSuspended = false

        let screen = PopupPositioner.screen(containing: context.cursorPosition) ?? NSScreen.main
        let screenBounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        panel.heightCap = screenBounds.height
        let probeSize = CGSize(width: PopupMetrics.aiCardIdealWidth, height: PopupMetrics.aiCardMinHeight)
        let probeFrame = PopupPositioner.calculateFrame(
            for: context, popupSize: probeSize, in: screenBounds)
        cardAbove = probeFrame.minY < screenBounds.minY + PopupMetrics.cardAboveThreshold
        modeStore.searchResultsAbove = cardAbove

        let rootView = ResultSurfaceView(
            modeStore: modeStore,
            settingsStore: settingsStore,
            onDismiss: { [weak self] in self?.hide() },
            onCardDrag: { [weak self] phase in self?.handleCardDrag(phase) },
            onResize: { [weak self] edge, phase in self?.handleResize(edge, phase: phase) },
            onPinCard: { [weak self] in self?.pinCard() },
            onCardEffect: { [weak self] result in self?.performCardEffect(result) },
            onFollowUp: { [weak self] instruction in self?.runFollowUp(instruction) },
            onCancelFollowUp: { [weak self] in self?.cancelFollowUp() },
            onContentSizeChange: { [weak self] size in
                self?.resizePanel(to: size)
                self?.keepPanelOnScreen()
                self?.updateToastPlacement()
            }
        )
        syncPanelAppearance(panel)
        panel.contentView = PopupPanel.ContentView(rootView: rootView)
        positionPanel(panel, size: probeSize, for: context)
        lastPopupFrame = panel.frame
    }

    /// Metadata only: never include selected text, window titles, or clipboard contents.
    private func logPresentation(_ event: String) {
        guard let context = currentContext else { return }
        // Window metadata is only interesting when the card is visible but off the active Space.
        guard panel?.isVisible == true && panel?.isOnActiveSpace == false else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frame = panel.map { NSStringFromRect($0.frame) } ?? "none"
        let ageMS = sessionShowTime > 0 ? Int((ProcessInfo.processInfo.systemUptime - sessionShowTime) * 1000) : 0
        let metadata = "event=\(event) pid=\(ProcessInfo.processInfo.processIdentifier) source=\(context.sourceApp.bundleIdentifier ?? "unknown") frontmost=\(frontmost?.bundleIdentifier ?? "unknown") session=\(aiSessionID) ageMS=\(ageMS) visible=\(panel?.isVisible ?? false) activeSpace=\(panel?.isOnActiveSpace ?? false) unoccluded=\(panel?.occlusionState.contains(.visible) ?? false) appActive=\(NSApp.isActive) appHidden=\(NSApp.isHidden) window=\(panel?.windowNumber ?? -1) level=\(panel?.level.rawValue ?? 0) alpha=\(panel?.alphaValue ?? 0) key=\(panel?.isKeyWindow ?? false) hidesOnDeactivate=\(panel?.hidesOnDeactivate ?? false) frame=\(frame) mode=\(modeStore.mode)"
        let message: Core.LogMessage = "[Trace#\(context.traceID ?? 0, privacy: .public)] popup \(metadata, privacy: .public)"
        Log.presentation.debug(message)
    }

    @objc private func panelOcclusionDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        logPresentation("occlusion-changed")
    }

    public var isVisible: Bool { (panel?.isVisible == true) || (currentContext != nil) }

    /// Starts a session without creating AppKit window monitors or ordering windows on screen.
    func startTestSession(for context: SelectionContext, pasteAvailable: Bool? = nil, initialMode: PopupMode = .actions) {
        isMenuTracking = false
        let selectionContext = context.with(
            pasteTargetAvailable: PasteAvailability.effective(policy: context.appPolicy, probe: pasteAvailable)
        )
        currentContext = selectionContext
        captureFrontmostAppIfNeeded()
        let actionContext = ActionContext(selection: selectionContext, modifiers: [])
        currentActionContext = actionContext
        modeStore.mode = initialMode
        modeStore.canPaste = pasteAvailable
    }

    /// Records the frontmost app before the panel becomes key. Captures once per session (hide() clears it), never OpenClip itself.
    private func captureFrontmostAppIfNeeded() {
        guard previousFrontmostApp == nil,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        previousFrontmostApp = app
    }

    /// Makes the panel key (a scoped exception to the never-key rule) without activating OpenClip, so the source app stays active.
    private func enterKeyMode() {
        guard let panel else { return }
        captureFrontmostAppIfNeeded()
        panel.allowsKey = true
        if NSClassFromString("XCTestCase") == nil {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Restores the never-key invariant and returns focus to the source app. Does not clear it: only hide() ends the session.
    private func exitKeyMode() {
        panel?.allowsKey = false
        if NSApp.isActive {
            previousFrontmostApp?.activate(options: [.activateAllWindows])
        }
    }

    // MARK: - AI Result Card

    /// True while the card is on screen and the user has dragged it aside (pinning it open). Un-dragged cards dismiss on outside clicks.
    public var cardIsModal: Bool { modeStore.mode == .content && hasUserMovedCard }
    public private(set) var hasUserMovedCard: Bool = false

    /// Applies a streaming "processing" flag only for its own session, so a stale stream can't re-stick isProcessingAI.
    func setAIProcessing(_ active: Bool, session: UUID) {
        guard session == aiSessionID else { return }
        modeStore.isProcessingAI = active
    }

    /// Shows an action's text (or error) in the result card and makes the panel key so Esc can collapse it. Paste and Copy are
    /// explicit requests and skip the paste-vs-copy re-decision. Chunks from abandoned streams are dropped.
    func showResultCard(
        text: String,
        isError: Bool,
        title: String,
        icon: ActionIcon? = nil,
        isStreaming: Bool = false,
        session: UUID,
        originalText: String? = nil,
        overrideOriginal: Bool = false,
        canFollowUp: Bool = true,
        file: FileOutputPayload? = nil
    ) {
        guard session == aiSessionID else { return }
        if toastController.isLoading {
            toastController.hide()
        }
        modeStore.isProcessingAI = isStreaming
        let original = overrideOriginal ? originalText : currentActionContext?.selection.text
        // The selection the action ran on rides along so the card can diff input → output.
        modeStore.resultCard = ResultCardPayload(
            text: text,
            isError: isError,
            title: title,
            icon: icon,
            isStreaming: isStreaming,
            original: original,
            canFollowUp: canFollowUp,
            file: file
        )
        if !isStreaming {
            // A settled card hands keyboard focus to its instruction field.
            Task { @MainActor in
                await Task.yield()
                self.focusCardField()
            }
        }
        if modeStore.mode != .content {
            hasUserMovedCard = false
            panel?.pinBottomEdgeOnResize = modeStore.searchResultsAbove
            panel?.horizontalAnchor = .center
            // A remembered card may exceed the default cap; let the panel grow to the screen.
            if let panel { panel.heightCap = screenBounds(for: panel).height }
            if isStreaming {
                // Lock dimensions on the first chunk so streaming doesn't resize the panel.
                modeStore.resultCardSize = rememberedSize(for: .card) ?? CGSize(
                    width: PopupMetrics.aiCardIdealWidth,
                    height: PopupMetrics.aiCardMinHeight
                )
                modeStore.isSurfaceUserSized = true
            } else {
                modeStore.resultCardSize = rememberedSize(for: .card)
                modeStore.isSurfaceUserSized = false
            }
            modeStore.mode = .content
            orderFrontIfHeadless()
            enterKeyMode()
        }

        // Nudge the hosting view to re-measure; NSHostingView won't re-measure on its own.
        fitPanelToContent()
        // Retry after the display cycle (DispatchQueue.main.async, not Task.yield, which doesn't guarantee a display pass).
        DispatchQueue.main.async { [weak self] in
            self?.fitPanelToContent()
        }
        // Safety-net retry: SwiftUI swaps the whole view tree on first content-mode entry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.modeStore.mode == .content else { return }
            self.fitPanelToContent()
        }
    }

    /// True while a settled AI result card is on screen, so push-to-talk continues its thread.
    var canContinueConversation: Bool {
        guard panel?.isVisible == true, modeStore.mode == .content, let card = modeStore.resultCard else { return false }
        return card.canFollowUp && !card.isStreaming && !card.isError
    }

    var isCardVisible: Bool { panel?.isVisible == true }

    /// True while an AI stream, loading action or loading toast is in flight.
    var isVoiceBusy: Bool {
        toastController.isLoading || modeStore.isProcessingAI || activeLoadingTask != nil || activeStreamingTask != nil
    }

    func presentAgentCard(text: String, title: String, isError: Bool = false, file: FileOutputPayload? = nil) {
        showResultCard(text: text, isError: isError, title: title, session: aiSessionID, canFollowUp: !isError, file: file)
    }

    func deliverAgentResult(_ result: ActionResult) {
        _ = handleActionResult(result, delivery: deliverySnapshot(), suppressDeliveryToast: result.containsToast)
    }

    private func orderFrontIfHeadless() {
        guard let panel, !panel.isVisible, NSClassFromString("XCTestCase") == nil else { return }
        panel.orderFront(nil)
        setupMonitors()
    }

    /// Re-measures the hosting view, resizes the panel to its content, and nudges it back on screen.
    private func fitPanelToContent() {
        guard let contentView = panel?.contentView else { return }
        contentView.invalidateIntrinsicContentSize()
        contentView.layoutSubtreeIfNeeded()
        resizePanel(to: sanitizedPopupSize(contentView.fittingSize))
        keepPanelOnScreen()
    }

    /// Minimally moves an auto-placed resizable surface back on screen. User-dragged cards are left alone.
    private func keepPanelOnScreen() {
        guard let panel, panel.isVisible, resizableSurface != nil, !hasUserMovedCard else { return }
        let bounds = screenBounds(for: panel).insetBy(dx: PopupMetrics.popupPadding, dy: PopupMetrics.popupPadding)
        var origin = panel.frame.origin
        origin.x = max(min(origin.x, bounds.maxX - panel.frame.width), bounds.minX)
        origin.y = max(min(origin.y, bounds.maxY - panel.frame.height), bounds.minY)
        if origin != panel.frame.origin {
            panel.setFrameOrigin(origin)
        }
    }

    // MARK: - Resizable Surfaces

    /// The resizable popup surface: the result card.
    private enum ResizableSurface {
        case card

        var minSize: CGSize {
            CGSize(width: PopupMetrics.aiCardMinWidth, height: PopupMetrics.aiCardMinHeight)
        }

        var widthKey: SettingKey<Double> { SettingKey.resultCardWidth }

        var heightKey: SettingKey<Double> { SettingKey.resultCardHeight }
    }

    /// The resizable surface on screen, if any (only the result card).
    private var resizableSurface: ResizableSurface? {
        switch modeStore.mode {
        case .content: return .card
        case .actions: return nil
        }
    }

    private func liveSize(for surface: ResizableSurface) -> CGSize? {
        switch surface {
        case .card: return modeStore.resultCardSize
        }
    }

    private func setLiveSize(_ size: CGSize?, for surface: ResizableSurface) {
        switch surface {
        case .card: modeStore.resultCardSize = size
        }
    }

    /// Last user size for `surface`, fitted to `screenBounds`; nil until resized, so default sizing applies.
    private func rememberedSize(for surface: ResizableSurface, in screenBounds: CGRect? = nil) -> CGSize? {
        let width = settingsStore.get(surface.widthKey)
        let height = settingsStore.get(surface.heightKey)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let bounds = screenBounds ?? panel.map { self.screenBounds(for: $0) } ?? Self.fallbackScreenBounds
        return PopupResizeGeometry.fit(CGSize(width: width, height: height), minSize: surface.minSize, in: bounds)
    }

    private static let fallbackScreenBounds = NSRect(x: 0, y: 0, width: 800, height: 600)

    private func screenBounds(for panel: PopupPanel) -> CGRect {
        panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? Self.fallbackScreenBounds
    }

    /// Panel and cursor position at drag start; nil when no drag is in flight.
    private var cardDragAnchor: (mouse: CGPoint, origin: CGPoint)?

    /// Moves the panel with the cursor, computed from the absolute cursor position against the `.began` anchor. A translation-based
    /// move would fight the moving window and crawl.
    func handleCardDrag(_ phase: ResultCardDragPhase, mouseLocation: CGPoint? = nil) {
        guard let panel else { return }
        let mouse = mouseLocation ?? NSEvent.mouseLocation
        switch phase {
        case .began:
            panel.prepareForUserDrag()
            cardDragAnchor = (mouse: mouse, origin: panel.frame.origin)
        case .changed:
            guard let anchor = cardDragAnchor else { return }
            panel.setFrameOrigin(CGPoint(x: anchor.origin.x + (mouse.x - anchor.mouse.x),
                                         y: anchor.origin.y + (mouse.y - anchor.mouse.y)))
        case .ended:
            cardDragAnchor = nil
            panel.endUserDrag()
            if modeStore.mode == .content {
                hasUserMovedCard = true
            }
        }
    }

    /// Toggles the card's pin. Pinning makes it modal (same gate as dragging), suppressing auto-dismiss.
    func pinCard() {
        let nowPinned = !modeStore.isCardPinned
        modeStore.isCardPinned = nowPinned
        hasUserMovedCard = nowPinned
    }

    // MARK: - Resize

    /// Cursor, size, and surface captured at resize start; nil when no resize is in flight.
    private var resizeAnchor: (mouse: CGPoint, size: CGSize, surface: ResizableSurface)?

    /// Resizes the card from its handle, like `handleCardDrag`: absolute cursor position against the `.began` anchor, top-left fixed,
    /// clamped to the surface minimum and the screen. `.ended` remembers the size.
    func handleResize(_ edge: PopupResizeEdge, phase: ResultCardDragPhase, mouseLocation: CGPoint? = nil) {
        guard let panel, let surface = resizableSurface else { return }
        let mouse = mouseLocation ?? NSEvent.mouseLocation
        switch phase {
        case .began:
            // Same panel state as a move: no click-through mid-drag, and no re-centering or bottom pinning that would fight the top-left frames.
            panel.prepareForUserDrag()
            panel.pinBottomEdgeOnResize = false
            // Start from the on-screen size so the handle stays under the pointer; the dragged size is then used verbatim.
            modeStore.isSurfaceUserSized = true
            resizeAnchor = (mouse: mouse, size: currentSurfaceSize(in: panel), surface: surface)
        case .changed:
            guard let anchor = resizeAnchor, anchor.surface == surface else { return }
            let proposed = PopupResizeGeometry.size(
                from: anchor.size, edge: edge, anchorMouse: anchor.mouse, mouse: mouse)
            let size = PopupResizeGeometry.clamp(
                proposed,
                minSize: surface.minSize,
                panelTopLeft: CGPoint(x: panel.frame.minX, y: panel.frame.maxY),
                screenBounds: screenBounds(for: panel))
            applySize(size, for: surface, to: panel)
        case .ended:
            guard let anchor = resizeAnchor, anchor.surface == surface else { return }
            resizeAnchor = nil
            panel.endUserDrag()
            // The dragged size persists until the surface closes (`isSurfaceUserSized`).
            if let size = liveSize(for: surface) {
                settingsStore.set(surface.widthKey, value: Double(size.width))
                settingsStore.set(surface.heightKey, value: Double(size.height))
            }
        }
    }

    /// On-screen surface size: the panel frame minus the shadow ring. Default sizes are never reported, so this is where the first resize starts.
    private func currentSurfaceSize(in panel: PopupPanel) -> CGSize {
        let ring = 2 * PopupMetrics.popupShadowInset
        return CGSize(width: panel.frame.width - ring, height: panel.frame.height - ring)
    }

    /// Applies a size: the panel is the surface plus its shadow ring, with the top-left corner fixed.
    private func applySize(_ size: CGSize, for surface: ResizableSurface, to panel: PopupPanel) {
        setLiveSize(size, for: surface)
        let ring = 2 * PopupMetrics.popupShadowInset
        let panelSize = CGSize(width: size.width + ring, height: size.height + ring)
        panel.setFrame(CGRect(x: panel.frame.minX, y: panel.frame.maxY - panelSize.height,
                              width: panelSize.width, height: panelSize.height), display: true)
    }

    // MARK: - Card Buttons

    /// Runs an explicit card button (Paste/Copy) with no delivery context. Dismissing results hide the popup first, so exitKeyMode() reactivates the target app.
    private func performCardEffect(_ result: ActionResult) {
        if result.dismissesPopup {
            hide()
            handleActionResult(result, delivery: nil)
        } else {
            _ = handleEffect(result, delivery: nil)
        }
    }

    // MARK: - Panel Resize

    /// Resizes the panel to its content, anchored like `PopupPanel.setFrame`: a resize drag keeps the top-left; otherwise the
    /// bottom-edge pin decides. Screen and height clamping live in `PopupPanel.setFrame`.
    private func resizePanel(to proposedSize: CGSize) {
        guard let panel, panel.isVisible else { return }
        let size = sanitizedPopupSize(proposedSize)
        let current = panel.frame.size
        if abs(current.width - size.width) < 1, abs(current.height - size.height) < 1 { return }
        if resizeAnchor != nil {
            // A resize handle is being dragged: the surface's top-left corner is the fixed point.
            panel.setFrame(CGRect(x: panel.frame.minX, y: panel.frame.maxY - size.height,
                                  width: size.width, height: size.height), display: true)
        } else if panel.pinBottomEdgeOnResize {
            // Bottom edge pinned (popup low on screen): keep it fixed, grow upward.
            panel.setFrame(CGRect(x: panel.frame.minX, y: panel.frame.minY,
                                  width: size.width, height: size.height), display: true)
        } else {
            // Keep the top edge fixed, grow downward.
            let newOriginY = panel.frame.maxY - size.height
            panel.setFrame(CGRect(x: panel.frame.minX, y: newOriginY,
                                  width: size.width, height: size.height), display: true)
        }
        updateToastPlacement()
    }

    private func syncPanelAppearance(_ targetPanel: NSPanel) {
        let appearanceToken = settingsStore.get(SettingKey.popupThemeColor)
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let isDark = PopupThemeModel.effectiveScheme(appearance: appearanceToken, systemIsDark: systemIsDark) == .dark
        targetPanel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    private func sanitizedPopupSize(_ raw: CGSize?) -> CGSize {
        var size = raw ?? CGSize(width: 300, height: 54)
        size.width = max(size.width, 100)
        size.height = max(size.height, 30)
        return size
    }

    private func positionPanel(_ panel: PopupPanel, size: CGSize, for context: SelectionContext) {
        let screen = PopupPositioner.screen(containing: context.cursorPosition) ?? NSScreen.main
        let screenBounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let frame = PopupPositioner.calculateFrame(
            for: context,
            popupSize: size,
            in: screenBounds
        )
        panel.setFrame(frame, display: true)
        if let anchor = activeVoiceAnchor {
            alignToVoiceAnchor(panel, anchor: anchor, bounds: screenBounds)
        }
    }

    /// Centres the card on the pill's column, overlapping the pill's spot on the side the card grows toward.
    private func alignToVoiceAnchor(_ panel: PopupPanel, anchor: NSRect, bounds: NSRect) {
        var frame = panel.frame
        frame.origin.x = min(max(anchor.midX - frame.width / 2, bounds.minX), max(bounds.minX, bounds.maxX - frame.width))
        frame.origin.y = cardAbove ? anchor.minY : anchor.maxY - frame.height
        frame.origin.y = min(max(frame.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - frame.height))
        panel.setFrame(frame, display: true)
    }

    public func hide(reason: String = #function, callerLine: Int = #line) {
        logPresentation("hide reason=\(reason) callerLine=\(callerLine)")
        // End the AI session first: cancel the stream and invalidate its token so in-flight chunks are dropped.
        activeStreamingTask?.cancel()
        activeStreamingTask = nil
        activeLoadingTask?.cancel()
        activeLoadingTask = nil
        activeLoadingID = nil
        aiSessionID = UUID()
        refiningPrevious = nil
        cardConversation = nil

        if toastController.currentFeedback?.keepVisible == true || toastController.isLoading
            || isCaptureToastCurrent {
            toastController.hide()
        }
        captureToastPresentationID = nil
        modeStore.resultCard = nil
        modeStore.resultCardSize = nil
        modeStore.isSurfaceUserSized = false
        modeStore.canPaste = nil
        // Clear click intent so a stale intent or declared delivery can't leak into the next session.
        pendingClickIntent = .primary
        pendingDelivery = nil
        pendingActionTitle = nil
        pendingActionIcon = nil
        pendingActionID = nil
        pendingActionRecommendedResult = nil
        pendingActionOutputKind = nil
        isScrollDismissalSuspended = false
        distanceDismissGraceUntil = nil
        isRightClickInProgress = false
        modeStore.isProcessingAI = false
        modeStore.mode = .actions
        panel?.pinBottomEdgeOnResize = false
        panel?.horizontalAnchor = .none
        panel?.heightCap = PopupMetrics.popupMaxHeight
        panel?.endUserDrag()
        cardDragAnchor = nil
        resizeAnchor = nil
        hasUserMovedCard = false
        modeStore.isCardPinned = false
        sessionShowTime = 0
        panel?.ignoresMouseEvents = false // clear click-through from the last session
        exitKeyMode() // allowsKey=false + reactivate previousFrontmostApp
        previousFrontmostApp = nil // hide() is the only thing that ends the key-mode session
        panel?.orderOut(nil)
        removeMonitors()
        currentContext = nil
        currentActionContext = nil
        isMenuTracking = false
    }

    /// Cancels any in-flight background tasks (loading actions and AI streaming) and hides the toast.
    @MainActor
    public func cancelActiveTasks() {
        if activeLoadingTask != nil || activeStreamingTask != nil {
            Log.presentation.info("Cancelling active in-flight task(s) via loading toast")
        }
        activeLoadingTask?.cancel()
        activeLoadingTask = nil
        activeLoadingID = nil
        activeStreamingTask?.cancel()
        activeStreamingTask = nil
        inFlightDeliveryContext = nil
        modeStore.isProcessingAI = false
        toastController.hide()
    }
    
    private func setupMonitors() {
        removeMonitors()

        let canMonitorGlobally = PermissionManager.shared.isAccessibilityGranted
        usesGlobalMouseMonitoring = canMonitorGlobally
        if canMonitorGlobally {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .rightMouseUp, .mouseMoved, .keyDown]) { [weak self] event in
                self?.handleEvent(event)
            }
        } else {
            Log.presentation.notice("Accessibility permission unavailable; using local event tracking.")
        }
        
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp, .mouseMoved, .keyDown]) { [weak self] event in
            self?.handleEvent(event)
            return event
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(panelOcclusionDidChange(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidBeginTracking), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidEndTracking), name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidDeactivate), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceDidActivateApp(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceActiveSpaceDidChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }
    
    @objc private func menuDidBeginTracking() {
        isMenuTracking = true
    }
    
    @objc private func menuDidEndTracking() {
        isMenuTracking = false
    }
    
    private func removeMonitors() {
        if let global = globalEventMonitor {
            NSEvent.removeMonitor(global)
            globalEventMonitor = nil
        }
        if let local = localEventMonitor {
            NSEvent.removeMonitor(local)
            localEventMonitor = nil
        }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func handleEvent(_ event: NSEvent) {
        if isMenuTracking { return }

        switch event.type {
        case .mouseMoved:
            updateClickThrough(at: NSEvent.mouseLocation)
        case .leftMouseDown:
            // Content test, not frame test: clicks in the shadow ring count as outside clicks.
            let inCard = isOverPanelContent(NSEvent.mouseLocation)
            pendingClickIntent = event.modifierFlags.contains(.shift) ? .secondary : .primary
            if !inCard && !cardIsModal {
                hide()
            }
        case .rightMouseDown:
            if isOverPanelContent(NSEvent.mouseLocation) {
                pendingClickIntent = .secondary
                isRightClickInProgress = true
            } else {
                isRightClickInProgress = false
                if !cardIsModal { hide() }
            }
        case .rightMouseUp:
            isRightClickInProgress = false
        case .keyDown:
            // Esc belongs to the SwiftUI card while the panel is key (handling it here would double-fire). If the panel lost key
            // (the card was clicked into another app), the monitor must answer Esc itself.
            if event.keyCode == 53, panel?.isKeyWindow != true {
                hide()
            }
        default:
            break
        }
    }

    /// Whether a screen point is over the popup's interactive content (panel minus the shadow ring). Ring clicks count as outside
    /// clicks; a panel frame check would swallow them. Internal so tests can pin this contract.
    func isOverPanelContent(_ screenLocation: CGPoint) -> Bool {
        guard let panel, panel.isVisible, let contentView = panel.contentView,
              panel.frame.contains(screenLocation) else { return false }
        let windowPoint = panel.convertPoint(fromScreen: screenLocation)
        let contentPoint = contentView.convert(windowPoint, from: nil)
        if contentView is PopupPanel.ContentView {
            return PopupPanel.ContentView.isInsideClickableRegion(point: contentPoint, bounds: contentView.bounds)
        }
        return contentView.bounds.contains(contentPoint)
    }

    /// Click-through over the shadow ring lets clicks reach the app below. Only with global monitoring: otherwise nothing
    /// notices re-entry and the panel would stay inert.
    private func updateClickThrough(at screenLocation: CGPoint) {
        guard usesGlobalMouseMonitoring, let panel, panel.isVisible, !panel.isUserDragging else { return }
        let overContent = isOverPanelContent(screenLocation)
        panel.ignoresMouseEvents = !overContent
        if overContent { NSCursor.arrow.set() }
    }

    @objc private func appDidDeactivate() {
        // A right-click resigns active before rightMouseUp; skip hide() so the right-click completes. Modal cards survive focus changes.
        if !isMenuTracking && !isRightClickInProgress && !cardIsModal {
            hide()
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        // A key panel resigns key when another window is clicked. Dismiss unless modal.
        if !cardIsModal {
            hide()
        }
    }

    @objc private func workspaceDidActivateApp(_ notification: Notification) {
        guard let app = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            ?? NSWorkspace.shared.frontmostApplication else { return }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        // The selection's source app may activate without dismissing.
        if let sourceBundleID = currentContext?.sourceApp.bundleIdentifier,
           app.bundleIdentifier == sourceBundleID {
            return
        }
        // Grace period: a clipboard manager's self-dismiss can queue an activation for the destination app. Ignore it within 300 ms of opening.
        if sessionShowTime > 0,
           (ProcessInfo.processInfo.systemUptime - sessionShowTime) < PopupMetrics.focusSwitchGracePeriod {
            return
        }
        // Modal result cards survive focus changes (parity with appDidDeactivate).
        if cardIsModal { return }
        if !isRightClickInProgress {
            hide()
        }
    }

    @objc private func workspaceActiveSpaceDidChange() {
        hide()
    }

    /// Frontmost app when an in-place answer lands; pasting is only safe into the selection's app. Settable for tests.
    var frontmostBundleIDProvider: @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    /// Runs an AI instruction on the selection: `replace` pastes the answer over the selection,
    /// otherwise it streams into the result card. `includeContext: false` treats it as a standalone question.
    func runAIPrompt(_ instruction: String, replace: Bool, includeContext: Bool = true) {
        let replace = replace && currentActionContext?.selection.source != .ocr
        let prompt = PaletteAIPrompt.instruction(from: instruction)
        guard !prompt.isEmpty else { return }
        let taskPrompt = includeContext
            ? PaletteAIPrompt.askAITaskPrompt(for: prompt)
            : PaletteAIPrompt.standaloneQuestionPrompt(for: prompt)
        let inputText: String? = includeContext ? nil : ""
        if replace {
            Log.ai.notice("Running a palette AI prompt, replacing the selection")
            runAIPromptReplacing(prompt: taskPrompt, inputText: inputText)
        } else {
            Log.ai.notice("Running a palette AI prompt into the result card")
            runAIPreset(prompt: taskPrompt, title: PaletteAIPrompt.toolTitle(for: prompt), inputText: inputText)
        }
    }

    /// Runs `prompt` on the selection and pastes the answer over it, with no card. Copies instead when the target can't paste
    /// or the frontmost app changed.
    func runAIPromptReplacing(prompt: String, loadingMessage: String? = nil, inputText: String? = nil, onGeneratedTitle: ((String) -> Void)? = nil) {
        guard let context = currentActionContext else {
            Log.ai.error("Cannot replace with AI: currentActionContext is nil")
            return
        }
        activeStreamingTask?.cancel()
        activeStreamingTask = nil

        let selection = context.selection
        let selectionText = inputText ?? selection.text
        let anchorFrame = toastAnchorFrame
        let targetCanPaste = PasteAvailability.effective(policy: selection.appPolicy, probe: modeStore.canPaste)
        let sourceBundleID = selection.sourceApp.bundleIdentifier

        hide()
        let session = aiSessionID
        toastController.showLoading(message: loadingMessage ?? String(localized: "Replacing…"), anchorFrame: anchorFrame) { [weak self] in
            self?.cancelActiveTasks()
        }

        let task = Task { @MainActor in
            self.modeStore.isProcessingAI = true
            defer {
                if !Task.isCancelled {
                    self.activeStreamingTask = nil
                    self.modeStore.isProcessingAI = false
                }
            }
            do {
                let provider = AIServiceManager.shared.currentProvider
                var accumulated = ""
                for try await chunk in provider.processStream(prompt: prompt, text: selectionText) {
                    guard !Task.isCancelled, session == self.aiSessionID else {
                        self.toastController.hide()
                        return
                    }
                    accumulated += chunk
                    if let generated = AIRequestSupport.extractTitleText(accumulated), !generated.isEmpty {
                        onGeneratedTitle?(generated)
                    }
                }
                guard !Task.isCancelled, session == self.aiSessionID else {
                    self.toastController.hide()
                    return
                }
                if let generated = AIRequestSupport.extractTitleText(accumulated), !generated.isEmpty {
                    onGeneratedTitle?(generated)
                }
                let answer = AIRequestSupport.extractResultText(accumulated)
                guard !answer.isEmpty else { throw AIError.invalidResponse }
                let stillInSourceApp = sourceBundleID == nil || self.frontmostBundleIDProvider() == sourceBundleID
                let pastes = targetCanPaste != false && stillInSourceApp
                self.handleActionResult(pastes ? .paste(answer) : .copy(answer), delivery: nil, suppressDeliveryToast: true)
                let message = pastes
                    ? String(localized: "Replaced with AI result")
                    : (stillInSourceApp ? String(localized: "Copied AI result") : String(localized: "Copied — the app changed"))
                self.toastController.show(StatusFeedback(message: message, style: .success, symbolName: "sparkle"), anchorFrame: anchorFrame)
            } catch is CancellationError {
                self.toastController.hide()
            } catch let error as AIError where error == .cancelled {
                self.toastController.hide()
            } catch {
                guard !Task.isCancelled, session == self.aiSessionID else {
                    self.toastController.hide()
                    return
                }
                Log.ai.error("Replacing with AI failed: \(error.localizedDescription)")
                self.toastController.show(StatusFeedback(error: error), anchorFrame: anchorFrame)
            }
        }
        activeStreamingTask = task
    }

    /// Runs a follow-up instruction on the card's current text. The card re-streams in place and diffs against the text it ran on.
    func runFollowUp(_ instruction: String) {
        guard let card = modeStore.resultCard, !card.isStreaming, !card.isError, currentActionContext != nil else { return }
        let prompt = PaletteAIPrompt.instruction(from: instruction)
        guard !prompt.isEmpty else { return }
        Log.ai.notice("Running a follow-up instruction in the result card")
        refineCard(card, prompt: prompt, title: PaletteAIPrompt.toolTitle(for: prompt))
    }

    /// The card a follow-up refines, kept so cancel or failure can restore it. Non-nil only while in flight.
    private var refiningPrevious: ResultCardPayload?

    /// Session history handed to follow-ups as labelled context.
    private(set) var cardConversation: AIConversation?

    /// Runs a follow-up inside the card: nothing hides, and the previous answer stays dimmed until the first chunk. Esc cancels;
    /// a failure restores the previous answer.
    private func refineCard(_ previous: ResultCardPayload, prompt: String, title: String) {
        activeStreamingTask?.cancel()
        activeStreamingTask = nil
        let session = aiSessionID
        let sourceText = previous.text
        // The history rides along as labelled context; the current instruction stays the task.
        let conversation = cardConversation
            ?? AIConversation(original: previous.original ?? sourceText, steps: [])
        let followUpTask = conversation.followUpTask(current: prompt)
        refiningPrevious = previous
        modeStore.isProcessingAI = true
        freezeCardSizeForRefinement()
        modeStore.resultCard = ResultCardPayload(
            text: sourceText,
            isError: false,
            title: title,
            icon: nil,
            isStreaming: true,
            original: previous.original,
            isRefining: true
        )

        let task = Task { @MainActor in
            defer {
                if !Task.isCancelled {
                    self.activeStreamingTask = nil
                    self.modeStore.isProcessingAI = false
                }
            }
            // The card is the only render target; chunks after leaving content mode or session end are dropped.
            @MainActor func stillRefining() -> Bool {
                if Task.isCancelled { return false }
                if session != self.aiSessionID { return false }
                if self.modeStore.mode != .content { return false }
                return self.refiningPrevious != nil
            }
            do {
                let provider = AIServiceManager.shared.currentProvider
                var accumulated = ""
                var activeTitle = title
                for try await chunk in provider.processStream(prompt: followUpTask, text: sourceText) {
                    guard stillRefining() else { return }
                    accumulated += chunk
                    if let newTitle = AIRequestSupport.extractTitleText(accumulated), !newTitle.isEmpty {
                        activeTitle = newTitle
                    }
                    let cleaned = AIRequestSupport.extractResultText(accumulated)
                    if !cleaned.isEmpty {
                        self.showResultCard(text: cleaned, isError: false, title: activeTitle, isStreaming: true, session: session, originalText: previous.original, overrideOriginal: true)
                    }
                }
                guard stillRefining() else { return }
                if let newTitle = AIRequestSupport.extractTitleText(accumulated), !newTitle.isEmpty {
                    activeTitle = newTitle
                }
                let finalResponse = AIRequestSupport.extractResultText(accumulated)
                if finalResponse.isEmpty {
                    self.restoreRefiningCard()
                    self.toastController.show(StatusFeedback(message: String(localized: "No response generated"), style: .error), anchorFrame: self.panel?.frame)
                } else {
                    self.refiningPrevious = nil
                    self.cardConversation = conversation.appending(instruction: prompt, result: finalResponse)
                    self.showResultCard(text: finalResponse, isError: false, title: activeTitle, isStreaming: false, session: session, originalText: previous.original, overrideOriginal: true)
                }
            } catch is CancellationError {
                // cancelFollowUp / hide already put the card back or took it down.
            } catch let error as AIError where error == .cancelled {
                // Same as above: cancelFollowUp / hide already restored the card.
            } catch {
                guard stillRefining() else { return }
                Log.ai.error("Follow-up failed in the result card: \(error.localizedDescription)")
                self.restoreRefiningCard()
                self.toastController.show(StatusFeedback(error: error), anchorFrame: self.panel?.frame)
            }
        }
        activeStreamingTask = task
    }

    /// Freezes the card at its current size so streaming refinements don't re-measure it per chunk. The body scrolls if needed.
    /// A card the user already resized is left alone.
    private func freezeCardSizeForRefinement() {
        guard !modeStore.isSurfaceUserSized, let panel else { return }
        let frozen = Self.cardSize(forPanelSize: panel.frame.size)
        guard frozen.width >= PopupMetrics.aiCardMinWidth, frozen.height >= PopupMetrics.aiCardMinHeight else { return }
        modeStore.resultCardSize = frozen
        modeStore.isSurfaceUserSized = true
    }

    /// The card's size inside a panel frame: the panel minus the transparent shadow ring.
    static func cardSize(forPanelSize size: CGSize) -> CGSize {
        CGSize(width: size.width - 2 * PopupMetrics.popupShadowInset, height: size.height - 2 * PopupMetrics.popupShadowInset)
    }

    /// Puts the answer the follow-up was refining back, settled, with the field focused again.
    private func restoreRefiningCard() {
        guard let previous = refiningPrevious else { return }
        refiningPrevious = nil
        modeStore.isProcessingAI = false
        showResultCard(text: previous.text, isError: previous.isError, title: previous.title, icon: previous.icon, isStreaming: false, session: aiSessionID, originalText: previous.original, overrideOriginal: true, canFollowUp: previous.canFollowUp)
    }

    /// Esc while a follow-up streams: stop it and keep the previous answer on screen.
    func cancelFollowUp() {
        guard refiningPrevious != nil else { return }
        Log.ai.info("Follow-up cancelled in the result card")
        activeStreamingTask?.cancel()
        activeStreamingTask = nil
        restoreRefiningCard()
    }

    /// Focuses the card's instruction field on the next run-loop turn; a @FocusState request during the mode change is dropped on macOS.
    private func focusCardField() {
        guard let panel, panel.isVisible, modeStore.mode == .content else { return }
        guard let field = Self.findEditableTextField(in: panel.contentView) else { return }
        panel.makeFirstResponder(field)
    }

    /// The first editable text field in a view tree (the result card's follow-up field), or nil.
    static func findEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let found = findEditableTextField(in: subview) { return found }
        }
        return nil
    }

    func runAIPreset(prompt: String, title: String, loadingMessage: String? = nil, inputText: String? = nil, onGeneratedTitle: ((String) -> Void)? = nil) {
        guard let context = currentActionContext else {
            Log.ai.error("Cannot run AI preset: currentActionContext is nil")
            return
        }
        activeStreamingTask?.cancel()
        activeStreamingTask = nil

        let selection = context.selection
        let selectionText = inputText ?? selection.text
        let originalForCard = inputText != nil ? (inputText!.isEmpty ? nil : inputText) : nil
        let overrideOriginal = inputText != nil
        let anchorFrame = toastAnchorFrame
        let targetCanPaste = PasteAvailability.effective(policy: selection.appPolicy, probe: modeStore.canPaste)

        hide()
        let session = aiSessionID

        toastController.showLoading(message: loadingMessage ?? String(localized: "Generating…"), anchorFrame: anchorFrame) { [weak self] in
            self?.cancelActiveTasks()
        }

        let task = Task { @MainActor in
            self.modeStore.isProcessingAI = true
            defer {
                if !Task.isCancelled {
                    self.activeStreamingTask = nil
                    self.modeStore.isProcessingAI = false
                }
            }

            var hasYielded = false
            var activeTitle = title

            do {
                let provider = AIServiceManager.shared.currentProvider

                var accumulated = ""

                for try await chunk in provider.processStream(prompt: prompt, text: selectionText) {
                    guard !Task.isCancelled, session == self.aiSessionID else {
                        self.toastController.hide()
                        return
                    }
                    accumulated += chunk
                    if let newTitle = AIRequestSupport.extractTitleText(accumulated), !newTitle.isEmpty {
                        activeTitle = newTitle
                        onGeneratedTitle?(newTitle)
                    }
                    let cleaned = AIRequestSupport.extractResultText(accumulated)
                    if !cleaned.isEmpty {
                        if !hasYielded {
                            hasYielded = true
                            self.toastController.hide()
                            let canPaste = targetCanPaste
                            guard !Task.isCancelled, session == self.aiSessionID else { return }
                            self.reopenSession(for: selection, pasteAvailable: canPaste)
                        }
                        self.showResultCard(text: cleaned, isError: false, title: activeTitle, isStreaming: true, session: session, originalText: originalForCard, overrideOriginal: overrideOriginal)
                    }
                }

                guard !Task.isCancelled, session == self.aiSessionID else {
                    self.toastController.hide()
                    return
                }
                self.toastController.hide()
                if let newTitle = AIRequestSupport.extractTitleText(accumulated), !newTitle.isEmpty {
                    activeTitle = newTitle
                    onGeneratedTitle?(newTitle)
                }
                let finalResponse = AIRequestSupport.extractResultText(accumulated)
                if finalResponse.isEmpty {
                    if !hasYielded {
                        let canPaste = targetCanPaste
                        guard !Task.isCancelled, session == self.aiSessionID else { return }
                        self.reopenSession(for: selection, pasteAvailable: canPaste)
                        self.showResultCard(text: "No response generated", isError: true, title: activeTitle, isStreaming: false, session: session, originalText: originalForCard, overrideOriginal: overrideOriginal)
                    }
                } else {
                    if !hasYielded {
                        let canPaste = targetCanPaste
                        guard !Task.isCancelled, session == self.aiSessionID else { return }
                        self.reopenSession(for: selection, pasteAvailable: canPaste)
                    }
                    // A fresh run starts the card's session history; refineCard extends it.
                    if inputText == nil {
                        self.cardConversation = AIConversation(original: selectionText, steps: [.init(instruction: prompt, result: finalResponse)])
                    } else {
                        self.cardConversation = AIConversation(original: finalResponse, steps: [.init(instruction: prompt, result: finalResponse)])
                    }
                    self.showResultCard(text: finalResponse, isError: false, title: activeTitle, isStreaming: false, session: session, originalText: originalForCard, overrideOriginal: overrideOriginal)
                }
            } catch is CancellationError {
                Log.ai.info("AI streaming cancelled")
                self.toastController.hide()
            } catch {
                guard !Task.isCancelled, session == self.aiSessionID else {
                    self.toastController.hide()
                    return
                }
                self.toastController.hide()
                Log.ai.error("AI preset execution failed: \(error.localizedDescription)")
                if !hasYielded {
                    let canPaste = targetCanPaste
                    guard !Task.isCancelled, session == self.aiSessionID else { return }
                    self.reopenSession(for: selection, pasteAvailable: canPaste)
                }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.showResultCard(text: message, isError: true, title: title, isStreaming: false, session: session, originalText: originalForCard, overrideOriginal: overrideOriginal)
            }
        }
        activeStreamingTask = task
    }
    
    /// Settable in `init` so the effect-delivery tests can inject a recording handler.
    var resultHandler: ActionResultHandler

    // MARK: - Decision 8: ActionResult Tree-Walk

    /// Inputs to the paste-vs-copy decision, captured synchronously when an action performs. `nil` (explicit user requests) means never re-decided.
    struct DeliveryContext {
        let policy: AppPolicyContext
        let clickIntent: ActionResultDelivery.ClickIntent
        /// Declared delivery (secondary outcome and per-click toasts); nil means none.
        let delivery: ActionDelivery?
        /// Target app for delivery, captured synchronously; `exitKeyMode()` reactivates this app on hide.
        let application: NSRunningApplication?
        /// The user's per-action override if one was configured in Action Editor.
        let userOverride: ResultDeliveryPreference?
        /// The author's recommended delivery mode.
        let recommendedResult: ActionResultDeliveryMode?
        /// The action's uncommitted output kind.
        let outputKind: ActionOutputKind?
        /// The performing action's title — the result card header. nil for explicit user requests.
        let actionTitle: String?
        /// Display icon for the card header (customization-resolved).
        let actionIcon: ActionIcon?
        /// Input/destination requirements rechecked immediately before effects are executed.
        let inputRequirement: ActionInputRequirement?
        let requiresPasteTarget: Bool
        /// The selection context captured before any early-close (loading actions), used to re-show
        /// the popup with a result card when the outcome is text or a file. nil when the popup never closed.
        let selection: SelectionContext?

        /// Resolves a declared secondary on a secondary click. Consuming it sets `clickIntent` to `.primary` and moves
        /// `secondaryToast` to `primaryToast`, so explicit outcomes aren't downgraded by the clipboard invariant.
        func consumeDeclaredSecondary(for result: ActionResult) -> (result: ActionResult, delivery: DeliveryContext) {
            guard clickIntent == .secondary, let declared = delivery?.secondary else {
                return (result, self)
            }
            let consumed = DeliveryContext(
                policy: policy,
                clickIntent: .primary,
                delivery: ActionDelivery(secondary: nil, primaryToast: delivery?.secondaryToast, secondaryToast: nil),
                application: application,
                userOverride: userOverride,
                recommendedResult: recommendedResult,
                outputKind: outputKind,
                actionTitle: actionTitle,
                actionIcon: actionIcon,
                inputRequirement: inputRequirement,
                requiresPasteTarget: requiresPasteTarget,
                selection: selection
            )
            return (declared, consumed)
        }
    }

    /// Snapshots delivery inputs synchronously, before any dismissal or await.
    func deliverySnapshot(for action: (any Action)? = nil, clickIntent: ActionResultDelivery.ClickIntent? = nil) -> DeliveryContext {
        let intent = clickIntent ?? pendingClickIntent
        let actionDelivery = action?.delivery ?? pendingDelivery
        let title = action?.title ?? pendingActionTitle
        let icon = action?.displayIcon(using: ActionCustomizationManager.shared) ?? pendingActionIcon
        let actionID = action?.id ?? pendingActionID
        let targetApp = previousFrontmostApp ?? (frontmostApplicationProvider()?.bundleIdentifier != Bundle.main.bundleIdentifier ? frontmostApplicationProvider() : previousFrontmostApp)
        let override = actionID.flatMap { ActionCustomizationManager.shared.override(for: $0)?.deliveryPreference }
        let rec = action?.chrome.recommendedResult ?? pendingActionRecommendedResult
        let outKind = action?.chrome.outputKind ?? pendingActionOutputKind
        return DeliveryContext(
            policy: currentActionContext?.selection.appPolicy ?? .default,
            clickIntent: intent,
            delivery: actionDelivery,
            application: targetApp,
            userOverride: override,
            recommendedResult: rec,
            outputKind: outKind,
            actionTitle: title,
            actionIcon: icon,
            inputRequirement: (action as? any ActionWithRules).map { $0.rules?.requirements?.input ?? .text },
            requiresPasteTarget: (action as? any ActionWithRules)?.rules?.requirements?.requiresPasteTarget ?? false,
            selection: currentActionContext?.selection
        )
    }

    /// Whether the target app is still frontmost; async paste must not post into a new foreground window.
    private func isTargetApplicationActive(_ targetApp: NSRunningApplication?) -> Bool {
        guard let targetApp else { return true }
        guard let frontmost = frontmostApplicationProvider() else { return true }
        if frontmost.bundleIdentifier == Bundle.main.bundleIdentifier {
            return true
        }
        return frontmost.processIdentifier == targetApp.processIdentifier
    }

    /// Declared paste-target requirements also apply to the async paste probe.
    private func requiredPasteTargetIsActive(_ delivery: DeliveryContext?) -> Bool {
        guard let delivery, delivery.requiresPasteTarget else { return true }
        return isTargetApplicationActive(delivery.application)
    }

    /// Routes a performed result into the tree-walk. The delivery snapshot is taken before `hide()` clears the live context, and
    /// is single-use: a later paste must never reuse a prior action's declaration.
    func deliverResult(_ result: ActionResult, delivery: DeliveryContext? = nil) {
        let resolvedDelivery = delivery ?? inFlightDeliveryContext ?? deliverySnapshot()
        inFlightDeliveryContext = nil
        pendingDelivery = nil
        pendingActionTitle = nil
        pendingActionIcon = nil
        pendingActionID = nil
        pendingActionRecommendedResult = nil
        pendingActionOutputKind = nil
        let (deliveredResult, effectiveDelivery) = resolvedDelivery.consumeDeclaredSecondary(for: result)
        let effectiveResult = normalizeOCRResult(deliveredResult, delivery: effectiveDelivery)
        if shouldDismiss(effectiveResult, delivery: effectiveDelivery) {
            hide()
        }
        handleActionResult(effectiveResult, delivery: effectiveDelivery, suppressDeliveryToast: effectiveResult.containsToast)
    }

    private func copyOnlyOCRResult(_ result: ActionResult) -> ActionResult {
        switch result {
        case .paste(let text), .cut(let text): return .copy(text)
        case .pasteContent(let payload): return .copyContent(payload)
        case .simulatePaste: return .none
        case .sequence(let items): return .sequence(items.map(copyOnlyOCRResult))
        default: return result
        }
    }

    private func normalizeOCRResult(_ result: ActionResult, delivery: DeliveryContext?) -> ActionResult {
        let isOCRDelivery = delivery?.selection?.source == .ocr
            || (delivery == nil && currentContext?.source == .ocr)
        let ocrSafe = isOCRDelivery ? copyOnlyOCRResult(result) : result
        guard let delivery, delivery.inputRequirement != nil || delivery.requiresPasteTarget else { return ocrSafe }

        let selection = delivery.selection
        let input = delivery.inputRequirement ?? .optional
        let hasText = !(selection?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let liveAndCurrent = selection?.source == .selection
            && (selection.map(selectionIsCurrent) ?? false)
            && isTargetApplicationActive(delivery.application)
        let inputSatisfied: Bool
        switch input {
        case .optional: inputSatisfied = true
        case .text: inputSatisfied = hasText
        case .liveSelection: inputSatisfied = hasText && liveAndCurrent
        case .editableSelection: inputSatisfied = hasText && liveAndCurrent && selection?.isEditable == true
        }
        let pasteTargetSatisfied = !delivery.requiresPasteTarget
            || (selection?.pasteTargetAvailable == true
                && PasteAvailability.effective(policy: delivery.policy, probe: selection?.pasteTargetAvailable) == true
                && isTargetApplicationActive(delivery.application))
        return inputSatisfied && pasteTargetSatisfied ? ocrSafe : .none
    }

    /// Walks a performed result: presentation renders in the popup, leaf effects go to the effect handler. Dismissal is decided
    /// once at the top level. A top-level `.toast` suppresses delivery toasts, and a `.sequence` runs its items in order.
    @discardableResult
    func handleActionResult(_ result: ActionResult, delivery: DeliveryContext? = nil, suppressDeliveryToast: Bool = false) -> Task<Void, Never>? {
        let (selectedResult, effectiveDelivery) = delivery?.consumeDeclaredSecondary(for: result) ?? (result, delivery)
        let effectiveResult = normalizeOCRResult(selectedResult, delivery: effectiveDelivery)
        let effectiveSuppressToast = suppressDeliveryToast || effectiveResult.containsToast
        switch effectiveResult {
        case .toast(let feedback):
            presentToast(feedback)
            return nil
        case .openConfiguration(let request):
            presentConfiguration(for: request)
            return nil
        case .sequence(let items):
            return Task { @MainActor in
                for item in items {
                    await self.handleActionResult(item, delivery: effectiveDelivery, suppressDeliveryToast: effectiveSuppressToast)?.value
                }
            }
        default:
            return handleEffect(effectiveResult, delivery: effectiveDelivery, suppressDeliveryToast: effectiveSuppressToast)
        }
    }

    /// Routes a leaf effect to DefaultActionResultHandler. A thrown error becomes a dismissing error toast. Applies the paste-vs-copy
    /// decision (`.paste` becomes `.copy` on force-copy, policy, or an unavailable target); nil `delivery` passes through.
    @discardableResult
    private func handleEffect(_ result: ActionResult, delivery: DeliveryContext?, suppressDeliveryToast: Bool = false) -> Task<Void, Never> {
        let effect = result
        return Task { @MainActor in
            do {
                let resolved = await resolveDelivery(effect, delivery: delivery, suppressDeliveryToast: suppressDeliveryToast)
                guard requiredPasteTargetIsActive(delivery) else { return }
                if case .text(let text) = resolved.result {
                    // Preview: show the text in the card and deliver nothing; the popup stays open. Probe paste if it was skipped,
                    // so the card gates Paste on a real answer (unknown normalizes to cannot-paste).
                    if modeStore.canPaste == nil {
                        modeStore.canPaste = await pasteProbe.canPaste(in: delivery?.application, policy: delivery?.policy ?? .default) ?? false
                    }
                    showResultCard(text: text, isError: false, title: delivery?.actionTitle ?? "Action", icon: delivery?.actionIcon, session: aiSessionID, canFollowUp: false)
                    return
                }
                if case .file(let filePayload) = resolved.result {
                    showResultCard(
                        text: filePayload.displayName,
                        isError: false,
                        title: delivery?.actionTitle ?? filePayload.displayName,
                        icon: delivery?.actionIcon,
                        session: aiSessionID,
                        canFollowUp: false,
                        file: filePayload
                    )
                    return
                }
                // A detached-surface result suspends scroll dismissal for the rest of the session.
                isScrollDismissalSuspended = resolved.result.suspendsScrollDismissal
                try await resultHandler.handle(resolved.result, in: panel?.contentView, targetApp: delivery?.application,
                                               isSelectionCurrent: { [weak self] selection in
                    self?.selectionIsCurrent(selection) == true
                })
                let toastToShow: StatusFeedback? = {
                    if let toast = resolved.toast {
                        if case .saveFile = resolved.result {
                            let saveDir = settingsStore.get(.fileSaveLocation)
                            let folderName = !saveDir.isEmpty ? URL(fileURLWithPath: (saveDir as NSString).expandingTildeInPath).lastPathComponent : "Downloads"
                            return StatusFeedback(message: String(localized: "Saved to \(folderName)"), style: .success, symbolName: "arrow.down.circle")
                        }
                        return toast
                    }
                    if delivery == nil {
                        switch resolved.result {
                        case .saveFile:
                            let saveDir = settingsStore.get(.fileSaveLocation)
                            let folderName = !saveDir.isEmpty ? URL(fileURLWithPath: (saveDir as NSString).expandingTildeInPath).lastPathComponent : "Downloads"
                            return StatusFeedback(message: String(localized: "Saved to \(folderName)"), style: .success, symbolName: "arrow.down.circle")
                        case .copyFile:
                            return StatusFeedback(message: String(localized: "Copied File"), style: .success, symbolName: "doc.on.doc")
                        default:
                            return nil
                        }
                    }
                    return nil
                }()
                if let toast = toastToShow, !suppressDeliveryToast {
                    toastController.show(toast, anchorFrame: toastAnchorFrame)
                }
            } catch {
                handleActionResult(.toast(StatusFeedback(error: error)))
            }
        }
    }

    /// Decides a text result's delivery and companion toast from the snapshot. A nil `delivery` passes through with no toast.
    /// The paste probe runs only when a paste outcome is on the table, since only `.paste` can downgrade to `.copy`.
    internal var selectionIsCurrent: @MainActor (SelectionContext) -> Bool = { _ in true }
    internal private(set) var lastDeliveryStatus: SelectionReadStatus?

    private func resolveDelivery(_ result: ActionResult, delivery: DeliveryContext?, suppressDeliveryToast: Bool = false) async -> (result: ActionResult, toast: StatusFeedback?) {
        guard let delivery else { return (result, nil) }
        let selected = ActionResultDelivery.select(
            raw: result,
            clickIntent: delivery.clickIntent,
            delivery: delivery.delivery ?? .none,
            preference: delivery.userOverride,
            recommendedResult: delivery.recommendedResult,
            outputKind: delivery.outputKind
        )
        let couldPaste = delivery.selection?.source != .ocr && isPaste(selected)
        let isTargetActive = isTargetApplicationActive(delivery.application)
            && (delivery.selection.map(selectionIsCurrent) ?? true)
        var canPaste: Bool
        if !couldPaste || !isTargetActive {
            canPaste = false
        } else if !PasteAvailability.needsProbe(policy: delivery.policy) {
            canPaste = PasteAvailability.effective(policy: delivery.policy, probe: nil) ?? false
        } else {
            canPaste = await pasteProbe.canPaste(in: delivery.application, policy: delivery.policy) ?? false
        }
        // A target may change while the AX paste probe is suspended.
        if couldPaste, !isTargetApplicationActive(delivery.application)
            || !(delivery.selection.map(selectionIsCurrent) ?? true) {
            canPaste = false
        }
        if couldPaste, !isTargetActive || !(delivery.selection.map(selectionIsCurrent) ?? true)
            || !isTargetApplicationActive(delivery.application) {
            lastDeliveryStatus = .targetChanged
            Log.selection.debug("delivery outcome: targetChanged")
        } else {
            lastDeliveryStatus = nil
        }
        let resolved = ActionResultDelivery.resolve(
            raw: result,
            clickIntent: delivery.clickIntent,
            canPaste: canPaste,
            delivery: delivery.delivery ?? .none,
            preference: delivery.userOverride,
            recommendedResult: delivery.recommendedResult,
            outputKind: delivery.outputKind
        )
        return (resolved.result, suppressDeliveryToast ? nil : resolved.toast)
    }

    private func isPaste(_ result: ActionResult?) -> Bool {
        guard let result else { return false }
        switch result {
        case .paste, .pasteContent:
            return true
        default:
            return false
        }
    }

    private func isText(_ result: ActionResult) -> Bool {
        guard case .text = result else { return false }
        return true
    }

    /// Top-level dismissal: the popup stays open only when the resolved outcome is `.text` (preview) or `.file`. Mirrors the resolver's
    /// Select step so dismissal matches the delivered outcome. `canPaste` does not matter here.
    private func shouldDismiss(_ result: ActionResult, delivery: DeliveryContext) -> Bool {
        let (effectiveResult, effectiveDelivery) = delivery.consumeDeclaredSecondary(for: result)
        let resolved = ActionResultDelivery.resolve(
            raw: effectiveResult,
            clickIntent: effectiveDelivery.clickIntent,
            canPaste: false,
            delivery: effectiveDelivery.delivery ?? .none,
            preference: effectiveDelivery.userOverride,
            recommendedResult: effectiveDelivery.recommendedResult,
            outputKind: effectiveDelivery.outputKind
        ).result
        if isText(resolved) { return false }
        if case .file = resolved { return false }
        return resolved.dismissesPopup
    }

    /// Runs a bindable action from a per-action hotkey or the voice agent. Reuses the on-screen session if up; otherwise opens on the selection so paste and preview have a delivery context.
    func runBoundAction(_ action: any Action, with context: ActionContext, pasteAvailable: Bool? = nil) {
        guard canPerformAction(action, in: context) else { return }
        if currentActionContext == nil || panel?.isVisible != true {
            beginSession(for: context.selection, pasteAvailable: pasteAvailable)
        } else if let pasteAvailable {
            modeStore.canPaste = pasteAvailable
        }
        if ActionIdentity.isAIPreset(action) {
            guard let preset = AIServiceManager.shared.preset(forActionID: action.id) else { return }
            runAIPreset(prompt: AIServiceManager.shared.promptForPreset(preset), title: preset.title)
            return
        }
        runAction(action, with: context, isSecondaryClick: false)
    }

    /// Perform-time gate for clicks, group actions, and hotkeys. Visibility is recomputed from the captured context; source-bound
    /// requirements also check the selection generation and target app.
    private func canPerformAction(_ action: any Action, in context: ActionContext) -> Bool {
        guard action.isEnabled(for: context) else { return false }
        guard let ruledAction = action as? any ActionWithRules else { return true }
        let requirements = ruledAction.rules?.requirements ?? ActionRequirements()
        let selection = context.selection
        let liveAndCurrent = selection.source == .selection
            && selectionIsCurrent(selection)
            && isTargetApplicationActive(previousFrontmostApp)
        switch requirements.input {
        case .optional, .text:
            break
        case .liveSelection:
            guard liveAndCurrent else { return false }
        case .editableSelection:
            guard liveAndCurrent, selection.isEditable == true else { return false }
        }
        if requirements.requiresPasteTarget {
            guard context.pasteTargetAvailable == true,
                  PasteAvailability.effective(policy: selection.appPolicy, probe: context.pasteTargetAvailable) == true,
                  isTargetApplicationActive(previousFrontmostApp) else { return false }
        }
        return true
    }

    /// Performs an action directly for the right-click path, which the SwiftUI button never fires. Builds the delivery context
    /// from `isSecondaryClick`.
    func runAction(_ action: any Action, with context: ActionContext, isSecondaryClick: Bool) {
        guard canPerformAction(action, in: context) else { return }
        if action.chrome.showsLoading {
            runLoadingAction(action, with: context, isSecondaryClick: isSecondaryClick)
            return
        }
        let clickIntent: ActionResultDelivery.ClickIntent = isSecondaryClick ? .secondary : .primary
        pendingClickIntent = clickIntent
        // Snapshot the declared delivery and title into the DeliveryContext. Pending state stays untouched: no onWillPerformAction precedes this path.
        let delivery = deliverySnapshot(for: action, clickIntent: clickIntent)
        inFlightDeliveryContext = delivery
        let match = action.matchInfo(for: context)
        let performContext = ActionContext(
            selection: context.selection,
            modifiers: context.modifiers,
            isSecondaryClick: isSecondaryClick,
            match: match
        )
        Task { @MainActor in
            do {
                let result = try await action.perform(performContext)
                let (effectiveResult, effectiveDelivery) = delivery.consumeDeclaredSecondary(for: result)
                if self.shouldDismiss(effectiveResult, delivery: effectiveDelivery) {
                    self.hide()
                }
                self.handleActionResult(effectiveResult, delivery: effectiveDelivery, suppressDeliveryToast: effectiveResult.containsToast)
                self.inFlightDeliveryContext = nil
            } catch {
                Log.presentation.error("Action failed (id \(action.id, privacy: .public)): \(error.localizedDescription)")
                self.handleActionResult(.toast(StatusFeedback(error: error)))
                self.inFlightDeliveryContext = nil
            }
        }
    }

    /// Performs a `showsLoading` action with early close: the popup hides, a spinner toast attaches to its last frame, and the
    /// result settles the toast.
    func runLoadingAction(_ action: any Action, with context: ActionContext, isSecondaryClick: Bool) {
        guard canPerformAction(action, in: context) else { return }
        let clickIntent: ActionResultDelivery.ClickIntent = isSecondaryClick ? .secondary : .primary
        pendingClickIntent = clickIntent
        // Snapshot the declared delivery and title into the DeliveryContext; pending state stays untouched.
        let delivery = deliverySnapshot(for: action, clickIntent: clickIntent)
        inFlightDeliveryContext = delivery
        let match = action.matchInfo(for: context)
        let performContext = ActionContext(
            selection: context.selection,
            modifiers: context.modifiers,
            isSecondaryClick: isSecondaryClick,
            match: match
        )
        // Capture before the early hide so the spinner attaches to where the popup actually was.
        let anchorFrame = toastAnchorFrame
        hide()
        let message = action.chrome.loadingMessage ?? String(localized: "Opening \(action.title)…")
        toastController.showLoading(message: message, anchorFrame: anchorFrame) { [weak self] in
            self?.cancelActiveTasks()
        }
        let runID = UUID()
        activeLoadingID = runID
        let loadingTask = Task { @MainActor in
            defer {
                if self.activeLoadingID == runID {
                    self.activeLoadingTask = nil
                    self.activeLoadingID = nil
                }
            }
            do {
                let result = try await action.perform(performContext)
                guard !Task.isCancelled else {
                    self.toastController.hide()
                    return
                }
                let (effectiveResult, effectiveDelivery) = delivery.consumeDeclaredSecondary(for: result)
                await self.settleLoadingResult(effectiveResult, delivery: effectiveDelivery, suppressDeliveryToast: effectiveResult.containsToast)
            } catch is CancellationError {
                Log.presentation.info("Loading action cancelled (id \(action.id, privacy: .public))")
                self.toastController.hide()
            } catch {
                guard !Task.isCancelled else {
                    self.toastController.hide()
                    return
                }
                Log.presentation.error("Action failed (id \(action.id, privacy: .public)): \(error.localizedDescription)")
                await self.settleLoadingResult(.toast(StatusFeedback(error: error)), delivery: delivery)
            }
        }
        activeLoadingTask = loadingTask
    }

    /// Settles a loading action's spinner toast from its result: `.toast` swaps in, a delivery toast swaps in, and other
    /// results fade the spinner. With `suppressDeliveryToast`, the script toast owns the toast (one per run).
    private func settleLoadingResult(_ result: ActionResult, delivery: DeliveryContext, suppressDeliveryToast: Bool = false) async {
        let (selectedResult, effectiveDelivery) = delivery.consumeDeclaredSecondary(for: result)
        let effectiveResult = normalizeOCRResult(selectedResult, delivery: effectiveDelivery)
        let effectiveSuppressToast = suppressDeliveryToast || effectiveResult.containsToast
        switch effectiveResult {
        case .toast(var feedback):
            feedback.keepVisible = false
            toastController.show(feedback)
        case .openConfiguration(let request):
            toastController.hide()
            presentConfiguration(for: request)
        case .sequence(let items):
            for item in items { await settleLoadingResult(item, delivery: effectiveDelivery, suppressDeliveryToast: effectiveSuppressToast) }
        default:
            let effect = effectiveResult
            do {
                let resolved = await resolveDelivery(effect, delivery: effectiveDelivery, suppressDeliveryToast: effectiveSuppressToast)
                guard requiredPasteTargetIsActive(effectiveDelivery) else {
                    toastController.hide()
                    return
                }
                if case .text(let text) = resolved.result {
                    // Preview on a loading action: hide the spinner and re-show the popup as a card at the original selection, re-probing paste.
                    toastController.hide()
                    if let selection = effectiveDelivery.selection {
                        let canPaste = await pasteProbe.canPaste(in: effectiveDelivery.application, policy: effectiveDelivery.policy) ?? false
                        guard requiredPasteTargetIsActive(effectiveDelivery) else {
                            toastController.hide()
                            return
                        }
                        reopenSession(for: selection, pasteAvailable: canPaste)
                        showResultCard(text: text, isError: false, title: effectiveDelivery.actionTitle ?? "Action", icon: effectiveDelivery.actionIcon, session: aiSessionID, canFollowUp: false)
                    }
                    return
                }
                if case .file(let filePayload) = resolved.result {
                    toastController.hide()
                    if let selection = effectiveDelivery.selection {
                        let canPaste = await pasteProbe.canPaste(in: effectiveDelivery.application, policy: effectiveDelivery.policy) ?? false
                        reopenSession(for: selection, pasteAvailable: canPaste)
                        showResultCard(
                            text: filePayload.displayName,
                            isError: false,
                            title: effectiveDelivery.actionTitle ?? filePayload.displayName,
                            icon: effectiveDelivery.actionIcon,
                            session: aiSessionID,
                            canFollowUp: false,
                            file: filePayload
                        )
                    }
                    return
                }
                try await resultHandler.handle(resolved.result, in: panel?.contentView)
                let toastToShow: StatusFeedback? = {
                    if let toast = resolved.toast {
                        if case .saveFile = resolved.result {
                            let saveDir = settingsStore.get(.fileSaveLocation)
                            let folderName = !saveDir.isEmpty ? URL(fileURLWithPath: (saveDir as NSString).expandingTildeInPath).lastPathComponent : "Downloads"
                            return StatusFeedback(message: String(localized: "Saved to \(folderName)"), style: .success, symbolName: "arrow.down.circle")
                        }
                        return toast
                    }
                    return nil
                }()
                if let toast = toastToShow, !effectiveSuppressToast {
                    toastController.swapTo(toast)
                } else if !effectiveSuppressToast {
                    toastController.hide()
                }
            } catch {
                await settleLoadingResult(.toast(StatusFeedback(error: error)), delivery: effectiveDelivery)
            }
        }
    }

    /// Feedback lives in its own window; the action panel never grows or shrinks for it.
    func updateToastPlacement() {
        guard toastController.isShowing, toastController.currentPlacement != .overlay, let panel else { return }
        toastController.reposition(anchorFrame: panel.frame, avoidanceRects: [])
    }

    /// Shows feedback near an explicit point or the current cursor; popup/group frames are
    /// avoidance rectangles, not the position of the toast.
    public func showToast(_ feedback: StatusFeedback, at point: CGPoint? = nil) {
        let placement = point.map { ToastPlacement.nearCursor($0) }
        toastController.show(feedback, anchorFrame: toastAnchorFrame, placement: placement)
    }

    /// Status feedback uses its own cursor-relative window even after the popup has hidden.
    private func presentToast(_ feedback: StatusFeedback) {
        showToast(feedback)
    }

    /// Config-open: posts the configuration notification so Preferences presents the action's editor.
    private func presentConfiguration(for request: ConfigurationRequest) {
        NotificationCenter.default.post(
            name: .openClipOpenActionConfiguration,
            object: nil,
            userInfo: ["request": request]
        )
    }
}
