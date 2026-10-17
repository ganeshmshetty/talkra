// PopupThemeModel.swift
// OpenClip
//
// Pure resolution logic for popup theme storage and result card styling.
// The popup surface is always Liquid Glass; the only stored choice is the appearance
// ("system" | "light" | "dark"), under "popupThemeColor".
import SwiftUI

enum PopupThemeModel {
    /// Theme token every popup surface renders with.
    static let glass = "glass"

    /// Color scheme for the popup subtree so `.primary` and materials match the theme. Applied only
    /// inside the popup, so Preferences is unaffected.
    static func effectiveScheme(appearance: String, systemIsDark: Bool) -> ColorScheme {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return systemIsDark ? .dark : .light
        }
    }

    /// Resting foreground color. Glass follows `.primary` so it tracks the forced scheme.
    static func restForeground(for effectiveTheme: String) -> Color {
        switch effectiveTheme {
        case "light": return .black.opacity(0.85)
        case "dark": return .white.opacity(0.90)
        default: return .primary
        }
    }

    /// The secondary foreground color (hints, badges) for the given effective theme token.
    static func restSecondary(for effectiveTheme: String) -> Color {
        switch effectiveTheme {
        case "light": return .black.opacity(0.55)
        case "dark": return .white.opacity(0.60)
        default: return .secondary
        }
    }

    /// Opaque fallback surface for Reduce Transparency.
    @ViewBuilder
    public static func solidSurfaceBackground(for colorScheme: ColorScheme, in shape: RoundedRectangle) -> some View {
        shape.fill(
            Color(
                red: colorScheme == .dark ? 0.15 : 0.94,
                green: colorScheme == .dark ? 0.15 : 0.94,
                blue: colorScheme == .dark ? 0.165 : 0.96
            )
        )
    }
}

extension View {
    @ViewBuilder
    func paletteSafeAreaBar<Content: View>(
        edge: VerticalEdge,
        spacing: CGFloat? = 0,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(macOS 26.0, *), !ProcessInfo.processInfo.arguments.contains("-XCTest") && NSClassFromString("XCTestCase") == nil {
            safeAreaBar(edge: edge, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: edge, spacing: spacing) {
                content()
                    .background(.ultraThinMaterial)
            }
        }
    }
}

// MARK: - Effective Theme Environment Key

/// Empty ("not set") by default, so views hosted outside `ResultSurfaceView` fall back to the
/// shared `.primary`/`.secondary` tokens. `ResultSurfaceView` always sets it.
struct PopupEffectiveThemeKey: EnvironmentKey {
    static let defaultValue = ""
}

public extension EnvironmentValues {
    var popupEffectiveTheme: String {
        get { self[PopupEffectiveThemeKey.self] }
        set { self[PopupEffectiveThemeKey.self] = newValue }
    }
}

// MARK: - Shared Card Chrome

/// Shared footer control surface. Liquid Glass on macOS 26+; a tinted fill otherwise.
struct PopupFooterButtonChrome: ViewModifier {
    let effectiveTheme: String
    let colorScheme: ColorScheme
    let isHovered: Bool
    var tint: Color? = nil

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PopupMetrics.footerButtonCornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        Group {
            if effectiveTheme == "glass",
               #available(macOS 26.0, *),
               !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                if let tint {
                    content
                        .background(shape.fill(tint.opacity(colorScheme == .light ? 1.0 : (isHovered ? 0.38 : 0.28))))
                        .background(.ultraThinMaterial, in: shape)
                        .glassEffect(.regular.tint(tint.opacity(colorScheme == .light ? 1.0 : 0.42)).interactive(), in: shape)
                        .overlay(shape.stroke(Color.white.opacity(0.24), lineWidth: 0.5))
                } else {
                    content
                        .background(shape.fill(Color.primary.opacity(isHovered ? 0.14 : 0.08)))
                        .background(.ultraThinMaterial, in: shape)
                        .glassEffect(.regular.interactive(), in: shape)
                        .overlay(
                            shape.stroke(
                                colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.10),
                                lineWidth: 0.5
                            )
                        )
                }
            } else {
                content
                    .background(
                        shape.fill(
                        tint?.opacity(isHovered ? 0.85 : 1.0)
                            ?? Color.primary.opacity(isHovered
                                ? (colorScheme == .dark ? 0.18 : 0.12)
                                : (colorScheme == .dark ? 0.12 : 0.07))
                        )
                    )
                    .overlay(
                        shape.stroke(
                            tint == nil
                                ? (colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                                : Color.white.opacity(0.20),
                            lineWidth: 0.5
                        )
                    )
            }
        }
    }
}

extension View {
    func popupFooterButtonChrome(
        effectiveTheme: String,
        colorScheme: ColorScheme,
        isHovered: Bool,
        tint: Color? = nil
    ) -> some View {
        modifier(
            PopupFooterButtonChrome(
                effectiveTheme: effectiveTheme,
                colorScheme: colorScheme,
                isHovered: isHovered,
                tint: tint
            )
        )
    }

