// RichPasteboardPayload.swift
// OpenClip
//
// Pure Core value types representing multi-type clipboard content (plain text, RTF, HTML, and raw
// pasteboard flavors). Used by ActionResult.pasteContent and ActionResult.copyContent to support
// rich text formatting and app-private types.
import Foundation

/// A raw pasteboard representation (UTI + bytes) preserved so app-private types (e.g. Notes
/// checklists) survive a copy→paste round trip instead of being rebuilt from RTF/HTML.
public struct RichPasteboardFlavor: Sendable, Equatable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

public struct RichPasteboardPayload: Sendable, Equatable {
    public var plainText: String?
    public var rtf: String?
    public var html: String?
    /// Raw representations captured from the source pasteboard. When non-empty these are the source
    /// of truth and are written verbatim; `plainText`/`rtf`/`html` are the fallback.
    public var flavors: [RichPasteboardFlavor]

    public init(
        plainText: String? = nil,
        rtf: String? = nil,
        html: String? = nil,
        flavors: [RichPasteboardFlavor] = []
    ) {
        self.plainText = plainText
        self.rtf = rtf
        self.html = html
        self.flavors = flavors
    }
}
