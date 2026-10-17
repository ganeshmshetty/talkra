// VoicePillPanelController.swift
// OpenClip
//
// Owns the borderless, non-activating panel that floats the voice pill just above the selection
// (or the caret / pointer when there is none) without stealing focus from the frontmost app.
import AppKit
import Combine
import SwiftUI

@MainActor
public final class VoicePillPanelController {
    public let model: VoicePillModel

    private let panel: VoicePillPanel
    private let hostingView: VoicePillHostingView
    private var phaseCancellable: AnyCancellable?
    private var anchor: CGRect?

    /// Esc pressed while the pill has keyboard focus.
    public var onEscape: (() -> Void)? {
        get { panel.onEscape }
        set { panel.onEscape = newValue }
    }

    public init(model: VoicePillModel = VoicePillModel()) {
        self.model = model
        let panel = VoicePillPanel()
        let hostingView = VoicePillHostingView(rootView: VoicePillView(model: model))
        self.panel = panel
        self.hostingView = hostingView
        panel.contentView = hostingView
        // `$phase` fires on willSet; measure after SwiftUI has rendered the new phase.
        phaseCancellable = model.$phase
            .map(VoicePillModel.animationKey(of:))
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.phaseDidChange() }
    }

    public var isVisible: Bool { panel.isVisible }

    /// The pill's on-screen frame, shadow padding included; its centre is the pill's centre.
    public var frame: NSRect { panel.frame }

    /// Shows the panel above `anchor` (screen coordinates, AppKit bottom-left origin). A nil anchor
    /// places it above the mouse pointer.
    public func show(anchor: CGRect?) {
        let rect = anchor ?? CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1))
        self.anchor = rect
        panel.ignoresMouseEvents = !isInteractive
        // Even without a usable fit the panel orders front; the phase change that follows sizes it
        // from the stored anchor.
        if let size = measuredSize() {
            let origin = Self.origin(for: size, anchor: rect, visibleFrame: Self.visibleFrame(containing: rect))
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        if NSClassFromString("XCTestCase") == nil {
            panel.orderFrontRegardless()
            panel.announceActive()
        }
    }

    /// Takes keyboard focus for Esc. Only after the selection has been read and before the key is
    /// released: a key window changes the frontmost-app check that guards reading and pasting.
    public func takeKeyFocus() {
        guard panel.isVisible, NSClassFromString("XCTestCase") == nil else { return }
        panel.acceptsKey = true
        panel.makeKey()
    }

    /// Gives focus back so the source app is the only key target for paste-in-place.
    public func releaseKeyFocus() {
        guard panel.acceptsKey else { return }
        panel.acceptsKey = false
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel.orderOut(nil)
        model.phase = .hidden
    }

    /// Origin for a panel of `size` centred above `anchor`, clamped inside `visibleFrame`.
    static func origin(for size: CGSize, anchor: CGRect, visibleFrame: CGRect, gap: CGFloat = 8) -> CGPoint {
        let x = min(max(anchor.midX - size.width / 2, visibleFrame.minX),
                    max(visibleFrame.minX, visibleFrame.maxX - size.width))
        var y = anchor.maxY + gap
        if y + size.height > visibleFrame.maxY {
            y = anchor.minY - gap - size.height
        }
        y = min(max(y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
        return CGPoint(x: x, y: y)
    }

    private var isInteractive: Bool {
        if case .clarify = model.phase { return true }
        return false
    }

    private func phaseDidChange() {
        panel.ignoresMouseEvents = !isInteractive
        resizeKeepingBottomCentre()
    }

    /// The panel grows away from its bottom edge so the pill stays pinned over the anchor; the glass
    /// shape inside fills the panel, so animating the frame morphs the pill.
    private func resizeKeepingBottomCentre() {
        guard let size = measuredSize() else { return }
        let current = panel.frame
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 || !panel.isVisible else { return }
        let origin: CGPoint
        let animates = panel.isVisible && current.height > 0
        if animates {
            origin = CGPoint(x: current.midX - size.width / 2, y: current.minY)
        } else {
            let rect = resolvedAnchor()
            origin = Self.origin(for: size, anchor: rect, visibleFrame: Self.visibleFrame(containing: rect))
        }
        let target = NSRect(origin: origin, size: size)
        guard animates, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(target, display: panel.isVisible)
            panel.announceActive()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [panel] in
            // Glass samples its backdrop when told the window is active; tell it again at the new size.
            MainActor.assumeIsolated { panel.announceActive() }
        }
    }

    private func resolvedAnchor() -> CGRect {
        anchor ?? CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1))
    }

    private func measuredSize() -> CGSize? {
        hostingView.layoutSubtreeIfNeeded()
        let fit = hostingView.fittingSize
        guard fit.width.isFinite, fit.height.isFinite, fit.width > 0, fit.height > 0 else { return nil }
        return fit
    }

    private static func visibleFrame(containing anchor: CGRect) -> CGRect {
        let midpoint = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(midpoint) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
    }
}

/// First clicks must reach the clarify chips even though the panel never becomes key.
private final class VoicePillHostingView: NSHostingView<VoicePillView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class VoicePillPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        ignoresMouseEvents = true
    }

    var onEscape: (() -> Void)?

    var acceptsKey = false

    /// Tells SwiftUI the window became active, since it only re-reads the state on these notifications.
    func announceActive() {
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: self)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: self)
    }

    override var canBecomeKey: Bool { acceptsKey }

    /// Reported active so Liquid Glass renders in its lit style. The pill must not really take key
    /// focus while it works: a key window changes the frontmost-app check that guards reading and pasting.
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override var canBecomeMain: Bool { false }
}
