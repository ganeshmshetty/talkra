// AgentPrompts.swift
// OpenClip
//
// Task instructions the voice agent sends through the regular AI providers. Providers already wrap
// the selection in <text> and expect the answer in <result>, so these only describe the task.
import Foundation

/// How much context a provider can take for one routing call. Small on-device models get less so the
/// prompt fits their context window; the long tail stays reachable by name through `CommandMatcher`.
public struct RoutingBudget: Sendable, Equatable {
    public let maxActions: Int
    public let selectionSample: Int
    /// False for models too small to write reliable scripts; the router never offers them that route.
    public let allowsScripts: Bool

    public init(maxActions: Int, selectionSample: Int, allowsScripts: Bool = true) {
        self.maxActions = maxActions
        self.selectionSample = selectionSample
        self.allowsScripts = allowsScripts
    }

    public static let full = RoutingBudget(maxActions: 120, selectionSample: 2_000)
    public static let local = RoutingBudget(maxActions: 50, selectionSample: 1_200)
    /// Apple Intelligence's on-device model has a ~4K-token context shared by instructions and input.
    public static let onDevice = RoutingBudget(maxActions: 25, selectionSample: 600, allowsScripts: false)
}

public enum AgentPrompts {
    public static let maxListedActions = RoutingBudget.full.maxActions
    /// Selection characters shown to the router or generator. Scripts receive the full text at run time.
    public static let selectionSampleLimit = RoutingBudget.full.selectionSample

    /// Sent after a reply that was not a valid decision, before falling back to a plain answer.
    public static let strictJSONReminder = "Your previous reply was not a valid JSON decision. Reply with ONLY the JSON object, no prose, no code fences."

    /// Actions the transcript mentions first (best match first), then the rest in their original order,
    /// so a capped list keeps the likely candidates.
    public static func prioritized(_ actions: [ActionDescriptor], for transcript: String) -> [ActionDescriptor] {
        let ranked = CommandMatcher.rank(transcript, actions: actions).map(\.actionID)
        let rankedSet = Set(ranked)
        let byID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { byID[$0] } + actions.filter { !rankedSet.contains($0.id) }
    }

    /// `- id: Title (keywords: a, b)`; keywords help the model tell similar actions apart.
    public static func line(for action: ActionDescriptor) -> String {
        let keywords = action.keywords.prefix(3).filter { !$0.isEmpty }
        return keywords.isEmpty
            ? "- \(action.id): \(action.title)"
            : "- \(action.id): \(action.title) (keywords: \(keywords.joined(separator: ", ")))"
    }

    /// Plain-language instructions for providers that fill a typed routing schema instead of writing JSON.
    public static func guidedRouting(_ request: AgentRequest, actions: [ActionDescriptor], maxActions: Int) -> String {
        let actionLines = prioritized(actions, for: request.transcript).prefix(maxActions)
            .map { line(for: $0) }
            .joined(separator: "\n")
        let selectionNote = request.hasSelection
            ? "The user has text selected; it is given after the command."
            : "Nothing is selected."
        return """
        You route a spoken command for a macOS voice assistant. \(selectionNote)
        Choose `action` when an installed action below does what was asked, and copy its id exactly. Choose `rewrite` to transform the selected text (shorten, fix, translate, reformat). Choose `answer` to explain or answer a question. Choose `clarify` only when the command is truly ambiguous.

        Installed actions:
        \(actionLines.isEmpty ? "(none)" : actionLines)
        """
    }

    public static func routing(_ request: AgentRequest, actions: [ActionDescriptor], maxActions: Int = maxListedActions, allowsScripts: Bool = true) -> String {
        let actionLines = prioritized(actions, for: request.transcript).prefix(maxActions)
            .map { Self.line(for: $0) }
            .joined(separator: "\n")
        let selectionNote = request.hasSelection
            ? "The user's selected text is in the <text> block (possibly truncated)."
            : "Nothing is selected; treat the command as a standalone request."
        let synthesizeRoute = allowsScripts
            ? "- {\"route\":\"synthesize\",\"language\":\"javascript|shell|applescript\",\"code\":\"<script>\",\"delivery\":\"replace|card|silent\"} for exact, mechanical work an LLM might get wrong (parsing, counting, extracting, converting, encoding, dates, math, UUIDs) or for controlling macOS / apps.\n        "
            : ""
        let scriptRules = allowsScripts
            ? [
                "Script rules:",
                "- javascript (preferred for text work): define `async function action(text) { ... }` returning a string; `text` is the full selection. JavaScriptCore only: no DOM, no Node, no require. `openclip.openURL(url)` opens a link.",
                "- shell: zsh; the selection is in \"$OPENCLIP_TEXT\"; print the result to stdout.",
                "- applescript: the selection is in the property OPENCLIP_TEXT; return the result.",
                "- delivery: \"replace\" puts the output over the selection, \"card\" shows it to read, \"silent\" for side effects.",
                "",
                ""
            ].joined(separator: "\n        ")
            : ""
        let app = request.appBundleID.map { "Frontmost app: \($0)\n" } ?? ""
        return """
        You are the router of a voice assistant for macOS. Decide how to fulfil the spoken command and reply with ONE JSON object only.

        Spoken command: "\(request.transcript)"
        \(app)\(selectionNote)

        Routes:
        - {"route":"action","actionID":"<id>"} when an installed action below does exactly what was asked, needing no extra parameters.
        - {"route":"rewrite","instruction":"<task>"} to transform the selected text in place (rewrite, fix, translate, reformat, shorten). With no selection, this writes new text at the cursor.
        - {"route":"answer","instruction":"<task>"} to explain, summarize, answer a question or produce information to read.
        \(synthesizeRoute)- {"route":"clarify","question":"<short question>","options":["<2 to 4 short spoken-style commands>"]} only when the command is genuinely ambiguous.

        \(scriptRules)Installed actions:
        \(actionLines.isEmpty ? "(none)" : actionLines)

        Put the JSON object inside the result tags with no other text.
        """
    }

    /// Asks for a corrected script after `error`.
    public static func repair(_ script: SynthesizedScript, error: String, request: AgentRequest) -> String {
        """
        A \(script.language.rawValue) script written for the voice command "\(request.transcript)" failed.

        Script:
        \(script.code)

        Error:
        \(error)

        Return only the corrected \(script.language.rawValue) script, keeping the same input/output contract, inside the result tags. No explanation.
        """
    }

    /// Follow-up turns as context for an answer or rewrite.
    public static func instruction(_ instruction: String, history: [AgentTurn]) -> String {
        guard !history.isEmpty else { return instruction }
        let turns = history.suffix(4).map { "User: \($0.instruction)\nResult: \(clipped($0.result, to: 1_000))" }
        return "Earlier in this conversation:\n\(turns.joined(separator: "\n\n"))\n\nNow: \(instruction)"
    }

    public static func clipped(_ text: String, to limit: Int = selectionSampleLimit) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
