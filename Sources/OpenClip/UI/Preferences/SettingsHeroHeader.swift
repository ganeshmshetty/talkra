// SettingsHeroHeader.swift
// OpenClip
//
// Identity block at the top of a page about an extension, AI Tools or a custom action: a centred
// tile, name and subtitle, on the window background rather than in a card.

import SwiftUI
import Core

@MainActor
struct SettingsHeroHeader: View {
    /// A system symbol for OpenClip's pages, or an extension's action icon.
    enum Glyph {
        case symbol(String, tint: Color)
        case icon(ActionIcon, tint: Color)
    }

    let glyph: Glyph
    let title: String
    var subtitle: String?
    /// The quiet third line: "Version 1.0.0 · OpenClip Team".
    var footnote: String?
    var tileSize: CGFloat = 50

    var body: some View {
        VStack(spacing: 10) {
            tile

            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let footnote, !footnote.isEmpty {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var tile: some View {
        switch glyph {
        case .symbol(let name, let tint):
            SettingsIconTile(systemImage: name, tint: tint, size: tileSize)
                .shadow(color: tint.opacity(0.24), radius: 6, y: 2)
        case .icon(let icon, let tint):
            ExtensionIconTile(icon: icon, tint: tint, size: tileSize)
                .shadow(color: tint.opacity(0.24), radius: 6, y: 2)
        }
    }
}

extension SettingsHeroHeader {
    /// Copy, Cut and Paste use text glyphs, which a tile cannot show, so they use their symbol.
    @MainActor
    static func glyph(for action: any Action, presented: ActionPresentationModel) -> ActionIcon {
        if case .text = presented.icon,
           let symbol = (action as? any ConfigurableAction)?.preferenceIconName,
           !symbol.isEmpty {
            return .symbol(symbol)
        }
        return presented.icon
    }
}
