// PermissionManager.swift
// OpenClip
//
// Checks and prompts for required macOS Accessibility permissions necessary for text retrieval and event monitoring.
import AppKit
import ApplicationServices
import AVFoundation
import Speech
import Core

/// Polls `AXIsProcessTrusted` with an async loop on the main actor rather than a Timer.
@MainActor
public final class PermissionManager: ObservableObject {
    public static let shared = PermissionManager()

    @Published public private(set) var isAccessibilityGranted: Bool = false
    @Published public private(set) var microphoneStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published public private(set) var speechStatus: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()

    public var isMicrophoneGranted: Bool { microphoneStatus == .authorized }
    public var isSpeechGranted: Bool { speechStatus == .authorized }

    private var pollingTask: Task<Void, Never>?

    private init() {
        self.isAccessibilityGranted = Self.queryAX()
    }

    // MARK: - Public API

    public func startMonitoring() {
        guard pollingTask == nil else { return }
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.checkStatus()
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
            }
        }
    }

    public func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func checkStatus() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        let current = Self.queryAX()
        if isAccessibilityGranted != current {
            isAccessibilityGranted = current
            NotificationCenter.default.post(name: .openClipAccessibilityChanged, object: current)
        }
    }

    /// Asks for microphone access, or opens System Settings when it was already denied.
    public func requestMicrophone() {
        if microphoneStatus == .denied || microphoneStatus == .restricted {
            openPrivacyPane("Privacy_Microphone")
            return
        }
        Self.askMicrophone { Task { @MainActor in PermissionManager.shared.checkStatus() } }
    }

    /// Asks for speech-recognition access, or opens System Settings when it was already denied.
    public func requestSpeech() {
        if speechStatus == .denied || speechStatus == .restricted {
            openPrivacyPane("Privacy_SpeechRecognition")
            return
        }
        Self.askSpeech { Task { @MainActor in PermissionManager.shared.checkStatus() } }
    }

    // Built outside the main actor so the system's callback queue never runs main-actor-isolated code.
    nonisolated private static func askMicrophone(_ done: @escaping @Sendable () -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in done() }
    }

    nonisolated private static func askSpeech(_ done: @escaping @Sendable () -> Void) {
        SFSpeechRecognizer.requestAuthorization { _ in done() }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Prompts TCC to evaluate the running binary. TCC entries are reset only by `resetTCCAndRelaunch`.
    public func requestAccessibilityPermission() {
        startMonitoring()
        promptAndOpenAccessibilitySettings()
    }

    private func promptAndOpenAccessibilitySettings() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reset TCC permission database entry for OpenClip if macOS TCC is caching a stale signature.
    public func resetTCCAndRelaunch() {
        // Async: never `waitUntilExit` on the main actor. The app relaunches regardless.
        Task {
            do {
                _ = try await ShellProcessRunner.run(ShellProcessRunner.Invocation(
                    executableURL: URL(fileURLWithPath: "/usr/bin/tccutil"),
                    arguments: ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.talkra.Talkra"],
                    environment: [:]
                ))
            } catch {
                Log.permissions.error("Failed to run tccutil reset for Accessibility permission: \(error.localizedDescription)")
            }
            relaunchApp()
        }
    }

    /// Relaunch the app so macOS TCC registers the new permission for the running process.
    public func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Internal

    /// Direct TCC query — bypasses any in-process caching.
    private static func queryAX() -> Bool {
        AXIsProcessTrustedWithOptions(nil)
    }
}
