// AppIdentifying.swift
// OpenClip
//
// Represents external application identity (bundle identifier, process name, executable path).

import Foundation

public struct AppIdentity: Sendable, Equatable, Hashable {
    public let bundleIdentifier: String?
    public let localizedName: String?
    public let processIdentifier: pid_t?
    /// Path of the running executable. The reliable identifier for apps without a bundle
    /// (CLI tools and SDL apps such as scrcpy), which the bundle-ID-only design could not target.
    public let executablePath: String?

    public init(
        bundleIdentifier: String? = nil,
        localizedName: String? = nil,
        processIdentifier: pid_t? = nil,
        executablePath: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.processIdentifier = processIdentifier
        self.executablePath = executablePath
    }

    /// The process's name: the executable's file name (authoritative for bundle-less
    /// processes), falling back to the localized name.
    public var processName: String? {
        if let executablePath, !executablePath.isEmpty {
            let name = URL(fileURLWithPath: executablePath).lastPathComponent
            if !name.isEmpty { return name }
        }
        return localizedName
    }

    /// Identifier an app rule can target this app by: bundle ID, or a scoped
    /// `process:`/`path:` pattern for bundle-less processes.
    public var ruleIdentifier: String? {
        if let bundleIdentifier, !bundleIdentifier.isEmpty { return bundleIdentifier }
        if let processName, !processName.isEmpty { return DefaultAppRules.processNamePrefix + processName }
        if let executablePath, !executablePath.isEmpty { return DefaultAppRules.executablePathPrefix + executablePath }
        return nil
    }

    /// Whether both identities point at the same app: matching bundle IDs, or — for
    /// bundle-less processes — matching executable paths.
    public func isSameApp(as other: AppIdentity) -> Bool {
        if let bundleIdentifier { return bundleIdentifier == other.bundleIdentifier }
        if let executablePath { return executablePath == other.executablePath }
        return false
    }
}

