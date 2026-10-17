// ActionSettingsRow.swift
// OpenClip
//
// One action as a settings-table row: enable switch, name, hotkey, chevron. Shared by every
// action list so their columns line up.

import SwiftUI
import Core
import KeyboardShortcuts

@MainActor
struct ActionSettingsRow: View {
    let action: any Action
    @Binding var disabledActionIDs: Set<String>
    @Binding var disabledPackages: Set<String>
    /// Second line under the name. Nil keeps rows one height.
    var subtitle: String?

    init(
        action: any Action,
        disabledActionIDs: Binding<Set<String>>,
        disabledPackages: Binding<Set<String>>,
        subtitle: String? = nil
    ) {
        self.action = action
        _disabledActionIDs = disabledActionIDs
        _disabledPackages = disabledPackages
        self.subtitle = subtitle
    }

    @ObservedObject private var customizationManager = ActionCustomizationManager.shared

    var body: some View {
        let presentation = customizationManager.presented(action, surface: .table)
        let isEnabled = ActionEnablement.binding(
            for: action,
            disabledActionIDs: $disabledActionIDs,
            disabledPackages: $disabledPackages
        )

        HStack(spacing: 10) {
            Toggle("", isOn: isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Enable \(presentation.title)"))

            Button {
                SettingsDestination.open(action)
            } label: {
                HStack(spacing: 10) {
                    ActionIconView(icon: presentation.icon, size: 14)
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(presentation.title)
                            .font(.system(size: 13))
                            .foregroundStyle(isEnabled.wrappedValue ? .primary : .secondary)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Configure Action")

            if ActionIdentity.isBindable(action) {
                Shortcut(for: .actionHotkey(action.id))
            }

            Button {
                SettingsDestination.open(action)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Configure \(presentation.title)"))
        }
        .padding(.vertical, 3)
    }
}
