// SynthesizedScriptRunner.swift
// OpenClip
//
// Runs agent-generated code through the same runtimes extensions use (OpenClipJSHost, the shared
// ShellProcessRunner, osascript), and turns runtime error results into thrown errors so the
// self-healing loop sees them.
import Foundation
import Core

@MainActor
enum SynthesizedScriptRunner {
    static let actionID = "voice.synthesized"

    static func run(_ script: SynthesizedScript, context: ActionContext) async throws -> ActionResult {
        let title = String(localized: "Voice Script")
        let action: any Action
        switch script.language {
        case .javascript:
            action = JavaScriptAction(id: actionID, title: title, scriptCode: script.code, isAsync: true)
        case .applescript:
            action = AppleScriptAction(id: actionID, title: title, appleScriptCode: script.code)
        case .shell:
            action = CustomAction(id: actionID, title: title, iconName: "terminal", type: .shellScript(script: script.code, replaceSelection: false))
        }
        let result = try await action.perform(context)
        if let message = errorMessage(in: result) {
            throw AgentError.scriptFailed(message)
        }
        return result
    }

    static func errorMessage(in result: ActionResult) -> String? {
        switch result {
        case .failure(let error):
            return SelfHealingExecutor.message(for: error)
        case .toast(let feedback) where feedback.style == .error:
            return feedback.message
        case .sequence(let results):
            return results.lazy.compactMap(errorMessage(in:)).first
        default:
            return nil
        }
    }
}
