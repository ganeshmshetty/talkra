// TextRetrieving.swift
// OpenClip
//
// Defines the protocol for extracting text and bounds from active applications using accessibility APIs or pasteboard fallbacks.
import Foundation
import CoreGraphics

public struct TextResult: Sendable {
    public let text: String
    public let bounds: CGRect?
    public let html: String?
    public let rtf: String?
    /// Raw pasteboard representations captured alongside the text, including app-private types.
    public let flavors: [RichPasteboardFlavor]

    public init(
        text: String,
        bounds: CGRect? = nil,
        html: String? = nil,
        rtf: String? = nil,
        flavors: [RichPasteboardFlavor] = []
    ) {
        self.text = text
        self.bounds = bounds
        self.html = html
        self.rtf = rtf
        self.flavors = flavors
    }
}

public protocol TextRetrieving: Sendable {
    func retrieveText(for app: AppIdentity, policy: AppPolicyContext) async -> String?
    func retrieveTextResult(for app: AppIdentity, policy: AppPolicyContext) async -> TextResult?
}

public extension TextRetrieving {
    func retrieveText(for app: AppIdentity, policy: AppPolicyContext) async -> String? {
        await retrieveTextResult(for: app, policy: policy)?.text
    }
}
