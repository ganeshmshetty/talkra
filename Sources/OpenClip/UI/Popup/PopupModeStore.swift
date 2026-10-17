// PopupModeStore.swift
// OpenClip
//
// Shared observable popup mode state: the screen mode and the result card payload. Toasts bypass
// this store. The static preview uses a throwaway store so it never affects the live popup.
import Foundation
import Combine
import Core

@MainActor
public final class PopupModeStore: ObservableObject {
    /// Current screen mode for the popup.
    @Published public var mode: PopupMode = .actions
    /// True when the popup sits low on screen and search results render above the field.
    @Published public var searchResultsAbove: Bool = false
    /// Result card shown while `mode == .content`; any text outcome renders here.
    @Published public var resultCard: ResultCardPayload? = nil
    /// Max result-card size: the remembered user size, updated live during resize. `nil` means default.
    @Published public var resultCardSize: CGSize? = nil
    /// True once the user drags a resize handle; the card then keeps that size for its session.
    @Published public var isSurfaceUserSized: Bool = false
    /// Whether the target app can Paste (probed via AX). `false` hides Paste and Cut; `nil` and `true` keep them.
    @Published public var canPaste: Bool? = nil
    /// True while an async AI action runs; suspends distance auto-dismiss.
    @Published public var isProcessingAI: Bool = false
    /// True once the user pins the result card; suppresses auto-dismiss. Cleared by `hide()` and `exitContent()`.
    @Published public var isCardPinned: Bool = false

    public init() {}
}

/// Payload for the native result card. `original` is the input text, kept for the character diff;
/// nil when there is nothing to compare.
public struct ResultCardPayload: Sendable, Equatable {
    public let text: String
    public let isError: Bool
    public let title: String
    public let icon: ActionIcon?
    public let isStreaming: Bool
    public let original: String?
    /// Follow-up in flight with no chunk yet: `text` is the previous answer, shown dimmed.
    public let isRefining: Bool
    /// True for AI results that support follow-up refinement.
    public let canFollowUp: Bool
    public let file: FileOutputPayload?

    /// Builds the card content, including an optional native file.
    public init(text: String, isError: Bool, title: String = String(localized: "AI Tools"), icon: ActionIcon? = nil, isStreaming: Bool = false, original: String? = nil, isRefining: Bool = false, canFollowUp: Bool = true, file: FileOutputPayload? = nil) {
        self.text = text
        self.isError = isError
        self.title = title
        self.icon = icon
        self.isStreaming = isStreaming
        self.original = original
        self.isRefining = isRefining
        self.canFollowUp = canFollowUp
        self.file = file
    }
}
