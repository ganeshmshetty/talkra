// SpeechTranscribing.swift
// OpenClip
//
// Push-to-talk speech capture contract. Implementations must not touch the microphone until
// `start()` and must release it on `stop()` / `cancel()`.
import Foundation

public struct SpeechUpdate: Sendable, Equatable {
    public let transcript: String
    /// Normalized input level 0...1 for the waveform.
    public let level: Float

    public init(transcript: String, level: Float) {
        self.transcript = transcript
        self.level = level
    }
}

public enum SpeechError: Error, Sendable, Equatable {
    case microphoneDenied
    case speechRecognitionDenied
    case recognizerUnavailable
    case audioEngineFailed(String)
}

@MainActor
public protocol SpeechTranscribing: AnyObject {
    /// Called on the main actor with each partial transcript and level sample.
    var onUpdate: ((SpeechUpdate) -> Void)? { get set }
    var isRunning: Bool { get }
    /// Requests permissions on first use, then starts capture.
    func start() async throws
    /// Stops capture and returns the final transcript (empty when nothing was heard).
    func stop() async -> String
    /// Stops capture and discards the transcript.
    func cancel()
}
