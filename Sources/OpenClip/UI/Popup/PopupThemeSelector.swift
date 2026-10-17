// PopupThemeSelector.swift
// OpenClip
//
// Lets the user pick the result card and toast appearance as grouped settings sections
// (matching the General tab's look): Appearance, and Size.
//
// Styled with modern SettingsCard, icon tiles, and hairline dividers.

import SwiftUI
import AppKit
import Core

@MainActor
struct PopupThemeSelector: View {
    @Setting(SettingKey.popupThemeColor) private var themeColor
    @Setting(SettingKey.popupScale) private var popupScale

    private struct AppearanceOption: Identifiable {
        let label: String
        let value: String
        var icon: String? = nil
        var id: String { value }
    }

    private var appearanceOptions: [AppearanceOption] {
        [
            AppearanceOption(label: "System", value: "system", icon: "circle.lefthalf.filled"),
            AppearanceOption(label: "Light", value: "light", icon: "sun.max.fill"),
            AppearanceOption(label: "Dark", value: "dark", icon: "moon.fill")
        ]
    }

    private var isAllDefault: Bool {
        themeColor == SettingKey.popupThemeColor.defaultValue &&
        popupScale == SettingKey.popupScale.defaultValue
    }

    private func resetToDefaults() {
        themeColor = SettingKey.popupThemeColor.defaultValue
        popupScale = SettingKey.popupScale.defaultValue
    }

    private func scaleLabel(for level: Int) -> String {
        switch level {
        case 1: return "85%"
        case 2: return "92%"
        case 3: return "100%"
        case 4: return "110%"
        case 5: return "122%"
        default: return "100%"
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            SettingsCard("Appearance") {
                appearanceControlRow(
                    title: "Color Mode",
                    info: "Follow the system appearance, or pin the card to light or dark regardless of the Mac."
                ) {
                    iconPicker(selection: $themeColor, options: appearanceOptions, label: "Color Mode", width: 200)
                }
            }

            SettingsCard("Size") {
                SettingsRow(
                    title: "Card Scale"
                ) {
                    stepSlider(
                        value: Binding(
                            get: { popupScale },
                            set: { popupScale = $0 }
                        ),
                        accessibilityLabel: "Card Scale",
                        labelText: scaleLabel(for: popupScale)
                    )
                }
            }

            HStack {
                Spacer()
                Button {
                    resetToDefaults()
                } label: {
                    Text(String(localized: "Reset"))
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .settingsGlassCapsule()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isAllDefault ? SettingsDesignTokens.tertiaryText : SettingsDesignTokens.secondaryText)
                .disabled(isAllDefault)
            }
            .padding(.top, 2)
        }
    }

    private func segmentedPicker(
        selection: Binding<String>,
        options: [AppearanceOption],
        label: LocalizedStringKey,
        width: CGFloat = 170
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options) { option in
                Text(LocalizedStringKey(option.label)).tag(option.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: width, height: 24, alignment: .trailing)
        .accessibilityLabel(label)
    }

    private func iconPicker(
        selection: Binding<String>,
        options: [AppearanceOption],
        label: LocalizedStringKey,
        width: CGFloat = 170
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options) { option in
                if let icon = option.icon {
                    Image(systemName: icon)
                        .help(LocalizedStringKey(option.label))
                        .accessibilityLabel(LocalizedStringKey(option.label))
                        .tag(option.value)
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: width, height: 24, alignment: .trailing)
        .accessibilityLabel(label)
    }

    /// A settings row for the appearance controls: the shared label style (icon tile + title) with
    /// an info button beside it, and the segmented control on the trailing edge. Mirrors
    /// `SettingsRow`'s spacing and padding so the section keeps the app's row rhythm.
    private func appearanceControlRow<Control: View>(
        title: LocalizedStringKey,
        info: LocalizedStringKey,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            SettingsRowLabel(title: title)
            SettingsInfoButton(title: title, info: info)
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, SettingsDesignTokens.sectionCardPaddingH)
        .padding(.vertical, SettingsDesignTokens.sectionCardPaddingV)
        .frame(minHeight: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepSlider(
        value: Binding<Int>,
        range: ClosedRange<Int> = 1...5,
        accessibilityLabel: LocalizedStringKey,
        labelText: String
    ) -> some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { newValue in
                        let clamped = max(range.lowerBound, min(range.upperBound, Int(round(newValue))))
                        if clamped != value.wrappedValue {
                            value.wrappedValue = clamped
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        }
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(labelText)
            .frame(width: 104)

            Text(labelText)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(SettingsDesignTokens.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 58, alignment: .trailing)
        }
        .frame(width: 170, height: 24, alignment: .trailing)
    }
}

/// A small info glyph that reveals an explanation in a popover, and shows the title as a native
/// hover tooltip. Owns its own presentation state so a row does not have to.
@MainActor
private struct SettingsInfoButton: View {
    let title: LocalizedStringKey
    let info: LocalizedStringKey

    @State private var isShowingInfo = false

    var body: some View {
        Image(systemName: "info.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(Color.secondary.opacity(0.7))
            .contentShape(Circle())
            .onTapGesture { isShowingInfo.toggle() }
            .help(title)
            .accessibilityLabel(title)
            .popover(isPresented: $isShowingInfo, arrowEdge: .bottom) {
                Text(info)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240, alignment: .leading)
                    .padding(14)
            }
    }
}
