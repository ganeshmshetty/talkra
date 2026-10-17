// SandboxTextView.swift
// OpenClip
//
// NSViewRepresentable wrapping an NSTextView for the onboarding sandbox.
// Detects text selection and triggers live feedback callback.
import SwiftUI
import AppKit

@MainActor
struct SandboxTextView: NSViewRepresentable {
    let text: String
    var onSelection: (() -> Void)? = nil

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelection: (() -> Void)?

        init(onSelection: (() -> Void)?) {
            self.onSelection = onSelection
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            onSelection?()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onSelection = onSelection
    }
}
