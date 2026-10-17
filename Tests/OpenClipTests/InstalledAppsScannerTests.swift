import XCTest
@testable import OpenClip

@MainActor
final class InstalledAppsScannerTests: XCTestCase {
    func testScanInstalledAppsFromDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a mock app bundle
        let appBundleURL = tempDir.appendingPathComponent("MockApp.app")
        let contentsURL = appBundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "com.test.mockapp",
            "CFBundleName": "MockApp",
            "CFBundleDisplayName": "Mock App"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let scanner = InstalledAppsScanner(searchDirectories: [tempDir.path])
        let apps = await scanner.scanInstalledApps()

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.bundleIdentifier, "com.test.mockapp")
        XCTAssertEqual(apps.first?.name, "MockApp")
        XCTAssertTrue(apps.first?.path.hasSuffix("/MockApp.app") == true)
    }
}
