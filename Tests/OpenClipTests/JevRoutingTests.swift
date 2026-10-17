import XCTest
import Core
@testable import OpenClip

final class JevRoutingTests: XCTestCase {
    private let request = AgentRequest(transcript: "clean the em dash", selectedText: "a — b", appBundleID: nil, history: [])

    private func reply(_ choice: String, _ confidence: Double) -> Data {
        Data("{\"answers\":{\"route\":{\"type\":\"choice\",\"choice\":\"\(choice)\",\"confidence\":\(confidence)}}}".utf8)
    }

    func testConfidentActionRuns() {
        let decision = JevRouting.decision(from: reply("action:clean", 0.95), request: request, knownIDs: ["clean"])
        XCTAssertEqual(decision, .runAction(actionID: "clean"))
    }

    func testLowConfidenceFallsBack() {
        XCTAssertNil(JevRouting.decision(from: reply("action:clean", 0.3), request: request, knownIDs: ["clean"]))
    }

    func testUnknownActionAndScriptFallBack() {
        XCTAssertNil(JevRouting.decision(from: reply("action:nope", 1), request: request, knownIDs: ["clean"]))
        XCTAssertNil(JevRouting.decision(from: reply("script", 1), request: request, knownIDs: []))
    }

    func testRewriteNeedsSelection() {
        XCTAssertEqual(JevRouting.decision(from: reply("rewrite", 1), request: request, knownIDs: []), .rewrite(instruction: "clean the em dash"))
    }

    func testBodyListsActionsAndOmitsScriptsWhenBlocked() throws {
        let body = JevRouting.requestBody(for: request, actions: [ActionDescriptor(id: "clean", title: "Clean")], budget: .onDevice)
        let q = try XCTUnwrap((body["questions"] as? [String: Any])?["route"] as? [String: Any])
        let criteria = try XCTUnwrap(q["criteria"] as? [String: String])
        XCTAssertNotNil(criteria["action:clean"])
        XCTAssertNil(criteria["script"])
    }
}

@MainActor
final class CloudflareProviderTests: XCTestCase {
    func testAccountIDBuildsWorkersAIEndpoint() {
        XCTAssertEqual(CloudAPIProvider.resolveBaseURL(provider: .cloudflare, customBaseURL: "abc123"),
                       "https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1")
        XCTAssertEqual(CloudAPIProvider.resolveBaseURL(provider: .cloudflare, customBaseURL: "https://proxy.example/v1"),
                       "https://proxy.example/v1")
    }
}

final class DecisionEnvelopeTests: XCTestCase {
    func testCloudflareResultEnvelopeIsUnwrapped() {
        let data = Data("{\"result\":{\"answers\":{\"route\":{\"choice\":\"answer\",\"confidence\":0.9}}},\"success\":true}".utf8)
        let request = AgentRequest(transcript: "why is the sky blue")
        XCTAssertEqual(JevRouting.decision(from: data, request: request, knownIDs: []), .answer(instruction: "why is the sky blue"))
    }
}
