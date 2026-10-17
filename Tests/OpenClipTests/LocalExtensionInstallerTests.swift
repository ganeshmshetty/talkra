// LocalExtensionInstallerTests.swift
// OpenClipTests
//
// Tests for LocalExtensionInstaller URL detection, prompt handling, and direct package installation.
import XCTest
import AppKit
@testable import Core
@testable import OpenClip

final class LocalExtensionInstallerTests: XCTestCase {
    var tempDir: URL!
    var extensionsDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { TestIsolation.reset() }
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        extensionsDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: extensionsDir)
        super.tearDown()
    }

    @MainActor
    func testIsExtensionPackageURL() {
        let packageURL = URL(fileURLWithPath: "/Users/test/Downloads/CleanLink.openclipext")
        XCTAssertTrue(LocalExtensionInstaller.isExtensionPackageURL(packageURL))

        let packageZipURL = URL(fileURLWithPath: "/Users/test/Downloads/CleanLink.openclipext.zip")
        XCTAssertTrue(LocalExtensionInstaller.isExtensionPackageURL(packageZipURL))

        let plainZipURL = URL(fileURLWithPath: "/Users/test/Downloads/CleanLink.zip")
        XCTAssertFalse(LocalExtensionInstaller.isExtensionPackageURL(plainZipURL))

        let scriptURL = URL(fileURLWithPath: "/Users/test/Downloads/script.sh")
        XCTAssertFalse(LocalExtensionInstaller.isExtensionPackageURL(scriptURL))

        let webURL = URL(string: "https://example.com/test.openclipext")!
        XCTAssertFalse(LocalExtensionInstaller.isExtensionPackageURL(webURL))
    }

    @MainActor
    func testInstallNonExistentFileAlerts() async {
        let nonExistentURL = tempDir.appendingPathComponent("Missing.openclipext")
        var presentedAlerts: [String] = []

        let installer = LocalExtensionInstaller.shared
        installer.promptHandler = { alert in
            presentedAlerts.append(alert.messageText)
            return .alertFirstButtonReturn
        }

        await installer.install(from: nonExistentURL)
        XCTAssertEqual(presentedAlerts, ["Extension Not Found"])
    }

    @MainActor
    func testInstallUserCancelled() async throws {
        let pkgDir = tempDir.appendingPathComponent("TestCancel.openclipext")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let manifestContent = """
        {
            "identifier": "com.test.cancel",
            "name": "Test Cancel",
            "actions": [
                {
                    "id": "com.test.cancel.action",
                    "title": "Cancel Action",
                    "type": "url",
                    "url": "https://example.com"
                }
            ]
        }
        """
        try manifestContent.write(to: pkgDir.appendingPathComponent("openclip.json"), atomically: true, encoding: .utf8)

        var promptCount = 0
        let installer = LocalExtensionInstaller.shared
        installer.promptHandler = { alert in
            promptCount += 1
            // Second button is "Cancel"
            return .alertSecondButtonReturn
        }

        await installer.install(from: pkgDir)
        XCTAssertEqual(promptCount, 1)

        // Verify it was not installed into extensionsDir
        let installedPkg = Constants.extensionsDirectory.appendingPathComponent("TestCancel.openclipext")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedPkg.path))
    }

    @MainActor
    func testInstallSuccessAndSettingsNavigation() async throws {
        let settings = MemorySettingsStore()
        ExtensionManager.shared.settingsStore = settings
        ExtensionManager.shared.actionFactory = DefaultActionFactory()

        let pkgDir = tempDir.appendingPathComponent("TestSuccess.openclipext")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let manifestContent = """
        {
            "identifier": "com.test.success",
            "name": "Test Success",
            "version": "1.2.3",
            "author": "OpenClip Tester",
            "description": "A test extension for double-click installs.",
            "actions": [
                {
                    "id": "com.test.success.action",
                    "title": "Success Action",
                    "type": "url",
                    "url": "https://example.com"
                }
            ]
        }
        """
        try manifestContent.write(to: pkgDir.appendingPathComponent("openclip.json"), atomically: true, encoding: .utf8)

        var openedPreferences = false
        var presentedAlerts: [String] = []

        let installer = LocalExtensionInstaller.shared
        installer.configure {
            openedPreferences = true
        }

        installer.promptHandler = { alert in
            presentedAlerts.append(alert.messageText)
            if alert.messageText == "Install Extension?" {
                // First button is "Install"
                return .alertFirstButtonReturn
            } else if alert.messageText == "Extension Installed" {
                // Second button is "View in Settings"
                return .alertSecondButtonReturn
            }
            return .alertFirstButtonReturn
        }

        await installer.install(from: pkgDir)

        XCTAssertEqual(presentedAlerts, ["Install Extension?", "Extension Installed"])
        XCTAssertTrue(openedPreferences)

        // Verify the extension was registered as trusted
        let trust = settings.get(.extensionTrust)
        XCTAssertEqual(trust["com.test.success"], "trusted")

        // Cleanup
        let installedPkg = Constants.extensionsDirectory.appendingPathComponent("TestSuccess.openclipext")
        try? FileManager.default.removeItem(at: installedPkg)
    }
}
