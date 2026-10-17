// PopupResizeHandles.swift
// OpenClip
//
// Resize handles for the popup's resizable surfaces: edge strips plus a corner grip. These are
// SwiftUI gestures because the borderless panel has no AppKit resize edges and `NSHostingView`
// swallows `mouseDown`. The owner (`PopupWindowController.handleResize`) computes the size.
import SwiftUI
import AppKit

/// The top-left corner stays fixed, so only the right edge, bottom edge, and corner resize.
public enum PopupResizeEdge: Sendable, Equatable {
    case right
    case bottom
    case bottomRight

    public var resizesWidth: Bool { self != .bottom }
    public var resizesHeight: Bool { self != .right }
}

struct PopupResizeHandles: View {
    let tint: Color
    let accessibilityLabel: String
    /// `.began` is reported exactly once per drag.
    let onResize: @MainActor (PopupResizeEdge, ResultCardDragPhase) -> Void

    @State private var hoveredEdge: PopupResizeEdge?
    @State private var activeEdge: PopupResizeEdge?

    private static let edgeThickness: CGFloat = 5.0
    private static let gripHitSize: CGFloat = 16.0
    private static let gripGlyphSize: CGFloat = 9.0
    private static let gripInset: CGFloat = 5.0

    /// Thin strips leave the body's scrollbar grabbable; the grip is drawn last so it wins on overlap.
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            strip(.right)
                .frame(width: Self.edgeThickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            strip(.bottom)
                .frame(height: Self.edgeThickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            grip
        }
    }

    private func strip(_ edge: PopupResizeEdge) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { setHover(edge, $0) }
            .gesture(gesture(edge))
    }

    private var grip: some View {
        gripGlyph
            .padding([.bottom, .trailing], Self.gripInset)
            .frame(width: Self.gripHitSize, height: Self.gripHitSize, alignment: .bottomTrailing)
            .contentShape(Rectangle())
            .onHover { setHover(.bottomRight, $0) }
            .gesture(gesture(.bottomRight))
            .help(String(localized: "Drag to resize"))
            .accessibilityLabel(accessibilityLabel)
    }

    private var gripGlyph: some View {
        let size = Self.gripGlyphSize
        let isEmphasized = hoveredEdge == .bottomRight || activeEdge == .bottomRight
        return Path { path in
            for offset in stride(from: size / 3, through: size, by: size / 3) {
                path.move(to: CGPoint(x: size, y: size - offset))
                path.addLine(to: CGPoint(x: size - offset, y: size))
            }
        }
        .stroke(tint.opacity(isEmphasized ? 0.75 : 0.35), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        .frame(width: size, height: size)
    }

    /// `.began` fires once, on the first update, so a plain click is not a resize.
    private func gesture(_ edge: PopupResizeEdge) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in
                if activeEdge == nil {
                    activeEdge = edge
                    updateCursor()
                    onResize(edge, .began)
                }
                onResize(edge, .changed)
            }
            .onEnded { _ in
                guard activeEdge == edge else { return }
                activeEdge = nil
                onResize(edge, .ended)
                updateCursor()
            }
    }

    private func setHover(_ edge: PopupResizeEdge, _ hovering: Bool) {
        if hovering {
            hoveredEdge = edge
        } else if hoveredEdge == edge {
            hoveredEdge = nil
        }
        updateCursor()
    }

    /// Set manually: `PopupPanel.ContentView` forces the arrow on entry, and cursor rects miss fast drags.
    private func updateCursor() {
        if let edge = activeEdge ?? hoveredEdge {
            Self.cursor(for: edge).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private static func cursor(for edge: PopupResizeEdge) -> NSCursor {
        switch edge {
        case .right:
            return .resizeLeftRight
        case .bottom:
            return .resizeUpDown
        case .bottomRight:
            if #available(macOS 15, *) {
                return .frameResize(position: .bottomRight, directions: .all)
            }
            // No public diagonal resize cursor before macOS 15; the grip glyph carries the hint.
            return .arrow
        }
    }
}
