// WindowConfigurator.swift
// OpenClip
//
// Reaches the NSWindow hosting a SwiftUI view, for properties SwiftUI cannot set (e.g. a hard
// minimum size). A view can sit in more than one window, so the settings live with the view.
import AppKit
import SwiftUI

private final class ConfiguratorHostingView: NSView {
    var configure: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        runConfigure()
    }

    func runConfigure() {
        guard let window = self.window else { return }
        configure?(window)
        DispatchQueue.main.async { [weak window, weak self] in
            guard let window else { return }
            self?.configure?(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak window, weak self] in
            guard let window else { return }
            self?.configure?(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window, weak self] in
            guard let window else { return }
            self?.configure?(window)
        }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguratorHostingView(frame: .zero)
        view.configure = configure
        view.runConfigure()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let configView = nsView as? ConfiguratorHostingView {
            configView.configure = configure
            configView.runConfigure()
        }
    }
}

extension View {
    func minimumWindowContentSize(width: CGFloat, height: CGFloat) -> some View {
        background(
            WindowConfigurator { window in
                let content = NSSize(width: width, height: height)
                // Re-asserted on every update: SwiftUI rewrites these on layout changes, not always both.
                window.contentMinSize = content
                window.minSize = window.frameRect(
                    forContentRect: NSRect(origin: .zero, size: content)
                ).size
                // AppKit does not resize a window already below the new floor; grow it now.
                let frame = window.frame
                if frame.width < window.minSize.width || frame.height < window.minSize.height {
                    window.setContentSize(
                        NSSize(
                            width: max(window.contentLayoutRect.width, width),
                            height: max(window.contentLayoutRect.height, height)
                        )
                    )
                }
            }
        )
    }
}

extension View {
    /// Set on both window and split items, re-set on each update: macOS overrides per column and SwiftUI rewrites item styles.
    func hidesTitlebarSeparator() -> some View {
        background(
            WindowConfigurator { window in
                window.titlebarSeparatorStyle = .none
                for controller in WindowConfigurator.splitViewControllers(in: window) {
                    for item in controller.splitViewItems where item.titlebarSeparatorStyle != .none {
                        item.titlebarSeparatorStyle = .none
                    }
                }
            }
        )
    }

    /// Clears opaque backgrounds on scroll views so the behind-window liquid glass blurs through.
    func transparentScrollBackground() -> some View {
        background(
            WindowConfigurator { window in
                WindowConfigurator.clearScrollViews(in: window.contentView)
            }
        )
    }
}

extension WindowConfigurator {
    /// Split view controllers in `window`, including delegate-linked ones (SwiftUI `NavigationSplitView`).
    static func splitViewControllers(in window: NSWindow) -> [NSSplitViewController] {
        var found = splitViewControllers(in: window.contentViewController)
        if let contentView = window.contentView {
            found.append(contentsOf: splitViewControllers(in: contentView))
        }
        var seen = Set<ObjectIdentifier>()
        return found.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// Split view controllers under `root`, at any depth.
    static func splitViewControllers(in root: NSViewController?) -> [NSSplitViewController] {
        guard let root else { return [] }
        var found: [NSSplitViewController] = []
        if let controller = root as? NSSplitViewController {
            found.append(controller)
        }
        for child in root.children {
            found.append(contentsOf: splitViewControllers(in: child))
        }
        return found
    }

    static func splitViewControllers(in view: NSView?) -> [NSSplitViewController] {
        guard let view else { return [] }
        var found: [NSSplitViewController] = []
        if let splitView = view as? NSSplitView, let controller = splitView.delegate as? NSSplitViewController {
            found.append(controller)
        }
        for child in view.subviews {
            found.append(contentsOf: splitViewControllers(in: child))
        }
        return found
    }

    static func clearScrollViews(in view: NSView?, depth: Int = 0) {
        guard let view else { return }
        if let sv = view as? NSScrollView {
            sv.drawsBackground = false
            sv.backgroundColor = .clear
        }
        if let cv = view as? NSClipView {
            cv.drawsBackground = false
            cv.backgroundColor = .clear
        }
        if let tv = view as? NSTableView {
            tv.backgroundColor = .clear
            tv.headerView?.layer?.backgroundColor = .clear
        }
        for child in view.subviews {
            clearScrollViews(in: child, depth: depth + 1)
        }
    }
}

