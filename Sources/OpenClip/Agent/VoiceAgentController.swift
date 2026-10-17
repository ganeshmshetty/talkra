// VoiceAgentController.swift
// OpenClip
//
// Push-to-talk voice agent. Key-down snapshots the selection and starts listening; key-up routes
// the transcript: a clearly named installed action runs directly, otherwise the AI router picks
// rewrite / answer / synthesized script / clarification. Results reuse the popup controller's
// headless session (result card, toasts, in-place paste).
import AppKit
import KeyboardShortcuts
import Core

@MainActor
final class VoiceAgentController {
    private let popup: PopupWindowController
    private let hotkeys: HotkeyManager
    private let transcriber: any SpeechTranscribing
    private let pill: VoicePillPanelController
    private let settingsStore: SettingsStore

    private var isListening = false
    private var voiceRunActive = false
    private var interceptedLoading = false
    private var watchTask: Task<Void, Never>?
    private var continuesCard = false
    private var selectionTask: Task<SelectionContext?, Never>?
    private var runTask: Task<Void, Never>?
    private var pendingClarification: SelectionContext?
    private var recentTurns: [AgentTurn] = []
    private var lastTurnAt: Date?

    /// A new command within this window after a result keeps the previous turns as context.
    private static let conversationWindow: TimeInterval = 20
    private static let messageDuration: UInt64 = 1_600_000_000
    private static let noticeDuration: UInt64 = 1_100_000_000

    init(
        popup: PopupWindowController,
        hotkeys: HotkeyManager = .shared,
        transcriber: any SpeechTranscribing = OnDeviceSpeechTranscriber(),
        pill: VoicePillPanelController = VoicePillPanelController(),
        settingsStore: SettingsStore = DefaultSettingsStore.shared
    ) {
        self.popup = popup
        self.hotkeys = hotkeys
        self.transcriber = transcriber
        self.pill = pill
        self.settingsStore = settingsStore
    }