    func popupHeaderButtonChrome(
        effectiveTheme: String,
        colorScheme: ColorScheme,
        isHovered: Bool,
        tint: Color? = nil
    ) -> some View {
        modifier(
            PopupHeaderButtonChrome(
                effectiveTheme: effectiveTheme,
                colorScheme: colorScheme,
                isHovered: isHovered,
                tint: tint
            )
        )
    }
}

/// Compact circular chrome for the result card's header controls.
private struct PopupHeaderButtonChrome: ViewModifier {
    let effectiveTheme: String
    let colorScheme: ColorScheme
    let isHovered: Bool
    var tint: Color? = nil

    private let shape = Circle()

    func body(content: Content) -> some View {
        Group {
            if effectiveTheme == "glass",
               #available(macOS 26.0, *),
               !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                if let tint {
                    content
                        .background(shape.fill(tint.opacity(isHovered ? 0.38 : 0.28)))
                        .background(.ultraThinMaterial, in: shape)
                        .glassEffect(.regular.tint(tint.opacity(0.42)).interactive(), in: shape)
                        .overlay(shape.stroke(Color.white.opacity(0.24), lineWidth: 0.5))
                } else {
                    content
                        .background(shape.fill(Color.primary.opacity(isHovered ? 0.14 : 0.08)))
                        .background(.ultraThinMaterial, in: shape)
                        .glassEffect(.regular.interactive(), in: shape)
                        .overlay(
                            shape.stroke(
                                colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.10),
                                lineWidth: 0.5
                            )
                        )
                }
            } else {
                content
                    .background(
                        shape.fill(
                            tint?.opacity(isHovered ? 0.85 : 1.0)
                                ?? Color.primary.opacity(isHovered
                                    ? (colorScheme == .dark ? 0.18 : 0.12)
                                    : (colorScheme == .dark ? 0.12 : 0.07))
                        )
                    )
                    .overlay(
                        shape.stroke(
                            tint == nil
                                ? (colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                                : Color.white.opacity(0.20),
                            lineWidth: 0.5
                        )
                    )
            }
        }
    }
}

public struct PopupCardChromeModifier: ViewModifier {
    public let cornerRadius: CGFloat
    public let effectiveTheme: String
    public let colorScheme: ColorScheme

    public init(
        cornerRadius: CGFloat = PopupMetrics.cardCornerRadius,
        effectiveTheme: String,
        colorScheme: ColorScheme
    ) {
        self.cornerRadius = cornerRadius
        self.effectiveTheme = effectiveTheme
        self.colorScheme = colorScheme
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if effectiveTheme == "glass" && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            shadowed(
                content
                    .background(LayeredGlassBackground(cornerRadius: cornerRadius, colorScheme: colorScheme))
                    .clipShape(shape)
                    .overlay(outerBorder(shape))
                    .overlay(rimHighlight(shape))
            )
        } else {
            content
                .clipShape(shape)
                .background {
                    // Rasterize only the surface and shadow. AppKit may promote live buttons to backing
                    // layers after presentation, and their clipping must not change the shadow buffer.
                    shadowed(PopupThemeModel.solidSurfaceBackground(for: colorScheme, in: shape))
                        .padding(PopupMetrics.popupShadowInset)
                        .drawingGroup()
                        .padding(-PopupMetrics.popupShadowInset)
                        .allowsHitTesting(false)
                }
                .overlay(outerBorder(shape))
                .overlay(rimHighlight(shape))
        }
    }

    private func shadowed<Surface: View>(_ surface: Surface) -> some View {
        surface
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.38 : 0.14),
                radius: PopupMetrics.cardShadowContactRadius,
                x: 0,
                y: PopupMetrics.cardShadowContactYOffset
            )
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.32 : 0.16),
                radius: PopupMetrics.cardShadowAmbientRadius,
                x: 0,
                y: PopupMetrics.cardShadowAmbientYOffset
            )
    }

    /// Outer hairline; glass keeps its lit gradient, the opaque fallback brightens at the top.
    @ViewBuilder
    private func outerBorder(_ shape: RoundedRectangle) -> some View {
        if effectiveTheme == "glass" {
            LayeredGlassBorder(cornerRadius: cornerRadius, colorScheme: colorScheme)
        } else {
            shape.stroke(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color.white.opacity(0.20), Color.white.opacity(0.08)]
                        : [Color.black.opacity(0.16), Color.black.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1.0
            )
        }
    }

    /// 1px top highlight fading out by the bottom; inset so it never touches the hairline.
    private func rimHighlight(_ shape: RoundedRectangle) -> some View {
        shape.inset(by: 0.5).stroke(
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.32 : 0.65),
                    Color.white.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: 1.0
        )
        .allowsHitTesting(false)
    }
}

public extension View {
    func popupCardChrome(
        cornerRadius: CGFloat = PopupMetrics.cardCornerRadius,
        effectiveTheme: String,
        colorScheme: ColorScheme
    ) -> some View {
        modifier(PopupCardChromeModifier(cornerRadius: cornerRadius, effectiveTheme: effectiveTheme, colorScheme: colorScheme))
    }
}
