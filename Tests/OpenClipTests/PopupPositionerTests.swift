import XCTest
@testable import Core
@testable import OpenClip

final class PopupPositionerTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let size = CGSize(width: 50, height: 50)

    // Popup should appear above release point for an upward drag, anchored at the release X.
    func testLeftAnchoredPositioning() {
        let release = CGPoint(x: 400, y: 200)
        let frame = PopupPositioner.placeNearReleasePoint(
            releasePoint: release, popupSize: size, screenBounds: screen
        )
        XCTAssertEqual(frame.origin.x, 400 - PopupPositioner.firstActionCenterOffset)
        XCTAssertEqual(frame.origin.y, 206)
    }

    func testOCRPopupStaysBesideTheRegionSelectionReleasePoint() {
        let releasePoint = CGPoint(x: 620, y: 310)
        let context = SelectionContext(
            text: "recognized text",
            cursorPosition: releasePoint,
            mouseDownLocation: CGPoint(x: 560, y: 340),
            selectionBounds: CGRect(x: 560, y: 280, width: 160, height: 90),
            source: .ocr
        )
        let frame = PopupPositioner.calculateFrame(
            for: context,
            popupSize: CGSize(width: 180, height: 48),
            in: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(frame.origin.x, releasePoint.x - PopupPositioner.firstActionCenterOffset)
        // The downward drag places the card below the release point, 6 pt past its top edge.
        XCTAssertEqual(frame.maxY, releasePoint.y - 6)
    }

    func testOCRPopupUsesCurrentPointerAndNormalGapAfterRecognitionDelay() {
        let releasePoint = CGPoint(x: 220, y: 230)
        let currentPointer = CGPoint(x: 640, y: 390)
        let anchor = CaptureTextPopupAnchor.resolve(
            releasePoint: releasePoint,
            mouseDownPoint: CGPoint(x: 180, y: 250),
            currentPointer: currentPointer
        )
        let context = SelectionContext(
            text: "recognized text",
            cursorPosition: anchor.cursorPosition,
            mouseDownLocation: anchor.mouseDownLocation,
            selectionBounds: CGRect(x: 180, y: 210, width: 120, height: 80),
            source: .ocr
        )
        let frame = PopupPositioner.calculateFrame(
            for: context,
            popupSize: CGSize(width: 180, height: 48),
            in: screen
        )

        XCTAssertEqual(anchor.cursorPosition, currentPointer)
        XCTAssertNil(anchor.mouseDownLocation)
        XCTAssertEqual(frame.origin.x, currentPointer.x - PopupPositioner.firstActionCenterOffset)
        XCTAssertEqual(frame.minY - currentPointer.y, 6)
        let dx = max(0, max(frame.minX - currentPointer.x, currentPointer.x - frame.maxX))
        let dy = max(0, max(frame.minY - currentPointer.y, currentPointer.y - frame.maxY))
        XCTAssertEqual(hypot(dx, dy), 6)
    }

    func testOCRArrivalGraceExpiresAndDoesNotBecomePermanent() {
        let deadline: TimeInterval = 15
        XCTAssertTrue(PopupDismissalGrace.isActive(now: 14.99, deadline: deadline))
        XCTAssertFalse(PopupDismissalGrace.isActive(now: deadline, deadline: deadline))
        XCTAssertFalse(PopupDismissalGrace.isActive(now: 30, deadline: nil))
    }

    // Top-to-Bottom drag: released below the start point, so the popup goes BELOW the cursor to avoid covering text.
    func testDragDownPositioning() {
        let start = CGPoint(x: 400, y: 350)
        let release = CGPoint(x: 400, y: 200)
        let frame = PopupPositioner.placeNearReleasePoint(
            releasePoint: release, mouseDownPoint: start, popupSize: size, screenBounds: screen
        )
        XCTAssertEqual(frame.origin.y, 144)
    }

    // Near right edge: popup should be pushed left
    func testRightEdgeClamping() {
        let release = CGPoint(x: 790, y: 200)
        let frame = PopupPositioner.placeNearReleasePoint(
            releasePoint: release, popupSize: size, screenBounds: screen
        )
        XCTAssertEqual(frame.origin.x, 742)
    }

    // Near left edge: popup should be pushed right
    func testLeftEdgeClamping() {
        let release = CGPoint(x: 5, y: 200)
        let frame = PopupPositioner.placeNearReleasePoint(
            releasePoint: release, popupSize: size, screenBounds: screen
        )
        XCTAssertEqual(frame.origin.x, 8)
    }

    // Near top edge: popup should flip BELOW the release point
    func testTopEdgeFlipToBelow() {
        let release = CGPoint(x: 400, y: 580)
        let frame = PopupPositioner.placeNearReleasePoint(
            releasePoint: release, popupSize: size, screenBounds: screen
        )
        XCTAssertEqual(frame.origin.y, 524)
    }

    // Near bottom edge: popup should stay above and clamp
    func testBottomEdgeClamped() {
        let release = CGPoint(x: 400, y: 5)
        let frame = PopupPositioner.placeNearReleasePoint(
            releasePoint: release, popupSize: size, screenBounds: screen
        )
        XCTAssertEqual(frame.origin.y, 11)
    }

    func testScreenFrameResolutionInclusivelyMatchesEdges() {
        let screen1 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screen2 = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

        // Point exactly on the boundary of screen 2 (x = 3840)
        let pointOnRightEdge = CGPoint(x: 3840, y: 500)
        let resolved = PopupPositioner.screenFrame(containing: pointOnRightEdge, screenFrames: [screen1, screen2])
        XCTAssertEqual(resolved, screen2)
    }

    func testAlignedXPositions() {
        let releaseX: CGFloat = 400
        let anchoredX = PopupPositioner.alignedX(releaseX: releaseX, width: 200, screenBounds: screen)
        XCTAssertEqual(anchoredX, 400 - PopupPositioner.firstActionCenterOffset)

        let clampedX = PopupPositioner.alignedX(releaseX: 790, width: 200, screenBounds: screen)
        XCTAssertEqual(clampedX, screen.maxX - 200 - 8, "clamped to right padding edge")
    }
}
