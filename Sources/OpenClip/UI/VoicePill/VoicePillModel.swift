// VoicePillModel.swift
// OpenClip
//
// Observable state behind the push-to-talk pill. The orchestrator mutates `phase`; the view only
// renders it and reports chip taps through `onChipSelected`.
import SwiftUI

@MainActor
public final class VoicePillModel: ObservableObject {
    public enum Phase: Equatable {
        case hidden
        /// Key held: live transcript plus recent input levels (0...1), newest last.
        case listening(transcript: String, levels: [Float])
        /// Key released and work in progress, e.g. "Thinking…" or "Running Translate…".
        case working(label: String)
        case clarify(question: String, options: [String])
        /// Neutral, non-error hint (e.g. nothing was heard) shown briefly before the pill hides.
        case notice(text: String, symbol: String)
        /// Brief terminal message (error or "Done") before the pill hides.
        case message(text: String, isError: Bool)
    }

    public static let levelHistoryCount = 24

    /// Identity of what the pill shows, ignoring live input levels, so layout and animation react to
    /// a change of state or text but not to every audio sample.
    public static func animationKey(of phase: Phase) -> String {
        switch phase {
        case .hidden: return "hidden"
        case .listening: return "listening"
        case .working(let label): return "working:\(label)"
        case .notice(let text, let symbol): return "notice:\(symbol):\(text)"
        case .message(let text, let isError): return "message:\(isError):\(text)"
        case .clarify(let question, let options): return "clarify:\(question):\(options.joined(separator: "|"))"
        }
    }

    @Published public var phase: Phase = .hidden
    public var onChipSelected: ((String) -> Void)?
    public var onClose: (() -> Void)?

    public init() {}

    /// Appends a level sample, keeping `levelHistoryCount` samples.
    public func push(transcript: String, level: Float) {
        var levels: [Float]
        if case .listening(_, let existing) = phase { levels = existing } else { levels = [] }
        levels.append(min(max(level, 0), 1))
        if levels.count > Self.levelHistoryCount { levels.removeFirst(levels.count - Self.levelHistoryCount) }
        phase = .listening(transcript: transcript, levels: levels)
    }
}
