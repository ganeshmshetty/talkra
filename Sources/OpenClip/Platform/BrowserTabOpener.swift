// BrowserTabOpener.swift
// OpenClip
//
// Opens a URL in the browser the selection came from via the browser's own scripting, so the tab
// lands in the front window. LaunchServices would open a new window when the only window is private.
// Every step is best-effort and falls back to LaunchServices.
import Foundation
import AppKit
import Core

@MainActor
public struct BrowserTabOpener {
    public init() {}
    /// Injected so tests can avoid `osascript`.
    var runAppleScript: @MainActor @Sendable (String, TimeInterval) async throws -> String = { source, timeout in
        try await AppleScriptRunner.shared.run(source, timeout: timeout)
    }
    /// Hands the URL to the app through LaunchServices. Returns whether LaunchServices accepted it.
    var openWithApplication: @MainActor @Sendable (URL, String) async -> Bool = { url, bundleID in
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }
    }
    /// Last resort: the system default handler.
    var openDefault: @MainActor @Sendable (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }

    /// Short on purpose so a busy browser never holds the action up.
    static let appleScriptTimeout: TimeInterval = 5

    public func open(_ url: URL, inApp bundleID: String) async {
        if BrowserDetector.isBrowser(bundleIdentifier: bundleID) {
            do {
                _ = try await runAppleScript(Self.appleScript(url: url, bundleID: bundleID), Self.appleScriptTimeout)
                return
            } catch {
                Log.resultHandler.error("browser tab via AppleScript failed for \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .private); falling back to LaunchServices")
            }
        }
        if !(await openWithApplication(url, bundleID)) {
            openDefault(url)
        }
    }

    /// Safari's dictionary spells the tab-focus step differently from Chromium.
    static func appleScript(url: URL, bundleID: String) -> String {
        let escaped = escape(url.absoluteString)
        if bundleID.hasPrefix("com.apple.Safari") || bundleID == "com.kagi.kagimacOS" {
            return """
            tell application id "\(bundleID)"
                activate
                tell front window to set current tab to (make new tab with properties {URL:"\(escaped)"})
            end tell
            """
        }
        return """
        tell application id "\(bundleID)"
            activate
            tell front window to make new tab with properties {URL:"\(escaped)"}
            set active tab index of front window to (count of tabs of front window)
        end tell
        """
    }

    /// Backslashes before quotes, matching `AppleScriptAction`.
    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
