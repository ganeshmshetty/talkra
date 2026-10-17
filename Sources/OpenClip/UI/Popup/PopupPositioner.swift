// PopupPositioner.swift
// OpenClip
//
// Calculates popup window placement and screen edge clamping math based on selection bounds or cursor location.
import Foundation
import CoreGraphics
import Core
import AppKit

enum PopupDismissalGrace {
    static func isActive(now: TimeInterval, deadline: TimeInterval?) -> Bool {
        guard let deadline else { return false }
        return now < deadline
    }
}

public struct PopupPositioner: Sendable {

    private static let gap: CGFloat = 6

    /// Main entry point — positions relative to the mouse release point and drag direction.
    public static func calculateFrame(
        for context: SelectionContext,
        popupSize: CGSize,
        in screenBounds: CGRect
    ) -> CGRect {
        placeNearReleasePoint(
            releasePoint: context.cursorPosition,
            mouseDownPoint: context.mouseDownLocation,
            popupSize: popupSize,
            screenBounds: screenBounds
        )
    }

    /// Distance from the window frame's left edge to the center of the first action button
    /// (shadow inset + half the button width).
    public static let firstActionCenterOffset: CGFloat = PopupMetrics.popupShadowInset + (PopupMetrics.actionButtonWidth / 2)

    /// Horizontal origin anchoring a popup of the given width at the release X,
    /// clamped to the screen's padding-inset edges.
    public static func alignedX(
        releaseX: CGFloat,
        width: CGFloat,
        screenBounds: CGRect
    ) -> CGFloat {
        let padding: CGFloat = PopupMetrics.popupPadding

        let maxPopupWidth = max(0, screenBounds.width - 2 * padding)
        let popupWidth = max(0, min(width, maxPopupWidth))

        let unconstrainedX = releaseX - firstActionCenterOffset

        let minX = screenBounds.minX + padding
        let maxX = screenBounds.maxX - popupWidth - padding
        if maxX >= minX {
            return max(minX, min(unconstrainedX, maxX))
        } else {
            return minX
        }
    }

    /// Places the popup near the release point. Auto puts it below when the drag went top-to-bottom (so it does not
    /// cover the selection), otherwise above; each side flips at a screen edge.
    public static func placeNearReleasePoint(
        releasePoint: CGPoint,
        mouseDownPoint: CGPoint? = nil,
        popupSize: CGSize,
        screenBounds: CGRect
    ) -> CGRect {
        let padding: CGFloat = PopupMetrics.popupPadding

        let maxPopupWidth = max(0, screenBounds.width - 2 * padding)
        let popupWidth = max(0, min(popupSize.width, maxPopupWidth))

        let x = alignedX(releaseX: releasePoint.x, width: popupWidth, screenBounds: screenBounds)

        // macOS screen coords: Y increases upwards (0 is bottom of screen).
        // Top-to-Bottom drag -> releasePoint.y < mouseDownPoint.y.
        let shouldPlaceBelow: Bool = {
            guard let mouseDown = mouseDownPoint else { return false }
            return (releasePoint.y - mouseDown.y) < -10.0
        }()

        let yAbove = releasePoint.y + gap
        let yBelow = releasePoint.y - popupSize.height - gap

        var y: CGFloat
        if shouldPlaceBelow {
            if yBelow >= screenBounds.minY + padding {
                y = yBelow
            } else if yAbove + popupSize.height <= screenBounds.maxY - padding {
                y = yAbove
            } else {
                y = screenBounds.minY + padding
            }
        } else {
            if yAbove + popupSize.height <= screenBounds.maxY - padding {
                y = yAbove
            } else if yBelow >= screenBounds.minY + padding {
                y = yBelow
            } else {
                y = screenBounds.maxY - popupSize.height - padding
            }
        }

        return CGRect(x: x, y: y, width: popupWidth, height: popupSize.height)
    }

    /// Screen containing `point`, with a 2pt boundary tolerance so points on secondary-display edges still resolve.
    public static func screen(containing point: CGPoint, in screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        screens.first { $0.frame.insetBy(dx: -2, dy: -2).contains(point) } ?? screens.first
    }

    /// Selects the screen frame containing `point` with inclusive boundary tolerance.
    public static func screenFrame(containing point: CGPoint, screenFrames: [CGRect]) -> CGRect? {
        screenFrames.first { $0.insetBy(dx: -2, dy: -2).contains(point) } ?? screenFrames.first
    }
}
