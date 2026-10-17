// JevRouting.swift
// OpenClip
//
// Optional router: TypeSafe's Jev model answers one typed multiple-choice question about the spoken
// command. Confident answers skip the provider's routing call; anything else returns nil so the
// configured provider decides as usual.
import Foundation
import Core

enum JevRouting {
    static let apiKeyAccount = "typesafeAPIKey"
    static let minimumConfidence = 0.6
    private static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private static let actionPrefix = "action:"
    private static let fallbackChoices: Set<String> = ["script", "other"]

    static func requestBody(for request: AgentRequest, actions: [ActionDescriptor], budget: RoutingBudget, model: String = "jev-latest") -> [String: Any] {
        var criteria: [String: String] = [
            "rewrite": "Transform the selected text: shorten, fix, translate, reformat, rephrase.",
            "answer": "Explain or answer a question, or summarize; the result is shown in a card.",
            "other": "Ambiguous, or none of the other choices clearly fits."
        ]
        if budget.allowsScripts {
            criteria["script"] = "Exact mechanical work (counting, parsing, converting, math, dates) or controlling macOS apps."
        }
        for action in AgentPrompts.prioritized(actions, for: request.transcript).prefix(budget.maxActions) {
            criteria[actionPrefix + action.id] = AgentPrompts.line(for: action).dropFirst(2).description
        }
        var state = "Spoken command: \(request.transcript)"
        if request.hasSelection {
            state += "\nSelected text: " + AgentPrompts.clipped(request.selectedText, to: budget.selectionSample)
        } else {
            state += "\nNothing is selected."
        }
        return [
            "state": state,
            "model": model,
            "questions": ["route": [
                "type": "choice",
                "instructions": "What should a voice assistant do with this spoken command? Prefer an installed action when it does what was asked.",
                "criteria": criteria
            ] as [String: Any]]
        ]
    }

    static func decision(from data: Data, request: AgentRequest, knownIDs: Set<String>) -> AgentDecision? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let wrapped = root["result"] as? [String: Any] { root = wrapped }
        guard let answers = root["answers"] as? [String: Any],
              let route = answers["route"] as? [String: Any],
              let choice = route["choice"] as? String,
              (route["confidence"] as? Double ?? 0) >= minimumConfidence,
              !fallbackChoices.contains(choice) else { return nil }
        if choice.hasPrefix(actionPrefix) {
            let id = String(choice.dropFirst(actionPrefix.count))
            return knownIDs.contains(id) ? .runAction(actionID: id) : nil
        }
        switch choice {
        case "rewrite": return request.hasSelection ? .rewrite(instruction: request.transcript) : nil
        case "answer": return .answer(instruction: request.transcript)
        default: return nil
        }
    }

    /// Asks a System One-style decision endpoint. Returns nil on any failure so the active provider routes instead.
    static func decide(
        request: AgentRequest, actions: [ActionDescriptor], budget: RoutingBudget,
        endpoint: URL, apiKey: String?, model: String
    ) async -> AgentDecision? {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 6)
        urlRequest.httpMethod = "POST"
        if let apiKey, !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: requestBody(for: request, actions: actions, budget: budget, model: model)) else { return nil }
        urlRequest.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                Log.ai.error("Decision model failed with HTTP status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            return decision(from: data, request: request, knownIDs: Set(actions.map(\.id)))
        } catch is CancellationError {
            return nil
        } catch {
            Log.ai.error("Decision model failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func decide(request: AgentRequest, actions: [ActionDescriptor], budget: RoutingBudget) async -> AgentDecision? {
        guard let key = SecretStore.get(account: apiKeyAccount), !key.isEmpty else { return nil }
        return await decide(request: request, actions: actions, budget: budget, endpoint: endpoint, apiKey: key, model: "jev-latest")
    }
}
