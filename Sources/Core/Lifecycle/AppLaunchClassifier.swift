// AppLaunchClassifier.swift
// OpenClip
//
// Pure domain classifier that categorizes an application launch into First Install,
// App Update, Permission Recovery, or Normal Launch based on persisted state and current runtime.
import Foundation

public enum AppLaunchScenario: Equatable, Sendable {
    /// Clean first install or install where onboarding has not been completed.
    case firstInstall
    /// The app binary version or build changed (e.g., 1.0.0 -> 1.1.0 or build 1 -> build 2).
    case appUpdate(previousVersion: String, currentVersion: String, previousBuild: String, currentBuild: String)
    /// Same-version reinstall or runtime permission drop where Accessibility is missing.
    case permissionRecovery
    /// Normal launch with active permissions.
    case normalLaunch
}

public struct AppLaunchClassifier: Sendable {
    /// Classifies the launch from persisted version/build and current accessibility state.
    public static func classify(
        lastRunVersion: String,
        currentVersion: String,
        lastRunBuild: String = "",
        currentBuild: String = "",
        hasCompletedOnboarding: Bool,
        isAccessibilityGranted: Bool
    ) -> AppLaunchScenario {
        let trimmedLastVersion = lastRunVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCurrentVersion = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLastBuild = lastRunBuild.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCurrentBuild = currentBuild.trimmingCharacters(in: .whitespacesAndNewlines)

        if !hasCompletedOnboarding || trimmedLastVersion.isEmpty {
            return .firstInstall
        }

        // Build-only bumps count, including migrated installs that never persisted a build.
        let versionChanged = trimmedLastVersion != trimmedCurrentVersion
        let buildChanged: Bool = {
            guard !trimmedCurrentBuild.isEmpty else { return false }
            if trimmedLastBuild.isEmpty { return true }
            return trimmedLastBuild != trimmedCurrentBuild
        }()

        if versionChanged || buildChanged {
            return .appUpdate(
                previousVersion: trimmedLastVersion,
                currentVersion: trimmedCurrentVersion,
                previousBuild: trimmedLastBuild,
                currentBuild: trimmedCurrentBuild
            )
        }

        // If the same version is running but accessibility permission is missing (e.g. reinstall or revoked).
        if !isAccessibilityGranted {
            return .permissionRecovery
        }

        return .normalLaunch
    }
}
