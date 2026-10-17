// CodeBlockExtractor.swift
// OpenClip
//
// Pulls runnable source out of a code-synthesis reply, which may be a bare script or markdown
// with one or more fenced blocks.
import Foundation

public enum CodeBlockExtractor {
    /// Fence info strings accepted for each language, lowercased.
    public static func aliases(for language: ScriptLanguage) -> Set<String> {
        switch language {
        case .javascript:
            return ["javascript", "js"]
        case .shell:
            return ["shell", "sh", "bash", "zsh"]
        case .applescript:
            return ["applescript", "osascript"]
        }
    }

    /// The script body, or nil when the reply holds no code.
    public static func extract(from raw: String, expected language: ScriptLanguage) -> String? {
        struct Block {
            let info: String
            var lines: [String] = []
        }

        var blocks: [Block] = []
        var currentBlock: Block?

        raw.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var block = currentBlock {
                if trimmed.hasPrefix("```") {
                    blocks.append(block)
                    currentBlock = nil
                } else {
                    block.lines.append(line)
                    currentBlock = block
                }
            } else if trimmed.hasPrefix("```") {
                let after = trimmed.drop(while: { $0 == "`" })
                let info = after.trimmingCharacters(in: .whitespaces).lowercased()
                currentBlock = Block(info: info)
            }
        }

        if let currentBlock {
            blocks.append(currentBlock)
        }

        if blocks.isEmpty {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let languageAliases = aliases(for: language)
        let chosen = blocks.first(where: { languageAliases.contains($0.info) }) ?? blocks[0]
        let body = chosen.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}
