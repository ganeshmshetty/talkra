import XCTest
@testable import OpenClip

@MainActor
final class VoicePillTests: XCTestCase {
    func testPushKeepsBoundedClampedLevelHistory() {
        let model = VoicePillModel()
        for i in 0..<30 { model.push(transcript: "t\(i)", level: i == 29 ? 2 : 0.5) }
        guard case let .listening(transcript, levels) = model.phase else { return XCTFail() }
        XCTAssertEqual(transcript, "t29")
        XCTAssertEqual(levels.count, VoicePillModel.levelHistoryCount)
        XCTAssertEqual(levels.last, 1)
    }

    func testOriginCentresAboveAnchor() {
        let origin = VoicePillPanelController.origin(
            for: CGSize(width: 200, height: 40),
            anchor: CGRect(x: 400, y: 300, width: 100, height: 20),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        XCTAssertEqual(origin, CGPoint(x: 350, y: 328))
    }

    func testOriginClampsHorizontally() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = VoicePillPanelController.origin(for: CGSize(width: 200, height: 40), anchor: CGRect(x: 5, y: 300, width: 10, height: 20), visibleFrame: frame)
        XCTAssertEqual(left.x, 0)
        let right = VoicePillPanelController.origin(for: CGSize(width: 200, height: 40), anchor: CGRect(x: 1430, y: 300, width: 10, height: 20), visibleFrame: frame)
        XCTAssertEqual(right.x, 1240)
    }

    func testOriginFlipsBelowWhenNoRoomAbove() {
        let origin = VoicePillPanelController.origin(
            for: CGSize(width: 200, height: 40),
            anchor: CGRect(x: 400, y: 870, width: 100, height: 20),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        XCTAssertEqual(origin, CGPoint(x: 350, y: 822))
    }
}
