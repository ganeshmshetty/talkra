// PopupResizeGeometry.swift
// OpenClip
//
// Pure geometry for resizing a popup surface (the result card) by its right/bottom handles: the
// surface's top-left corner stays fixed, the dragged edge follows the absolute cursor position,
// and the result is clamped to the surface's minimum size and to the screen the panel sits on.
// Free of AppKit state so the rules are unit-testable without a panel.
import CoreGraphics

public enum PopupResizeGeometry {
    /// Size after the cursor moved from `anchorMouse` to `mouse` (screen coords, y up); only the handle's dimensions change.
    public static func size(from anchorSize: CGSize, edge: PopupResizeEdge,
                            anchorMouse: CGPoint, mouse: CGPoint) -> CGSize {
        var size = anchorSize
        if edge.resizesWidth {
            size.width = anchorSize.width + (mouse.x - anchorMouse.x)
        }
        if edge.resizesHeight {
            // Screen y grows upward: pulling the bottom edge down makes the surface taller.
            size.height = anchorSize.height + (anchorMouse.y - mouse.y)
        }
        return size
    }

    /// Clamps to `minSize` and keeps the panel (with shadow ring) inside `screenBounds` while growing from `panelTopLeft`. The minimum wins near an edge.
    public static func clamp(_ proposed: CGSize, minSize: CGSize, panelTopLeft: CGPoint, screenBounds: CGRect) -> CGSize {
        let ring = 2 * PopupMetrics.popupShadowInset
        let padding = PopupMetrics.popupPadding
        let maxWidth = screenBounds.maxX - padding - panelTopLeft.x - ring
        let maxHeight = panelTopLeft.y - (screenBounds.minY + padding) - ring
        return CGSize(
            width: bounded(proposed.width, min: minSize.width, max: maxWidth),
            height: bounded(proposed.height, min: minSize.height, max: maxHeight)
        )
    }

    /// Fits a remembered size to what `screenBounds` can show, independent of placement, so a size from a large display still opens on a small one.
    public static func fit(_ remembered: CGSize, minSize: CGSize, in screenBounds: CGRect) -> CGSize {
        let ring = 2 * PopupMetrics.popupShadowInset
        let padding = 2 * PopupMetrics.popupPadding
        return CGSize(
            width: bounded(remembered.width, min: minSize.width, max: screenBounds.width - padding - ring),
            height: bounded(remembered.height, min: minSize.height, max: screenBounds.height - padding - ring)
        )
    }

    /// `value` limited to `min...max`, with the minimum taking precedence when `max` is smaller.
    private static func bounded(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), max(maximum, minimum))
    }
}
