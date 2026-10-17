// AIPage.swift
// OpenClip
//
// The AI settings page: which engine answers, and the library of prompts that appear in the AI
// Tools group — with each prompt a page of its own. Whether AI Tools is on at all is the switch in
// the toolbar, beside the back and forward arrows, the same as an installed extension's.
//
// AI settings used to hang off the gear on the "AI Tools" row of the Actions list, which opened a
// fixed 440x480 popover with its own segmented sub-tabs and a sheet on top of those for editing a
// prompt. It is a whole provider's worth of configuration, not a per-action setting, so it gets the
// same treatment as an installed extension: a row in the sidebar and a page.

import SwiftUI
import Core
import KeyboardShortcuts

@MainActor
struct AIPage: View {
    @ObservedObject private var aiManager = AIServiceManager.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    let size: CGFloat = 42
                    let radius = SettingsDesignTokens.iconTileRadius(for: size)
                    let squircle = RoundedRectangle(cornerRadius: radius, style: .continuous)

                    ZStack {
                        squircle
                            .fill(
                                LinearGradient(
                                    colors: [SettingsTint.ai.opacity(0.96), SettingsTint.ai],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: Color.black.opacity(0.12), radius: 2, y: 1)

                        Image(systemName: SettingsPage.ai.systemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: size, height: size)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "AI Tools"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(SettingsDesignTokens.primaryText)
                            .lineLimit(1)

                        Text(String(localized: "Rewrite, summarize, translate or ask about the selected text."))
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsDesignTokens.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Toggle("", isOn: $aiManager.isAIEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                }
                .padding(.vertical, 4)
            }

            AIConfigureForm(embedded: true)

            AIActionsSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Creation fields stay local until Add Action, including the unregistered shortcut.
@MainActor
struct AIPresetDraft {
    var title = ""
    var prompt = ""
    var iconSymbol = Constants.defaultAIIconSymbol
    var displayMode = 1 // Text is the default, even after choosing an icon.
    var shortcut: KeyboardShortcuts.Shortcut?

    func canCreate() -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func createPreset(
        customizations: ActionCustomizationManager,
        saveShortcut: (KeyboardShortcuts.Shortcut, KeyboardShortcuts.Name) -> Void,
        savePreset: (AIActionPreset) -> Void
    ) -> AIActionPreset? {
        guard canCreate() else { return nil }
        let preset = AIServiceManager.makeCustomPreset(title: title, prompt: prompt)
        let action = AIAction(presetID: preset.id, title: preset.title)
        let symbol = iconSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        customizations.setOverride(
            for: action.id, title: nil,
            symbol: symbol.isEmpty ? Constants.defaultAIIconSymbol : symbol,
            text: displayMode == 1 ? preset.title : nil
        )
        if let shortcut {
            saveShortcut(shortcut, .actionHotkey(action.id))
        }
        // Register only after appearance and triggers are ready for the new action's ID.
        savePreset(preset)
        return preset
    }
}

/// Creating an AI action with the same appearance and trigger controls as its editor.
@MainActor
struct AINewPresetPage: View {
    @ObservedObject private var router = SettingsRouter.shared
    @ObservedObject private var aiManager = AIServiceManager.shared
    @State private var draft = AIPresetDraft()

    var body: some View {
        SettingsEditorPage {
            VStack(alignment: .leading, spacing: 18) {
                SettingsCard("Appearance") {
                    ActionAppearanceFields(
                        title: $draft.title,
                        displayTextFallback: String(localized: "Custom Action"),
                        iconSymbol: $draft.iconSymbol,
                        initialIconSymbol: Constants.defaultAIIconSymbol,
                        baseIcon: nil,
                        displayMode: $draft.displayMode
                    )
                }

                SettingsCard("Triggers") {
                    SettingsRow(
                        title: "Keyboard Shortcut",
                        subtitle: "Global hotkey to run this action directly.",
                        systemImage: "keyboard",
                        plainIcon: true,
                        descriptionOnHover: true
                    ) {
                        Shortcut(shortcut: $draft.shortcut)
                    }
                }

                SettingsCard("Prompt Instruction") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("e.g. Rewrite text using simple 5th-grade vocabulary", text: $draft.prompt, axis: .vertical)
                            .lineLimit(4...12)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(String(localized: "Prompt Instruction"))
                        Text("The selected text is appended to the instruction when the action runs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, SettingsDesignTokens.sectionCardPaddingH)
                    .padding(.vertical, SettingsDesignTokens.sectionCardPaddingV)
                }
            }
        } footer: {
            HStack(spacing: 12) {
                Spacer()

                Button("Cancel") { router.pop() }
                    .keyboardShortcut(.cancelAction)

                Button("Add Action") {
                    guard let preset = draft.createPreset(
                        customizations: .shared,
                        saveShortcut: { KeyboardShortcuts.setShortcut($0, for: $1) },
                        savePreset: aiManager.updatePreset
                    ) else { return }
                    router.show(path: [.ai, .aiPreset(id: preset.id)])
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canCreate())
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
