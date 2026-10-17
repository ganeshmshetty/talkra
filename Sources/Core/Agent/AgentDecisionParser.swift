// AgentDecisionParser.swift
// OpenClip
//
// Turns the LLM's structured routing reply into an `AgentDecision`, tolerating the prose and code
// fences models wrap around JSON, and rejecting decisions that name actions that do not exist.
import Foundation

public enum AgentDecisionParser {
    /// Parses the first JSON object in `raw`.
    /// - Throws: `AgentError.malformedDecision` when no valid decision can be built.
    public static func parse(_ raw: String, knownActionIDs: Set<String>) throws -> AgentDecision {
        guard let json = firstJSONObject(in: raw) else {
            throw AgentError.malformedDecision("no JSON object")
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        } catch {
            throw AgentError.malformedDecision("invalid JSON decision")
        }

        switch trimmed(payload.route) {
        case "action":
            guard let actionID = trimmed(payload.actionID),
                  !actionID.isEmpty,
                  knownActionIDs.contains(actionID) else {
                throw AgentError.malformedDecision("unknown or missing action id")
            }
            return .runAction(actionID: actionID)

        case "synthesize":
            guard let language = trimmed(payload.language).flatMap(ScriptLanguage.init(rawValue:)),
                  let code = trimmed(payload.code),
                  !code.isEmpty else {
                throw AgentError.malformedDecision("synthesize needs a known language and non-empty code")
            }
            let delivery = trimmed(payload.delivery).flatMap(AgentDelivery.init(rawValue:)) ?? .card
            return .synthesize(SynthesizedScript(language: language, code: code), delivery: delivery)

        case "rewrite":
            guard let instruction = trimmed(payload.instruction), !instruction.isEmpty else {
                throw AgentError.malformedDecision("rewrite needs an instruction")
            }
            return .rewrite(instruction: instruction)

        case "answer":
            guard let instruction = trimmed(payload.instruction), !instruction.isEmpty else {
                throw AgentError.malformedDecision("answer needs an instruction")
            }
            return .answer(instruction: instruction)

        case "clarify":
            let options = Array(
                (payload.options ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(4)
            )
            guard options.count >= 2 else {
                throw AgentError.malformedDecision("clarify needs at least two options")
            }
            return .clarify(question: trimmed(payload.question) ?? "", options: options)

        default:
            throw AgentError.malformedDecision("missing or unknown route")
        }
    }

    /// The first balanced `{...}` object in `raw`, ignoring braces inside JSON strings.
    public static func firstJSONObject(in raw: String) -> String? {
        let characters = Array(raw)
        guard let start = characters.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        var index = start
        while index < characters.count {
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(characters[start...index])
                    }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    private struct Payload: Decodable {
        let route: String?
        let actionID: String?
        let language: String?
        let code: String?
        let delivery: String?
        let instruction: String?
        let question: String?
        let options: [String]?
    }

    private static func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
