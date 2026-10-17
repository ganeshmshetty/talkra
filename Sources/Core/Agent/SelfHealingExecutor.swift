// SelfHealingExecutor.swift
// OpenClip
//
// Runs a synthesized script and, when it fails, feeds the error back to the generator for a
// bounded number of corrected attempts before giving up.
import Foundation

public enum SelfHealingOutcome<Output: Sendable>: Sendable {
    case success(Output, script: SynthesizedScript, attempts: Int)
    case failure(message: String, script: SynthesizedScript, attempts: Int)
}

public enum SelfHealingExecutor {
    /// - Parameters:
    ///   - maxRepairs: corrected attempts allowed after the first run fails.
    ///   - execute: runs a script; a thrown error counts as a failed attempt.
    ///   - repair: given the failed script and its error message, returns a corrected script.
    public static func run<Output: Sendable>(
        _ script: SynthesizedScript,
        maxRepairs: Int = 1,
        isolation: isolated (any Actor)? = #isolation,
        execute: (SynthesizedScript) async throws -> Output,
        repair: (SynthesizedScript, String) async throws -> SynthesizedScript
    ) async -> SelfHealingOutcome<Output> {
        let maxRepairsLimit = max(0, maxRepairs)
        var current = script
        var attempts = 0
        var repairsUsed = 0

        while true {
            attempts += 1
            do {
                let output = try await execute(current)
                return .success(output, script: current, attempts: attempts)
            } catch {
                let msg = message(for: error)
                if repairsUsed >= maxRepairsLimit {
                    return .failure(message: msg, script: current, attempts: attempts)
                }
                do {
                    current = try await repair(current, msg)
                    repairsUsed += 1
                } catch {
                    return .failure(message: msg, script: current, attempts: attempts)
                }
            }
        }
    }

    /// Message shown to the generator and the user for a failed attempt.
    public static func message(for error: any Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
