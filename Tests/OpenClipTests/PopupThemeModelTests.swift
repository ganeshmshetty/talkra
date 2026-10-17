import XCTest
@testable import OpenClip

/// The resolution rules the Appearance swatches render through. Pure, so the "what does this
/// choice look like" answer is pinned without a live popup.
final class PopupThemeModelTests: XCTestCase {

    func testEffectiveSchemePinsLightAndDarkAndFollowsSystem() {
        XCTAssertEqual(PopupThemeModel.effectiveScheme(appearance: "light", systemIsDark: true), .light)
        XCTAssertEqual(PopupThemeModel.effectiveScheme(appearance: "dark", systemIsDark: false), .dark)
        XCTAssertEqual(PopupThemeModel.effectiveScheme(appearance: "system", systemIsDark: true), .dark)
        XCTAssertEqual(PopupThemeModel.effectiveScheme(appearance: "system", systemIsDark: false), .light)
    }
}
