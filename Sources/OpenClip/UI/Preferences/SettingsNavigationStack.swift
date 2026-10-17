// SettingsNavigationStack.swift
// OpenClip
//
// Hosts the router's path in the detail column: the sidebar page at the bottom, drilled-into pages
// stacked on top. Every level stays mounted (offset and faded) so in-progress edits survive a
// drill-in and return; only the top level takes clicks or accessibility.

import SwiftUI

@MainActor
struct SettingsNavigationStack<Content: View>: View {
    let path: [SettingsPage]
    @ViewBuilder let content: (SettingsPage) -> Content

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(path.enumerated()), id: \.element.id) { index, page in
                let isTop = index == path.count - 1
                content(page)
                    .scrollContentBackground(.hidden)
                    .transparentScrollBackground()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(x: isTop ? 0 : -40)
                    .opacity(isTop ? 1 : 0)
                    .allowsHitTesting(isTop)
                    .accessibilityHidden(!isTop)
                    .zIndex(Double(index))
                    .transition(
                        index == 0
                            ? .opacity
                            : .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            )
                    )
            }
        }
        .clipped()
    }
}

// MARK: - Page layout

/// Shared metrics for the settings window's content.
enum SettingsLayout {
    /// Content cap, so every pane reads at the same measure whatever the window width.
    static let contentMaxWidth: CGFloat = 560
    /// Wider than the other panes so Store rows have room.
    static let storeMaxWidth: CGFloat = 640
}

extension View {
    /// Centres content at `maxWidth` while the scroll view stays full width, keeping the scroll indicator at the edge.
    func settingsPaneWidth(_ maxWidth: CGFloat = SettingsLayout.contentMaxWidth) -> some View {
        modifier(SettingsPaneWidth(maxWidth: maxWidth))
    }
}

/// Insets only the scroll content, so cards keep a fixed measure while the indicator stays at the edge.
private struct SettingsPaneWidth: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .scrollContentBackground(.hidden)
                .contentMargins(
                    .horizontal,
                    max(0, (proxy.size.width - maxWidth) / 2),
                    for: .scrollContent
                )
        }
    }
}

/// Scrolling content above a pinned footer (Cancel / Save).
@MainActor
struct SettingsEditorPage<Content: View, Footer: View>: View {
    /// Matches the grouped `Form` panes so pages line up.
    var contentMaxWidth: CGFloat = SettingsLayout.contentMaxWidth
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                content()

                footer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

/// Inline save error, used in place of modal alerts.
struct SettingsInlineError: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// The small uppercase caption that titles a card, matching a grouped `Form`'s section header.
struct SettingsCardTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

/// A list row that drills into another page; the whole row is the hit target.
struct SettingsDisclosureRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content()
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
