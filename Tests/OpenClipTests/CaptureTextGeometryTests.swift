import XCTest
@testable import Core
@testable import OpenClip

final class CaptureTextGeometryTests: XCTestCase {
    func testMapsAppKitRegionToDisplayLocalTopOriginPixels() {
        let screen = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let geometry = CaptureRegionGeometry.map(
            rect: CGRect(x: 250, y: 200, width: 300, height: 100),
            screenFrame: screen,
            scale: 2,
            displayID: 42
        )

        XCTAssertEqual(geometry?.displayID, 42)
        XCTAssertEqual(geometry?.sourceRect, CGRect(x: 150, y: 550, width: 300, height: 100))
        XCTAssertEqual(geometry?.pixelSize, CGSize(width: 600, height: 200))
    }

    func testClampsRegionToDisplayAndRejectsTinySelections() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let geometry = CaptureRegionGeometry.map(
            rect: CGRect(x: 790, y: 580, width: 40, height: 40),
            screenFrame: screen,
            scale: 1,
            displayID: 7
        )
        XCTAssertEqual(geometry?.sourceRect, CGRect(x: 790, y: 0, width: 10, height: 20))
        XCTAssertNil(CaptureRegionGeometry.map(
            rect: CGRect(x: 10, y: 10, width: 4, height: 20),
            screenFrame: screen,
            scale: 1,
            displayID: 7
        ))
    }

    func testPopupAnchorKeepsReleasePointAndDragDirectionWhenPointerHasNotMoved() {
        let anchor = CaptureTextPopupAnchor.resolve(
            releasePoint: CGPoint(x: 100, y: 200),
            mouseDownPoint: CGPoint(x: 40, y: 180),
            currentPointer: CGPoint(x: 106, y: 202)
        )

        XCTAssertEqual(anchor.cursorPosition, CGPoint(x: 100, y: 200))
        XCTAssertEqual(anchor.mouseDownLocation, CGPoint(x: 40, y: 180))
    }

    func testPopupAnchorFollowsMovedPointerAndDropsStaleDragDirection() {
        let anchor = CaptureTextPopupAnchor.resolve(
            releasePoint: CGPoint(x: 100, y: 200),
            mouseDownPoint: CGPoint(x: 40, y: 180),
            currentPointer: CGPoint(x: 140, y: 230)
        )

        XCTAssertEqual(anchor.cursorPosition, CGPoint(x: 140, y: 230))
        XCTAssertNil(anchor.mouseDownLocation)
    }

    @MainActor
    func testValidReleaseClosesSelectorOverlayBeforeStartingCaptureWork() {
        var overlayVisible = true
        var captureStarted = false

        CaptureTextReleaseHandoff.closeOverlayThenStartWork(
            closeOverlay: { overlayVisible = false },
            startWork: {
                XCTAssertFalse(overlayVisible)
                captureStarted = true
            }
        )

        XCTAssertTrue(captureStarted)
    }

    @MainActor
    func testCaptureCursorLeaseBalancesOneOverrideAndRestoresAfterOverlayCloses() {
        var pushes = 0
        var pops = 0
        var sets = 0
        var events: [String] = []
        let lease = CaptureCursorLease(
            pushCursor: { pushes += 1 },
            popCursor: { pops += 1; events.append("restore") },
            setCursor: { sets += 1 },
            asyncSet: { $0() },
            asyncReassert: { $0() }
        )

        lease.begin()
        lease.begin()
        lease.refresh()
        XCTAssertTrue(lease.isActive)

        CaptureOverlayCleanup.close(
            closeOverlays: { events.append("close") },
            restoreCursor: { lease.end() }
        )
        lease.end()
        lease.refresh()

        // begin() pushes once synchronously, then re-asserts with a second
        // push after activation settles (activation resets the cursor).
        // end() pops every outstanding push so the stack stays balanced.
        XCTAssertEqual(pushes, 2)
        XCTAssertEqual(pops, 2)
        XCTAssertEqual(sets, 4)
        XCTAssertEqual(events, ["close", "restore", "restore"])
        XCTAssertFalse(lease.isActive)
    }
}
