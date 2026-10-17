// OnDeviceSpeechTranscriber.swift
// OpenClip
//
// Push-to-talk transcription with SFSpeechRecognizer forced on-device and an AVAudioEngine input
// tap. The microphone is opened only inside `start()` and released by `stop()` / `cancel()`.
import AVFoundation
import Speech
import Core

@MainActor
public final class OnDeviceSpeechTranscriber: SpeechTranscribing {
    public var onUpdate: ((SpeechUpdate) -> Void)?
    public private(set) var isRunning = false

    private let recognizer: SFSpeechRecognizer?

    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestTranscript = ""
    private var latestLevel: Float = 0
    private var tapInstalled = false
    private var isStarting = false
    private var isStopping = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stopTimeoutTask: Task<Void, Never>?

    public init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    public func start() async throws {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        Log.permissions.notice("Push-to-talk start: speech=\(SFSpeechRecognizer.authorizationStatus().rawValue, privacy: .public) microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue, privacy: .public)")
        guard await requestSpeechAuthorization() else { throw SpeechError.speechRecognitionDenied }
        guard await requestMicrophoneAccess() else { throw SpeechError.microphoneDenied }
        guard let recognizer, recognizer.isAvailable else { throw SpeechError.recognizerUnavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechError.audioEngineFailed("No audio input device available")
        }

        let box = SpeechRequestBox(request)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(box: box) { [weak self] level in
            Task { @MainActor in self?.handleLevel(level) }
        })
        tapInstalled = true

        let task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] transcript, isFinal, failed in
            Task { @MainActor in
                self?.handleRecognition(transcript: transcript, isFinal: isFinal, failed: failed)
            }
        })

        engine.prepare()
        do {
            try engine.start()
        } catch {
            task.cancel()
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            engine.stop()
            throw SpeechError.audioEngineFailed(error.localizedDescription)
        }

        self.audioEngine = engine
        self.request = request
        self.recognitionTask = task
        latestTranscript = ""
        latestLevel = 0
        isRunning = true
    }

    public func stop() async -> String {
        guard isRunning, !isStopping else { return trimmedLatestTranscript }
        isStopping = true
        defer { isStopping = false }

        removeTap()
        audioEngine?.stop()
        request?.endAudio()

        await withCheckedContinuation { continuation in
            stopContinuation = continuation
            stopTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.finishStopWait()
            }
        }

        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        recognitionTask?.cancel()
        audioEngine = nil
        request = nil
        recognitionTask = nil
        isRunning = false
        return trimmedLatestTranscript
    }

    public func cancel() {
        removeTap()
        audioEngine?.stop()
        recognitionTask?.cancel()
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        audioEngine = nil
        request = nil
        recognitionTask = nil
        latestTranscript = ""
        latestLevel = 0
        isRunning = false
        finishStopWait()
    }

    private var trimmedLatestTranscript: String {
        latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private func removeTap() {
        guard tapInstalled else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func finishStopWait() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    private func handleLevel(_ level: Float) {
        latestLevel = level
        guard isRunning else { return }
        onUpdate?(SpeechUpdate(transcript: latestTranscript, level: level))
    }

    private func handleRecognition(transcript: String?, isFinal: Bool, failed: Bool) {
        if let transcript {
            latestTranscript = transcript
            if isRunning {
                onUpdate?(SpeechUpdate(transcript: transcript, level: latestLevel))
            }
        }
        if isFinal || failed {
            finishStopWait()
        }
    }

    // Built outside the main actor: closures formed inside it would inherit main-actor isolation and
    // trap when CoreAudio and Speech call them on their own threads.
    private nonisolated static func tapBlock(
        box: SpeechRequestBox,
        onLevel: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            box.request.append(buffer)
            if let level = normalizedLevel(from: buffer) { onLevel(level) }
        }
    }

    private nonisolated static func resultHandler(
        _ deliver: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            deliver(result?.bestTranscription.formattedString, result?.isFinal == true, error != nil)
        }
    }

    private nonisolated static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let frameCount = Int(buffer.frameLength)
        let samples = channels[0]
        var sumOfSquares: Float = 0
        for index in 0..<frameCount {
            let sample = samples[index]
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(frameCount)).squareRoot()
        guard rms > 0 else { return nil }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 50) / 50))
    }
}

/// The tap block outlives the main actor and appends buffers from the audio thread, so the
/// request crosses isolation here rather than through the transcription state itself.
private final class SpeechRequestBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest

    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }
}
