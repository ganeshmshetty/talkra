// PopupMetrics.swift
// OpenClip
//
// UI-facing layout and timing constants for the floating result card, toasts, and panel.
// These are presentation concerns living in the App target to keep `Sources/Core/` free of UI vocabulary.
import CoreGraphics
import Foundation
import SwiftUI
import AppKit

public enum PopupMetrics {
    /// Brief grace for OCR popups: recognition can outlast the cursor leaving the release point.
    static let ocrArrivalDismissalGrace: TimeInterval = 1.0
    /// Standard width of an action button, used by PopupPositioner for center alignment.
    public static let actionButtonWidth: CGFloat = 39.0

    /// Resolved spring animation or immediate cut respecting macOS Reduce Motion accessibility setting.
    public static func springOrImmediate(response: Double = 0.28, dampingFraction: Double = 0.8) -> Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .linear(duration: 0.05)
        }
        return .spring(response: response, dampingFraction: dampingFraction)
    }

    public static let cardCornerRadius: CGFloat = 22.0
    /// Shared radius for footer controls in the result card.
    public static let footerButtonCornerRadius: CGFloat = 10.0
    public static let toastCornerRadius: CGFloat = 14.0
    /// Maximum character length displayed in floating toast bubbles before truncating with an ellipsis.
    public static let toastMaxCharacterLength: Int = 40
    public static let toastPreferredAboveDistance: CGFloat = 140.0
    public static let captureStatusGap: CGFloat = 6.0
    /// Transparent ring so the toast drop shadow is not clipped; excluded from hit-testing.
    public static let toastShadowInset: CGFloat = 8.0
    public static let popupPadding: CGFloat = 8.0
    /// Card drop-shadow geometry, mirrored by `PopupCardChromeModifier` (`PopupThemeModel.swift`). The panel's transparent ring must cover the blur tail or the frame clips it.
    public static let cardShadowContactRadius: CGFloat = 1.5
    public static let cardShadowContactYOffset: CGFloat = 1.0
    public static let cardShadowAmbientRadius: CGFloat = 12.0
    public static let cardShadowAmbientYOffset: CGFloat = 4.0
    /// Measured SwiftUI shadow tail: alpha stays visible to about `yOffset + factor * radius`.
    private static let cardShadowTailFactor: CGFloat = 2.0
    /// Transparent ring inside the panel frame so the drop shadow is not clipped.
    /// Excluded from hit-testing so clicks in the shadow fall through to the app underneath.
    /// Keep in sync with ResultSurfaceView's `.padding(popupShadowInset)`.
    public static let popupShadowInset: CGFloat = max(
        cardShadowAmbientRadius,
        cardShadowAmbientYOffset + cardShadowTailFactor * cardShadowAmbientRadius
    )
    /// Screen-bottom threshold below which the card renders above.
    public static let cardAboveThreshold: CGFloat = 280.0
    public static let searchPanelContentWidth: CGFloat = 320.0
    public static var searchPanelWidth: CGFloat { searchPanelContentWidth + 2 * popupShadowInset }
    /// Shared height cap for the popup panel; `PopupPanel.heightCap` lifts it while a resizable surface shows.
    public static let popupMaxHeight: CGFloat = 312
    /// Result card sizing: long responses scroll; resize may exceed the max up to the screen, but not the min.
    /// A user-resized size is persisted (`SettingKey.resultCardWidth`/`resultCardHeight`) and overrides the default.
    public static let aiCardMinWidth: CGFloat = 220
    public static let aiCardIdealWidth: CGFloat = 320
    public static let aiCardMinHeight: CGFloat = 200
    public static let aiCardMaxHeight: CGFloat = 280
    /// Info/error toast auto-dismiss delay; loading toasts have no timer.
    public static let toastDurationNanoseconds: UInt64 = 1_200_000_000
    /// Ignores queued app-activation notifications right after a session starts; later ones are real focus switches.
    public static let focusSwitchGracePeriod: TimeInterval = 0.3

    /// Maps the 1...5 scale level to a multiplier; 3 is the default.
    public static func scaleMultiplier(for level: Int) -> CGFloat {
        switch level {
        case 1: return 0.85
        case 2: return 0.925
        case 3: return 1.00
        case 4: return 1.10
        case 5: return 1.22
        default: return 1.00
        }
    }
}
