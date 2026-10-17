// ActionVisibility.swift
// OpenClip
//
// Shared visibility evaluator for extension actions. Pure: no UserDefaults, AppKit, or Keychain.
import Foundation

public enum ActionVisibility {
    /// Order: input, paste target, app allow/deny, regex, then the expression gate (fail-closed on eval error).
    /// A malformed regex enables the action, so a bad manifest never hides one, and skips the expression gate.
    public static func isEnabled(
        requirements: ActionRequirements?,
        legacyRegex: String?,
        expression: ValidateExpression? = nil,
        context: ActionContext
    ) -> (enabled: Bool, match: ActionMatchInfo) {
        let text = context.selection.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceBundleID = context.selection.sourceApp.bundleIdentifier
        let noMatch = ActionMatchInfo(text: text, matchedText: text, captures: [], sourceBundleID: sourceBundleID)

        // Unknown capability evidence fails closed only when explicitly required.
        let inputRequirement = requirements?.input ?? .text
        let hasText = !trimmed.isEmpty
        let isLiveSelection = context.selection.source == .selection
        let inputSatisfied: Bool
        switch inputRequirement {
        case .optional:
            inputSatisfied = true
        case .text:
            inputSatisfied = hasText
        case .liveSelection:
            inputSatisfied = hasText && isLiveSelection
        case .editableSelection:
            inputSatisfied = hasText && isLiveSelection && context.selection.isEditable == true
        }
        if !inputSatisfied {
            return (false, noMatch)
        }
        if requirements?.requiresPasteTarget == true && context.pasteTargetAvailable != true {
            return (false, noMatch)
        }

        if let apps = requirements?.apps, !apps.isEmpty {
            switch requirements?.appsMode ?? .allow {
            case .allow:
                guard let sourceBundleID, apps.contains(sourceBundleID) else {
                    return (false, noMatch)
                }
            case .deny:
                if let sourceBundleID, apps.contains(sourceBundleID) {
                    return (false, noMatch)
                }
            }
        }

        // Regex is the fast first pass; a failed regex gate returns before the DSL expression evaluates.
        let pattern = requirements?.regex ?? legacyRegex
        var matched = noMatch
        var regexEnabled: Bool? = nil
        if let pattern, !pattern.isEmpty {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if let result = regex.firstMatch(in: trimmed, options: [], range: range) {
                    let matchedText = Range(result.range, in: trimmed).map { String(trimmed[$0]) } ?? trimmed
                    var captures: [String] = []
                    if regex.numberOfCaptureGroups > 0 {
                        for group in 1...regex.numberOfCaptureGroups {
                            let groupRange = result.range(at: group)
                            if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: trimmed) {
                                captures.append(String(trimmed[swiftRange]))
                            } else {
                                captures.append("")
                            }
                        }
                    }
                    matched = ActionMatchInfo(text: text, matchedText: matchedText, captures: captures, sourceBundleID: sourceBundleID)
                    regexEnabled = !(requirements?.regexNegated == true)
                } else {
                    regexEnabled = requirements?.regexNegated == true
                }
            } catch {
                // Malformed regex must not hide an action (legacy URL behavior).
                Log.coordinator.debug("Malformed enablement regex treated as non-matching: \(error.localizedDescription)")
                return (true, noMatch)
            }
        }
        if regexEnabled == false {
            return (false, matched)
        }

        if let expression {
            switch expression.evaluate(context, match: matched) {
            case .success(true):
                return (true, matched)
            case .success(false):
                return (false, matched)
            case .failure(let error):
                Log.js.error("Enablement expression evaluation failed: \(error)")
                return (false, matched)
            }
        }

        return (true, matched)
    }

    /// IDs of required options whose resolved value is empty. Kept out of `isEnabled` to avoid
    /// per-popup Keychain reads; checked at perform time.
    public static func missingRequiredOptions(
        requirements: ActionRequirements?,
        resolvedOptions: [String: String]
    ) -> [String] {
        guard let requiredOptions = requirements?.requiredOptions, !requiredOptions.isEmpty else { return [] }
        return requiredOptions.filter { optionID in
            let value = resolvedOptions[optionID] ?? ""
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Resolves option values through `optionStore`, then delegates to the pure overload.
    public static func missingRequiredOptions(
        requirements: ActionRequirements?,
        options: [ExtensionOption],
        optionStore: any ActionOptionReading,
        actionID: String
    ) -> [String] {
        let resolved = Dictionary(options.map { ($0.identifier, optionStore.stringValue(actionID: actionID, option: $0)) }, uniquingKeysWith: { _, latest in latest })
        return missingRequiredOptions(requirements: requirements, resolvedOptions: resolved)
    }
}
