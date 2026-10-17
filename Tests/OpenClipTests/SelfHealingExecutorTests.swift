import XCTest
@testable import Core

private struct ScriptError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private enum PlainError: Error { case boom }

@MainActor
final class SelfHealingExecutorTests: XCTestCase {
    private let first = SynthesizedScript(language: .javascript, code: "v1")
    private let fixed = SynthesizedScript(language: .javascript, code: "v2")

    func testSuccessOnFirstAttemptDoesNotRepair() async {
        var repairs = 0
        let outcome = await SelfHealingExecutor.run(first) { script in
            "ran \(script.code)"
        } repair: { script, _ in
            repairs += 1
            return script
        }
        guard case let .success(output, script, attempts) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(output, "ran v1")
        XCTAssertEqual(script, first)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(repairs, 0)
    }

    func testRepairsOnceWithErrorMessage() async {
        var seenError = ""
        let outcome = await SelfHealingExecutor.run(first) { script -> String in
            if script.code == "v1" { throw ScriptError(text: "ReferenceError: x is not defined") }
            return "ok"
        } repair: { failed, error in
            XCTAssertEqual(failed, self.first)
            seenError = error
            return self.fixed
        }
        guard case let .success(output, script, attempts) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(output, "ok")
        XCTAssertEqual(script, fixed)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(seenError, "ReferenceError: x is not defined")
    }

    func testGivesUpAfterMaxRepairs() async {
        var executions = 0
        let outcome = await SelfHealingExecutor.run(first) { _ -> String in
            executions += 1
            throw ScriptError(text: "fail \(executions)")
        } repair: { _, _ in
            self.fixed
        }
        guard case let .failure(message, script, attempts) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(message, "fail 2")
        XCTAssertEqual(script, fixed)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(executions, 2)
    }

    func testZeroRepairsRunsOnce() async {
        let outcome = await SelfHealingExecutor.run(first, maxRepairs: 0) { _ -> String in
            throw ScriptError(text: "nope")
        } repair: { _, _ in
            XCTFail("must not repair")
            return self.fixed
        }
        guard case let .failure(message, _, attempts) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(message, "nope")
        XCTAssertEqual(attempts, 1)
    }

    func testRepairThrowingKeepsExecutionError() async {
        let outcome = await SelfHealingExecutor.run(first) { _ -> String in
            throw ScriptError(text: "syntax error")
        } repair: { _, _ in
            throw PlainError.boom
        }
        guard case let .failure(message, script, attempts) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(message, "syntax error")
        XCTAssertEqual(script, first)
        XCTAssertEqual(attempts, 1)
    }

    func testMessageForNonLocalizedErrorUsesDescription() {
        XCTAssertEqual(SelfHealingExecutor.message(for: PlainError.boom), "boom")
        XCTAssertEqual(SelfHealingExecutor.message(for: ScriptError(text: "  spaced \n")), "spaced")
        XCTAssertEqual(SelfHealingExecutor.message(for: AgentError.scriptFailed("stderr text")), "stderr text")
    }
}
