// ScriptOutputSniffers.swift
// OpenClip
//
// Heuristics for legacy extensions that declare no `output` contract in their manifest.
import Foundation

public enum ScriptOutputSniffers {
    public static func jsProducesText(code: String) -> Bool {
        // 1. Arrow function with expression body.
        let arrowExprPattern = #"(?:(?:var|let|const)\s+)?(?:action|main)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[a-zA-Z0-9_]+)\s*=>\s*([^{\s\n;][^;\n]*)"#
        if let match = code.range(of: arrowExprPattern, options: .regularExpression) {
            let matchedStr = String(code[match])
            // Non-text literals (void/undefined/null/boolean) are not text.
            if matchedStr.range(of: #"=>\s*(?:undefined|null|true|false)\b"#, options: .regularExpression) == nil {
                return true
            }
            return false
        }

        // 2. Action/main entry function with block body.
        let entryHeaderPattern = #"(?:(?:async\s+)?function\s+(?:action|main)\s*\([^)]*\)|(?:(?:var|let|const)\s+)?(?:action|main)\s*=\s*(?:async\s*)?(?:function\s*\([^)]*\)|\([^)]*\)\s*=>|[a-zA-Z0-9_]+\s*=>))\s*\{"#
        if let match = code.range(of: entryHeaderPattern, options: .regularExpression) {
            let openBraceIndex = code.index(before: match.upperBound)
            if let body = extractBracedBlock(from: code, openBrace: openBraceIndex) {
                return bodyHasReturnText(body)
            }
        }

        // Fallback: no action/main entry found, scan the whole script.
        return bodyHasReturnText(code)
    }

    private static func bodyHasReturnText(_ body: String) -> Bool {
        body.range(of: #"return\s+(?!(?:true|false|undefined|null)\b)[^;}\s]"#, options: .regularExpression) != nil
    }

    private static func extractBracedBlock(from text: String, openBrace: String.Index) -> String? {
        guard openBrace < text.endIndex, text[openBrace] == "{" else { return nil }
        var depth = 0
        var currentIndex = openBrace
        while currentIndex < text.endIndex {
            let char = text[currentIndex]
            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[openBrace...currentIndex])
                }
            }
            currentIndex = text.index(after: currentIndex)
        }
        return String(text[openBrace...])
    }

    public static func appleScriptProducesText(code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        // Explicit non-empty return counts regardless of side-effects.
        let hasExplicitReturn = trimmed.range(of: #"return\s+(?!\s*["']["']|missing value\b)\S+"#, options: .regularExpression) != nil
        if hasExplicitReturn {
            return true
        }

        if trimmed.contains("return \"\"") || trimmed.contains("return ''") || trimmed.contains("return missing value") {
            return false
        }

        if trimmed.hasPrefix("say ") { return false }
        if trimmed.contains("tell application \"System Events\"") && trimmed.contains("keystroke") {
            return false
        }
        if trimmed.contains("do shell script") && trimmed.contains("main.sh") {
            return false
        }
        return true
    }

    public static func shellProducesText(code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        // QuickLook previews print nothing unless stdout is produced.
        if let qlRange = trimmed.range(of: "qlmanage") {
            let after = String(trimmed[qlRange.upperBound...])
            if !hasStdoutProducer(after) && !hasStdoutProducer(trimmed) {
                return false
            }
        }

        // Backgrounded with stdout sent to /dev/null.
        if (trimmed.contains(">/dev/null") || trimmed.contains("> /dev/null")) && trimmed.contains("&") {
            if !hasStdoutProducer(trimmed) {
                return false
            }
        }

        // GUI runners (swift, largetype) print nothing to stdout.
        if let guiRange = trimmed.range(of: #"(?:swift\s+|main\.swift|largetype)"#, options: .regularExpression) {
            let after = String(trimmed[guiRange.upperBound...])
            if !hasStdoutProducer(after) && !hasStdoutProducer(trimmed) {
                return false
            }
        }

        if trimmed.contains("| open ") || trimmed.contains("| /usr/bin/open ") {
            return false
        }

        if trimmed.contains("open -a ") || trimmed.contains("open -f ") || trimmed.contains("open -g ") {
            if !hasStdoutProducer(trimmed) {
                return false
            }
        }

        // Toast-only JSON effects (e.g. Harper) print nothing.
        if trimmed.contains("{\"type\":\"toast\"") || trimmed.contains("{type:\"toast\"") {
            if !trimmed.contains("| implode") && !trimmed.contains("type:\"copy\"") {
                return false
            }
        }

        return true
    }

    private static func hasStdoutProducer(_ text: String) -> Bool {
        let patterns = [
            #"echo\s"#,
            #"printf\s"#,
            #"cat\s"#,
            #"cat$"#,
            #"\|\s*implode"#,
            #"type:\"copy\""#
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
