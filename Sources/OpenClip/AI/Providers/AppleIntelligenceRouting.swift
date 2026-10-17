// AppleIntelligenceRouting.swift
// OpenClip
//
// Routes a spoken command with the on-device model through a typed schema. The small model does not
// reliably write the JSON decision the other providers produce, but it fills a schema dependably.
import Foundation
import Core

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable
enum AppleRoute: String {
    case action
    case rewrite
    case answer
    case clarify
}

@available(macOS 26.0, *)
@Generable
struct AppleRoutingResponse {
    @Guide(description: "action: run the listed installed action that does what was asked. rewrite: transform the selected text. answer: explain or answer a question. clarify: only if truly ambiguous.")
    var route: AppleRoute

    @Guide(description: "For action only: the exact id of the installed action, copied from the list. Otherwise empty.")
    var actionID: String?

    @Guide(description: "For rewrite or answer: the task to carry out, restated in one sentence.")
    var instruction: String?

    @Guide(description: "For clarify only: one short question.")
    var question: String?

    @Guide(description: "For clarify only: two to four short spoken-style commands the user could say instead.")
    var options: [String]?
}
#endif

enum AppleIntelligenceRouting {
    @MainActor
    static func decide(request: AgentRequest, actions: [ActionDescriptor], budget: RoutingBudget) async throws -> AgentDecision {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard AppleIntelligenceAvailability.isAvailable else {
                throw AIError.providerUnavailable(AppleIntelligenceAvailability.unavailableExplanation)
            }
            let instructions = AgentPrompts.guidedRouting(request, actions: actions, maxActions: budget.maxActions)
            var content = "Spoken command: \(request.transcript)"
            if request.hasSelection {
                content += "\n\nSelected text:\n" + AgentPrompts.clipped(request.selectedText, to: budget.selectionSample)
            }
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: content, generating: AppleRoutingResponse.self)
            return map(response.content, request: request, knownIDs: Set(actions.map(\.id)))
        }
        #endif
        throw AIError.providerUnavailable(String(localized: "Apple Intelligence isn't available on this Mac."))
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func map(_ response: AppleRoutingResponse, request: AgentRequest, knownIDs: Set<String>) -> AgentDecision {
        func text(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        switch response.route {
        case .action:
            if let id = text(response.actionID), knownIDs.contains(id) { return .runAction(actionID: id) }
            return .answer(instruction: request.transcript)
        case .rewrite:
            return .rewrite(instruction: text(response.instruction) ?? request.transcript)
        case .answer:
            return .answer(instruction: text(response.instruction) ?? request.transcript)
        case .clarify:
            let options = (response.options ?? []).compactMap { text($0) }
            if let question = text(response.question), (2...4).contains(options.count) {
                return .clarify(question: question, options: options)
            }
            return .answer(instruction: request.transcript)
        }
    }
    #endif
}