    func install() {
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            MainActor.assumeIsolated { self?.keyDown() }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            MainActor.assumeIsolated { self?.keyUp() }
        }
        pill.model.onChipSelected = { [weak self] option in
            self?.chipSelected(option)
        }
        pill.onEscape = { [weak self] in self?.cancelRun() }
        pill.model.onClose = { [weak self] in self?.cancelRun() }
        popup.toastController.interceptor = { [weak self] feedback in
            self?.takeOverToast(feedback) ?? false
        }
    }

    // MARK: - Push-to-talk lifecycle

    /// Esc while the pill has focus: drop the transcript and stop whatever is running.
    private func cancelRun() {
        let wasListening = isListening
        isListening = false
        runTask?.cancel()
        selectionTask?.cancel()
        pendingClarification = nil
        popup.cancelActiveTasks()
        if wasListening { Task { @MainActor in _ = await self.transcriber.stop() } }
        finishPill()
    }

    func keyDown() {
        // Key repeat delivers further key-downs while held.
        guard !isListening, KeyboardShortcuts.isEnabled else { return }
        guard settingsStore.get(.pauseUntilTimestamp) <= Date().timeIntervalSince1970 else { return }
        runTask?.cancel()
        pendingClarification = nil
        isListening = true
        voiceRunActive = true
        watchTask?.cancel()
        continuesCard = popup.canContinueConversation

        // Read the selection now, while the source app still owns focus; the pill never activates.
        if continuesCard {
            selectionTask = nil
        } else {
            let frontmost = NSWorkspace.shared.frontmostApplication
            let hotkeys = self.hotkeys
            selectionTask = Task { @MainActor in
                await hotkeys.collectTrigger(frontmostApp: frontmost, allowsEmptyText: true)?.context
            }
        }

        pill.model.phase = .listening(transcript: "", levels: [])
        pill.show(anchor: nil)
        popup.setVoiceAnchor(nil)
        transcriber.onUpdate = { [weak self] update in
            guard let self, self.isListening else { return }
            self.pill.model.push(transcript: update.transcript, level: update.level)
        }
        Task { @MainActor in
            _ = await self.selectionTask?.value
            if self.isListening { self.pill.takeKeyFocus() }
        }
        Task { @MainActor in
            do {
                try await self.transcriber.start()
            } catch {
                Log.ai.error("Push-to-talk could not start: \(error.localizedDescription, privacy: .public)")
                self.isListening = false
                self.selectionTask?.cancel()
                self.flash(Self.message(for: error), isError: true)
            }
        }
    }

    func keyUp() {
        guard isListening else { return }
        isListening = false
        pill.releaseKeyFocus()
        runTask = Task { @MainActor in
            await self.finishListening()
        }
    }

    private func finishListening() async {
        let transcript = await transcriber.stop().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Task.isCancelled else { return }
        guard !transcript.isEmpty else {
            selectionTask?.cancel()
            notice(String(localized: "Didn't catch that."), symbol: "mic.slash")
            return
        }
        if continuesCard {
            finishPill()
            popup.runFollowUp(transcript)
            return
        }
        pill.model.phase = .working(label: String(localized: "Thinking…"))
        guard let selection = await selectionTask?.value else {
            if hotkeys.lastTriggerResponse?.status == .policyBlocked {
                notice(String(localized: "Voice commands are off in this app."), symbol: "nosign")
            } else {
                notice(String(localized: "Couldn't read the selection. Try again."), symbol: "text.cursor")
            }
            return
        }
        await handle(transcript, selection: Self.voiceSelection(from: selection))
    }

    private func chipSelected(_ option: String) {
        guard let selection = pendingClarification else { return }
        pendingClarification = nil
        pill.model.phase = .working(label: String(localized: "Thinking…"))
        runTask?.cancel()
        runTask = Task { @MainActor in
            await self.handle(option, selection: selection)
        }
    }

    // MARK: - Routing

    private func handle(_ transcript: String, selection: SelectionContext) async {
        let actionContext = ActionContext(selection: selection)
        let actions = Self.candidateActions(for: actionContext)
        let descriptors = actions.map { action in
            ActionDescriptor(
                id: action.id,
                title: action.displayTitle(using: ActionCustomizationManager.shared),
                keywords: action.keywords
            )
        }

        if let id = CommandMatcher.confidentMatch(transcript, actions: descriptors),
           let action = actions.first(where: { $0.id == id }) {
            Log.ai.notice("Voice command matched action \(id, privacy: .public)")
            run(action, context: actionContext)
            return
        }

        guard AIServiceManager.shared.isAIEnabled else {
            flash(String(localized: "No matching action. Turn on AI to handle any request."), isError: true)
            return
        }

        let request = AgentRequest(
            transcript: transcript,
            selectedText: selection.text,
            appBundleID: selection.sourceApp.bundleIdentifier,
            history: activeHistory()
        )
        let decision: AgentDecision
        do {
            decision = try await decide(request, actions: descriptors)
        } catch is CancellationError {
            return
        } catch {
            Log.ai.error("Voice routing fell back to an answer: \(error.localizedDescription, privacy: .public)")
            decision = .answer(instruction: transcript)
        }
        guard !Task.isCancelled else { return }
        await execute(decision, request: request, selection: selection, actions: actions)
    }

    private func decide(_ request: AgentRequest, actions: [ActionDescriptor]) async throws -> AgentDecision {
        let provider = AIServiceManager.shared.currentProvider
        let budget = Self.routingBudget(for: provider.type)
        if let decision = await DecisionRouter.current.decide(request: request, actions: actions, budget: budget) {
            return decision
        }
        if provider.type == .apple {
            return try await AppleIntelligenceRouting.decide(request: request, actions: actions, budget: budget)
        }
        let prompt = AgentPrompts.routing(request, actions: actions, maxActions: budget.maxActions, allowsScripts: budget.allowsScripts)
        let text = AgentPrompts.clipped(request.selectedText, to: budget.selectionSample)
        let knownIDs = Set(actions.map(\.id))
        do {
            let raw = try await provider.process(prompt: prompt, text: text)
            return try AgentDecisionParser.parse(AIRequestSupport.extractResultText(raw), knownActionIDs: knownIDs)
        } catch AgentError.malformedDecision {
            Log.ai.notice("Voice routing reply was not a valid decision; retrying once")
            let raw = try await provider.process(prompt: prompt + "\n\n" + AgentPrompts.strictJSONReminder, text: text)
            return try AgentDecisionParser.parse(AIRequestSupport.extractResultText(raw), knownActionIDs: knownIDs)
        }
    }

    static func routingBudget(for provider: AIProviderType) -> RoutingBudget {
        switch provider {
        case .apple: return .onDevice
        case .local: return .local
        case .cli, .cloud: return .full
        }
    }

    private func execute(_ decision: AgentDecision, request: AgentRequest, selection: SelectionContext, actions: [any Action]) async {
        switch decision {
        case .runAction(let actionID):
            guard let action = actions.first(where: { $0.id == actionID }) else { return }
            run(action, context: ActionContext(selection: selection))
        case .rewrite(let instruction):
            handOffToPopup()
            popup.beginSession(for: selection, pasteAvailable: selection.pasteTargetAvailable)
            popup.runAIPrompt(AgentPrompts.instruction(instruction, history: request.history), replace: true, includeContext: request.hasSelection)
            remember(request.transcript, result: "")
        case .answer(let instruction):
            handOffToPopup()
            popup.beginSession(for: selection, pasteAvailable: selection.pasteTargetAvailable)
            popup.runAIPrompt(AgentPrompts.instruction(instruction, history: request.history), replace: false, includeContext: request.hasSelection)
            remember(request.transcript, result: "")
        case .clarify(let question, let options):
            pendingClarification = selection
            pill.model.phase = .clarify(question: question, options: options)
        case .synthesize(let script, let delivery):
            guard Self.routingBudget(for: AIServiceManager.shared.currentProvider.type).allowsScripts else {
                notice(String(localized: "This needs a stronger AI model. Choose a cloud model or CLI in Settings › AI."), symbol: "sparkles")
                return
            }
            await runSynthesized(script, delivery: delivery, request: request, selection: selection)
        }
    }

    private func run(_ action: any Action, context: ActionContext) {
        handOffToPopup()
        popup.runBoundAction(action, with: context, pasteAvailable: context.selection.pasteTargetAvailable)
        remember(action.title, result: "")
    }

    // MARK: - Code synthesis

    private func runSynthesized(_ script: SynthesizedScript, delivery: AgentDelivery, request: AgentRequest, selection: SelectionContext) async {
        pill.model.phase = .working(label: String(localized: "Running script…"))
        let context = ActionContext(selection: selection)
        let outcome = await SelfHealingExecutor.run(script) { candidate in
            try await SynthesizedScriptRunner.run(candidate, context: context)
        } repair: { failed, error in
            Log.ai.notice("Synthesized \(failed.language.rawValue, privacy: .public) script failed; asking for a fix")
            self.pill.model.phase = .working(label: String(localized: "Fixing script…"))
            let raw = try await AIServiceManager.shared.currentProvider.process(
                prompt: AgentPrompts.repair(failed, error: error, request: request),
                text: AgentPrompts.clipped(request.selectedText)
            )
            let body = AIRequestSupport.extractResultText(raw)
            guard let code = CodeBlockExtractor.extract(from: body, expected: failed.language) else {
                throw AgentError.noCodeInResponse
            }
            return SynthesizedScript(language: failed.language, code: code)
        }
        guard !Task.isCancelled else { return }

        switch outcome {
        case .success(let result, _, _):
            handOffToPopup()
            popup.beginSession(for: selection, pasteAvailable: selection.pasteTargetAvailable)
            deliver(result, delivery: delivery, title: request.transcript)
        case .failure(let message, let failed, let attempts):
            Log.ai.error("Synthesized script failed after \(attempts, privacy: .public) attempt(s)")
            handOffToPopup()
            popup.beginSession(for: selection, pasteAvailable: selection.pasteTargetAvailable)
            let text = String(localized: "The script failed: \(message)") + "\n\n```\(failed.language.rawValue)\n\(failed.code)\n```"
            popup.presentAgentCard(text: text, title: request.transcript, isError: true)
        }
    }

    private func deliver(_ result: ActionResult, delivery: AgentDelivery, title: String) {
        guard case .text(let text) = result else {
            popup.deliverAgentResult(result)
            remember(title, result: "")
            return
        }
        remember(title, result: text)
        switch delivery {
        case .replace:
            popup.deliverAgentResult(.paste(text))
        case .card:
            popup.presentAgentCard(text: text, title: title)
        case .silent:
            let message = AgentPrompts.clipped(text.trimmingCharacters(in: .whitespacesAndNewlines), to: 80)
            popup.deliverAgentResult(.toast(StatusFeedback(message: message.isEmpty ? String(localized: "Done") : message, style: .success)))
        }
    }

    // MARK: - Helpers

    /// The pill is the one status surface for a voice run: popup loading and result toasts render in it
    /// instead of separate toast windows, so listening, thinking and the outcome share one shape.
    private func takeOverToast(_ feedback: StatusFeedback?) -> Bool {
        guard voiceRunActive else { return false }
        guard let feedback else {
            if interceptedLoading { finishPill() }
            return true
        }
        if feedback.isLoading {
            interceptedLoading = true
            pill.model.phase = .working(label: feedback.message)
            if !pill.isVisible { pill.show(anchor: nil) }
        } else {
            interceptedLoading = false
            flash(feedback.message, isError: feedback.style == .error)
        }
        return true
    }

    /// Keeps the pill up while the popup works, telling it where the pill is so a result card opens in
    /// its place; the pill goes once the card is up or the work has finished.
    private func handOffToPopup() {
        if pill.isVisible { popup.setVoiceAnchor(pill.frame) }
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            var idleTicks = 0
            for _ in 0..<800 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, !Task.isCancelled, self.voiceRunActive, !self.isListening,
                      case .working = self.pill.model.phase else { return }
                if self.popup.isCardVisible { self.finishPill(); return }
                idleTicks = self.popup.isVoiceBusy ? 0 : idleTicks + 1
                if idleTicks > 10 { self.finishPill(); return }
            }
            self?.finishPill()
        }
    }

    private func finishPill() {
        pill.hide()
        voiceRunActive = false
        interceptedLoading = false
    }

    private func remember(_ instruction: String, result: String) {
        if let lastTurnAt, Date().timeIntervalSince(lastTurnAt) > Self.conversationWindow {
            recentTurns.removeAll()
        }
        recentTurns.append(AgentTurn(instruction: instruction, result: result))
        if recentTurns.count > 4 { recentTurns.removeFirst() }
        lastTurnAt = Date()
    }

    private func activeHistory() -> [AgentTurn] {
        guard let lastTurnAt, Date().timeIntervalSince(lastTurnAt) <= Self.conversationWindow else { return [] }
        return recentTurns
    }

    private func notice(_ text: String, symbol: String) {
        pill.model.phase = .notice(text: text, symbol: symbol)
        if !pill.isVisible { pill.show(anchor: nil) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.noticeDuration)
            guard let self, !self.isListening, case .notice = self.pill.model.phase else { return }
            self.finishPill()
        }
    }

    private func flash(_ text: String, isError: Bool) {
        pill.model.phase = .message(text: text, isError: isError)
        if !pill.isVisible { pill.show(anchor: nil) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.messageDuration)
            guard let self, !self.isListening, case .message = self.pill.model.phase else { return }
            self.finishPill()
        }
    }

    private static func message(for error: any Error) -> String {
        switch error as? SpeechError {
        case .microphoneDenied:
            return String(localized: "Allow microphone access in System Settings › Privacy & Security.")
        case .speechRecognitionDenied:
            return String(localized: "Allow speech recognition in System Settings › Privacy & Security.")
        case .recognizerUnavailable:
            return String(localized: "Speech recognition isn't available right now.")
        case .audioEngineFailed, .none:
            return error.localizedDescription
        }
    }

    /// Clipboard fallback text was not selected by the user, so voice treats it as no selection.
    static func voiceSelection(from context: SelectionContext) -> SelectionContext {
        guard context.isClipboardFallback else { return context }
        return SelectionContext(
            text: "",
            sourceApp: context.sourceApp,
            cursorPosition: context.cursorPosition,
            selectionBounds: nil,
            timestamp: context.timestamp,
            appPolicy: context.appPolicy,
            isClipboardFallback: false,
            isEditable: false
        )
    }

    private static func candidateActions(for context: ActionContext) -> [any Action] {
        let coordinator = ActionCoordinator.shared
        var seen = Set<String>()
        return (coordinator.resolveActions(for: context) + coordinator.searchCatalog(for: context)).filter { action in
            ActionIdentity.isBindable(action) && !(action is GatedExtensionAction) && seen.insert(action.id).inserted
        }
    }
}
