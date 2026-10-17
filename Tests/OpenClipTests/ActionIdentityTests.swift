import XCTest
@testable import Core

final class ActionIdentityTests: XCTestCase {
    private struct StubAction: Action {
        let id: String
        let title = "Stub"
        let icon = ActionIcon.symbol("star")
        let chrome: ActionChrome
        func isEnabled(for context: ActionContext) -> Bool { true }
        func perform(_ context: ActionContext) async throws -> ActionResult { .success }
    }

    func testLeafActionsAreBindable() {
        let leaf = StubAction(id: "builtin.copy", chrome: ActionChrome())
        XCTAssertTrue(ActionIdentity.isBindable(leaf))
    }

    func testAIPresetsAreBindable() {
        let preset = StubAction(id: "ai.preset.proofread", chrome: ActionChrome(source: .ai))
        XCTAssertTrue(ActionIdentity.isBindable(preset))
    }

    func testGroupsAreNotBindable() {
        let group = StubAction(
            id: "com.pkg.leafy",
            chrome: ActionChrome(rowStyle: .actionGroup, popupBehavior: .showSubActions)
        )
        XCTAssertFalse(ActionIdentity.isBindable(group))
    }

    func testAILauncherIsNotBindable() {
        let launcher = StubAction(id: "builtin.aiTools", chrome: ActionChrome(launchesAI: true))
        XCTAssertFalse(ActionIdentity.isBindable(launcher))
    }

    func testCompletionPseudoActionIsNotBindable() {
        let completion = StubAction(
            id: "builtin.completion",
            chrome: ActionChrome(popupBehavior: .provideCompletions)
        )
        XCTAssertFalse(ActionIdentity.isBindable(completion))
    }
}
