// CommandMatcher.swift
// OpenClip
//
// Deterministic first tier of intent routing: scores a spoken command against installed actions
// so an exact "translate" or "copy as markdown" runs without an LLM round trip.
import Foundation

public enum CommandMatcher {
    /// Default score an action must reach to run without asking the LLM.
    public static let confidenceThreshold = 0.85

    /// Words a spoken command carries that an action title/keyword never does.
    private static let fillerWords: Set<String> = [
        "please", "can", "could", "would", "will", "you", "just", "the", "a", "an",
        "this", "that", "these", "those", "it", "its", "me", "my", "for", "to", "of",
        "text", "selected", "selection", "is", "in", "on", "now", "hey", "ok", "okay",
        "um", "uh",
    ]

    /// Lowercased word tokens with punctuation and filler words removed.
    public static func normalize(_ text: String) -> [String] {
        var separated = ""
        for character in text.lowercased() {
            separated.append(character.isLetter || character.isNumber ? String(character) : " ")
        }
        let words = separated.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return words.filter { !fillerWords.contains($0) }.map(stem)
    }

    /// Folds simple plurals so "dash" names an action titled "Dashes".
    static func stem(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        for suffix in ["shes", "ches", "xes", "sses"] where word.hasSuffix(suffix) {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") { return String(word.dropLast()) }
        return word
    }

    /// Actions scoring above zero, best first; ties broken by `actionID` ascending.
    public static func rank(_ transcript: String, actions: [ActionDescriptor]) -> [CommandMatch] {
        let transcriptTokens = normalize(transcript)
        var matches: [CommandMatch] = []
        for action in actions {
            let best = bestScore(of: action, against: transcriptTokens)
            if best > 0 {
                matches.append(CommandMatch(actionID: action.id, score: best))
            }
        }
        return matches.sorted {
            $0.score == $1.score ? $0.actionID < $1.actionID : $0.score > $1.score
        }
    }

    /// The single action the transcript clearly names, or nil when the LLM should decide.
    public static func confidentMatch(
        _ transcript: String,
        actions: [ActionDescriptor],
        threshold: Double = confidenceThreshold
    ) -> String? {
        let ranked = rank(transcript, actions: actions)
        guard let top = ranked.first, top.score >= threshold else { return nil }
        if let runnerUp = ranked.dropFirst().first, runnerUp.score >= top.score - 0.1 {
            return nil
        }
        return top.actionID
    }

    /// The highest score any candidate phrase of `action` reaches against the transcript.
    private static func bestScore(of action: ActionDescriptor, against transcriptTokens: [String]) -> Double {
        var best = 0.0
        for candidate in ([action.title] + action.keywords).map(normalize) {
            let score = phraseScore(candidate, against: transcriptTokens)
            if score > best {
                best = score
            }
        }
        return best
    }

    /// Score one normalized phrase against the transcript's normalized tokens.
    private static func phraseScore(_ phrase: [String], against transcript: [String]) -> Double {
        guard !phrase.isEmpty, !transcript.isEmpty else { return 0 }
        if phrase == transcript {
            return 1
        }
        let transcriptSet = Set(transcript)
        if phrase.allSatisfy({ transcriptSet.contains($0) }) {
            return 0.6 + 0.4 * Double(phrase.count) / Double(transcript.count)
        }
        let overlap = Set(phrase).intersection(transcriptSet).count
        guard overlap > 0 else { return 0 }
        return 0.5 * Double(overlap) / Double(max(phrase.count, transcript.count))
    }
}
