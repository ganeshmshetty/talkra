// PaletteAIPrompt.swift
// OpenClip
//
// Prompt wrappers and title formatting for AI actions and result cards.
import Foundation

enum PaletteAIPrompt {
    /// Longest title a saved tool gets before it is elided with an ellipsis.
    static let maxToolTitleLength = 40

    /// The query with whitespace trimmed and collapsed, so stray spaces never change the prompt.
    static func instruction(from query: String) -> String {
        query
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// Prompt instruction wrapped with format requirements for standalone questions/tasks.
    static func standaloneQuestionPrompt(for query: String) -> String {
        let task = instruction(from: query)
        return """
        \(task)

        Format requirements:
        1. Output a short 2-4 word title for this question/topic inside <title>...</title> tags.
        2. Output your answer or response inside <result>...</result> tags.
        """
    }

    /// Prompt instruction wrapped with format requirements to generate a 2-4 word task title.
    static func askAITaskPrompt(for query: String) -> String {
        let task = instruction(from: query)
        return """
        \(task)

        Format requirements:
        1. Output a short 2-4 word title for this task inside <title>...</title> tags.
        2. Output your transformed text inside <result>...</result> tags.
        """
    }

    /// Tool title: the capitalised instruction cut at a word boundary to `maxToolTitleLength`, with
    /// an ellipsis when trimmed. Empty for a blank prompt.
    static func toolTitle(for prompt: String) -> String {
        let collapsed = instruction(from: prompt)
        guard let first = collapsed.first else { return "" }
        let capitalised = String(first).uppercased() + collapsed.dropFirst()
        guard capitalised.count > maxToolTitleLength else { return capitalised }

        let budget = maxToolTitleLength - 1 // room for the ellipsis
        var cut = String(capitalised.prefix(budget))
        if let lastSpace = cut.lastIndex(of: " "),
           cut.distance(from: cut.startIndex, to: lastSpace) >= budget / 2 {
            cut = String(cut[..<lastSpace])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}
