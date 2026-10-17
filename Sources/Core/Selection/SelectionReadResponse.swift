import Foundation

/// Domain outcome vocabulary: no platform APIs or user content in reason codes.
public enum SelectionReadStatus: String, Sendable, Codable, Equatable {
    case selection, noSelection, targetChanged, timedOut, copyBlocked, cancelled
    case clipboardFallback, policyBlocked, busy, failed, tooLarge
}

public struct TextReadResponse: Sendable {
    public let result: TextResult?
    public let isEditable: Bool
    public let traceID: UInt64?
    public let status: SelectionReadStatus

    public init(result: TextResult? = nil, isEditable: Bool = false, status: SelectionReadStatus, traceID: UInt64? = nil) {
        self.result = result
        self.isEditable = isEditable
        self.traceID = traceID
        self.status = status
    }
}

/// Clipboard fallback is a successful trigger with the original read outcome retained.
public struct SelectionTriggerResponse: Sendable {
    public let context: SelectionContext?
    public let canPaste: Bool?
    public let traceID: UInt64?
    public let status: SelectionReadStatus
    public let retrievalStatus: SelectionReadStatus?

    public init(context: SelectionContext? = nil, canPaste: Bool? = nil,
                status: SelectionReadStatus, retrievalStatus: SelectionReadStatus? = nil, traceID: UInt64? = nil) {
        self.context = context
        self.canPaste = canPaste
        self.traceID = traceID
        self.status = status
        self.retrievalStatus = retrievalStatus
    }
}
