// ExtensionPackagePage.swift
// OpenClip
//
// One installed extension's settings page: a hero saying what it is and who made it, the actions
// it adds and the way into each one's settings — the same page whether the package groups five
// commands behind one icon or contributes a single command. Its command table is
// `ActionSettingsRow`, the same rows the Shortcuts page is made of. Whether it is on, and what can be done to it as a
// whole — view its README, show its folder, uninstall it — live in the toolbar beside the back and
// forward arrows, because they belong to the extension rather than to any row of the page.
//
// This is what Raycast does with an extension — select it in the sidebar and everything about it
// is on one page — and it is the reason an extension is a sidebar destination rather than a gear on
// a list row.

import SwiftUI
import AppKit
import Core

@MainActor
struct ExtensionPackagePage: View {
    let packageID: String
    /// Manifest, folder and README; `nil` until the read lands or for a standalone script extension.
    let details: ExtensionPackageDetails?
    @Binding var disabledActionIDs: Set<String>
    @Binding var disabledPackages: Set<String>

    @ObservedObject private var coordinator = ActionCoordinator.shared
    @ObservedObject private var customizationManager = ActionCustomizationManager.shared
    @ObservedObject private var updateManager = ExtensionUpdateManager.shared
    @ObservedObject private var router = SettingsRouter.shared

    @State private var isUpdating = false

    init(
        packageID: String,
        details: ExtensionPackageDetails?,
        disabledActionIDs: Binding<Set<String>>,
        disabledPackages: Binding<Set<String>>
    ) {
        self.packageID = packageID
        self.details = details
        _disabledActionIDs = disabledActionIDs
        _disabledPackages = disabledPackages
    }

    private var info: InstalledExtensionInfo? {
        InstalledExtensionInfo.info(for: packageID, in: coordinator.actions)
    }

    private var manifest: ExtensionMetadata? { details?.manifest }

    var body: some View {
        Group {
            if let info {
                page(for: info)
            } else {
                // The package went away while its page was open (uninstalled from the Store, or
                // its folder was deleted). Show the list rather than an empty pane.
                Color.clear.onAppear { router.select(.shortcuts) }
            }
        }
    }

    /// Sections in display order; empty ones are skipped because an empty `Section` still draws a blank card.
    private enum PageSection {
        case gate
        case update
        case actions
    }

    private func sections(for info: InstalledExtensionInfo) -> [PageSection] {
        var sections: [PageSection] = []
        if info.gatedReason != nil { sections.append(.gate) }
        if updateManager.updatablePackageIDs.contains(packageID) { sections.append(.update) }
        if !info.commands.isEmpty { sections.append(.actions) }
        return sections
    }

    private func page(for info: InstalledExtensionInfo) -> some View {
        let sections = sections(for: info)
        // The identifier footer rides the last section so it never gets a card of its own.
        let last = sections.last

        return Form {
            // A header, not a view above the form: headers scroll with content, where a pinned view stays under the toolbar.
            Section {
                EmptyView()
            } header: {
                SettingsHeroHeader(
                    glyph: .icon(info.icon, tint: SettingsTint.neutral),
                    title: info.name,
                    subtitle: manifest?.localizedDescription?.resolve() ?? manifest?.description,
                    footnote: byline
                )
            }

        if sections.contains(.gate), let reason = info.gatedReason,
               let text = extensionGateDescription(for: reason) {
                Section {
                    Label {
                        Text(text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    identifierFooter(if: last == .gate)
                }
            }

            if sections.contains(.update) {
                Section {
                    SettingsRow(
                        title: "Update Available",
                        subtitle: "A newer version is in the Store.",
                        systemImage: "arrow.down.circle"
                    ) {
                        if #available(macOS 26.0, *) {
                            Button {
                                update()
                            } label: {
                                HStack(spacing: 5) {
                                    if isUpdating {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    Text(isUpdating ? String(localized: "Updating…") : String(localized: "Update"))
                                        .font(.system(size: 11.5, weight: .medium))
                                }
                                .foregroundStyle(SettingsDesignTokens.glassButtonBlue)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                            }
                            .buttonStyle(.plain)
                            .settingsGlassCapsule(tint: SettingsDesignTokens.glassButtonBlue.opacity(0.16), interactive: true)
                            .contentShape(Capsule())
                            .disabled(isUpdating)
                        } else {
                            Button(isUpdating ? String(localized: "Updating…") : String(localized: "Update")) {
                                update()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isUpdating)
                        }
                    }
                } footer: {
                    identifierFooter(if: last == .update)
                }
            }

            if sections.contains(.actions) {
                Section {
                    ForEach(info.commands, id: \.id) { action in
                        ActionSettingsRow(
                            action: action,
                            disabledActionIDs: $disabledActionIDs,
                            disabledPackages: $disabledPackages
                        )
                    }
                } header: {
                    Text("Actions")
                } footer: {
                    VStack(alignment: .leading, spacing: 10) {

                        Text(info.commands.count == 1
                             ? String(localized: "Turn the action off to disable it. Open it to change its name, icon, shortcut and options.")
                             : String(localized: "Turn an action off to disable it. Open one to change its name, icon, shortcut and options."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        identifierFooter(if: last == .actions)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Selectable package identifier, shown for bug reports.
    @ViewBuilder
    private func identifierFooter(if shouldShow: Bool) -> some View {
        if shouldShow {
            Text(packageID)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var byline: String? {
        var parts: [String] = []
        if let version = manifest?.version, !version.isEmpty {
            parts.append(String(localized: "Version \(version)"))
        }
        if let author = manifest?.author, !author.isEmpty {
            parts.append(author)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Actions

    // MARK: - Work

    private func update() {
        isUpdating = true
        Task {
            do {
                try await updateManager.update(packageID: packageID)
            } catch {
                router.notifyError(
                    title: String(localized: "Update Failed"),
                    message: error.localizedDescription
                )
            }
            isUpdating = false
            NotificationCenter.default.post(name: .openClipExtensionsDidChange, object: nil)
        }
    }
}
