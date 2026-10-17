import XCTest
@testable import Core

final class AgentDecisionParserTests: XCTestCase {
    private let known: Set<String> = ["translate", "uppercase"]

    private func parse(_ raw: String) throws -> AgentDecision {
        try AgentDecisionParser.parse(raw, knownActionIDs: known)
    }

    func testFirstJSONObjectSkipsProseAndFences() {
        let raw = "Sure! Here you go:\n```json\n{\"route\":\"answer\",\"instruction\":\"x\"}\n```\nDone {not json}"
        XCTAssertEqual(AgentDecisionParser.firstJSONObject(in: raw), "{\"route\":\"answer\",\"instruction\":\"x\"}")
    }

    func testFirstJSONObjectIgnoresBracesInsideStrings() {
        let raw = #"{"route":"synthesize","code":"function f() { return \"}\"; }","language":"javascript"} trailing"#
        XCTAssertEqual(AgentDecisionParser.firstJSONObject(in: raw), #"{"route":"synthesize","code":"function f() { return \"}\"; }","language":"javascript"}"#)
    }

    func testFirstJSONObjectHandlesNestingAndMissing() {
        XCTAssertEqual(AgentDecisionParser.firstJSONObject(in: #"a {"o":["x",{"y":1}]} b"#), #"{"o":["x",{"y":1}]}"#)
        XCTAssertNil(AgentDecisionParser.firstJSONObject(in: "no json here"))
        XCTAssertNil(AgentDecisionParser.firstJSONObject(in: "{ unterminated"))
    }

    func testActionRoute() throws {
        XCTAssertEqual(try parse(#"{"route":"action","actionID":"translate"}"#), .runAction(actionID: "translate"))
    }

    func testUnknownActionIsMalformed() {
        XCTAssertThrowsError(try parse(#"{"route":"action","actionID":"nope"}"#)) { error in
            guard case AgentError.malformedDecision = error else { return XCTFail("\(error)") }
        }
    }

    func testSynthesizeRouteDefaultsToCardDelivery() throws {
        XCTAssertEqual(
            try parse(#"{"route":"synthesize","language":"javascript","code":"return 1"}"#),
            .synthesize(SynthesizedScript(language: .javascript, code: "return 1"), delivery: .card)
        )
        XCTAssertEqual(
            try parse(#"{"route":"synthesize","language":"shell","code":"date","delivery":"replace"}"#),
            .synthesize(SynthesizedScript(language: .shell, code: "date"), delivery: .replace)
        )
    }

    func testSynthesizeRequiresLanguageAndCode() {
        XCTAssertThrowsError(try parse(#"{"route":"synthesize","code":"x"}"#))
        XCTAssertThrowsError(try parse(#"{"route":"synthesize","language":"javascript","code":"  "}"#))
        XCTAssertThrowsError(try parse(#"{"route":"synthesize","language":"python","code":"x"}"#))
    }

    func testRewriteAndAnswer() throws {
        XCTAssertEqual(try parse(#"{"route":"rewrite","instruction":"make it formal"}"#), .rewrite(instruction: "make it formal"))
        XCTAssertEqual(try parse(#"{"route":"answer","instruction":"explain"}"#), .answer(instruction: "explain"))
        XCTAssertThrowsError(try parse(#"{"route":"rewrite","instruction":""}"#))
    }

    func testClarifyKeepsTwoToFourOptions() throws {
        XCTAssertEqual(
            try parse(#"{"route":"clarify","question":"Which?","options":["a","b","c","d","e"]}"#),
            .clarify(question: "Which?", options: ["a", "b", "c", "d"])
        )
        XCTAssertEqual(
            try parse(#"{"route":"clarify","options":[" a ","","b"]}"#),
            .clarify(question: "", options: ["a", "b"])
        )
        XCTAssertThrowsError(try parse(#"{"route":"clarify","question":"?","options":["only"]}"#))
    }

    func testUnknownRouteAndGarbageAreMalformed() {
        XCTAssertThrowsError(try parse(#"{"route":"dance"}"#))
        XCTAssertThrowsError(try parse("I cannot help with that."))
        XCTAssertThrowsError(try parse(#"{"route":5}"#))
    }

    func testIgnoresUnknownKeysAndConfidence() throws {
        XCTAssertEqual(try parse(#"{"route":"answer","instruction":"hi","confidence":0.4,"extra":true}"#), .answer(instruction: "hi"))
    }
}

final class AgentPromptsTests: XCTestCase {
    private let actions = [
        ActionDescriptor(id: "a", title: "Alpha"),
        ActionDescriptor(id: "b", title: "Bravo"),
        ActionDescriptor(id: "t", title: "Translate"),
        ActionDescriptor(id: "u", title: "Uppercase"),
    ]

    func testPrioritizedPutsMentionedActionsFirstAndKeepsTheRest() {
        XCTAssertEqual(AgentPrompts.prioritized(actions, for: "translate this").map(\.id), ["t", "a", "b", "u"])
        XCTAssertEqual(AgentPrompts.prioritized(actions, for: "nothing relevant").map(\.id), ["a", "b", "t", "u"])
    }

    func testRoutingCapsListedActionsKeepingTheMatch() {
        let prompt = AgentPrompts.routing(AgentRequest(transcript: "uppercase it"), actions: actions, maxActions: 1)
        XCTAssertTrue(prompt.contains("- u: Uppercase"))
        XCTAssertFalse(prompt.contains("- a: Alpha"))
    }

    func testOnDeviceBudgetIsSmallerThanFull() {
        XCTAssertFalse(RoutingBudget.onDevice.allowsScripts)
        XCTAssertTrue(RoutingBudget.local.allowsScripts)
        XCTAssertLessThan(RoutingBudget.onDevice.maxActions, RoutingBudget.full.maxActions)
        XCTAssertLessThan(RoutingBudget.onDevice.selectionSample, RoutingBudget.full.selectionSample)
    }

    func testRoutingPromptOmitsScriptsWhenNotAllowed() {
        let request = AgentRequest(transcript: "count the words")
        let withScripts = AgentPrompts.routing(request, actions: [])
        let without = AgentPrompts.routing(request, actions: [], allowsScripts: false)
        XCTAssertTrue(withScripts.contains("\"route\":\"synthesize\""))
        XCTAssertTrue(withScripts.contains("Script rules:"))
        XCTAssertFalse(without.contains("synthesize"))
        XCTAssertFalse(without.contains("Script rules:"))
        XCTAssertTrue(without.contains("\"route\":\"clarify\""))
    }
}
