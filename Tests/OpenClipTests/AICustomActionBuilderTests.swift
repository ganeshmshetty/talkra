import XCTest
@testable import OpenClip
import Core

@MainActor
private final class MockAIProvider: AIProvider {
    var type: AIProviderType = .local
    var responseToReturn: String = ""
    var errorToThrow: Error? = nil

    func process(prompt: String, text: String) async throws -> String {
        if let errorToThrow {
            throw errorToThrow
        }
        return responseToReturn
    }

    func processStream(prompt: String, text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if let errorToThrow {
                continuation.finish(throwing: errorToThrow)
            } else {
                continuation.yield(responseToReturn)
                continuation.finish()
            }
        }
    }
}

@MainActor
final class AICustomActionBuilderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.reset()
        AIServiceManager.shared.isAIEnabled = true
    }

    override func tearDown() {
        TestIsolation.reset()
        super.tearDown()
    }

    func testGenerateSuccessfulJavaScriptAction() async throws {
        let mock = MockAIProvider()
        mock.responseToReturn = """
        <result>
        {
          "identifier": "com.openclip.user.snake-camel",
          "name": "CamelCase Converter",
          "description": "Converts snake_case to camelCase",
          "action": {
            "title": "CamelCase",
            "icon": "symbol(textformat)",
            "type": "javascript",
            "scriptCode": "function action(text) { return text.replace(/_([a-z])/g, function(_, c) { return c.toUpperCase(); }); }",
            "output": "text",
            "result": "paste-or-copy",
            "isAsync": false
          }
        }
        </result>
        """
        AIServiceManager.shared.providerOverride = mock

        let synthesis = try await AICustomActionService.generate(userPrompt: "convert snake_case to camelCase")

        XCTAssertEqual(synthesis.title, "CamelCase")
        XCTAssertEqual(synthesis.description, "Converts snake_case to camelCase")
        XCTAssertEqual(synthesis.iconSymbol, "textformat")
        XCTAssertEqual(synthesis.kind, "javascript")
        XCTAssertEqual(synthesis.delivery, .replace)
        XCTAssertFalse(synthesis.isAsync)
        XCTAssertTrue(synthesis.scriptCode.contains("function action(text)"))
    }

    func testGenerateDeliveryInferenceCopyAndPreview() async throws {
        let mock = MockAIProvider()
        mock.responseToReturn = """
        <result>
        {
          "identifier": "com.openclip.user.timestamp",
          "name": "Current Timestamp",
          "description": "Copies current epoch timestamp",
          "action": {
            "title": "Copy Timestamp",
            "icon": "clock",
            "type": "javascript",
            "scriptCode": "function action(text) { return Date.now().toString(); }",
            "output": "text",
            "result": "copy",
            "isAsync": false
          }
        }
        </result>
        """
        AIServiceManager.shared.providerOverride = mock

        let synthesis = try await AICustomActionService.generate(userPrompt: "copy current timestamp")
        XCTAssertEqual(synthesis.delivery, .copy)
        XCTAssertEqual(synthesis.iconSymbol, "clock")
    }

    func testGenerateURLAction() async throws {
        let mock = MockAIProvider()
        mock.responseToReturn = """
        <result>
        {
          "identifier": "com.openclip.user.github-search",
          "name": "GitHub Search",
          "description": "Search code on GitHub",
          "action": {
            "title": "Search GitHub",
            "icon": "link",
            "type": "url",
            "url": "https://github.com/search?q={query}",
            "result": "preview"
          }
        }
        </result>
        """
        AIServiceManager.shared.providerOverride = mock

        let synthesis = try await AICustomActionService.generate(userPrompt: "search github")
        XCTAssertEqual(synthesis.kind, "url")
        XCTAssertEqual(synthesis.delivery, .preview)
        XCTAssertEqual(synthesis.urlTemplate, "https://github.com/search?q={query}")
    }

    func testGenerateHandlesMarkdownFencesInResult() async throws {
        let mock = MockAIProvider()
        mock.responseToReturn = """
        <result>
        ```json
        {
          "identifier": "com.openclip.user.slugify",
          "name": "Slugify",
          "description": "Converts string to URL slug",
          "action": {
            "title": "Slugify",
            "icon": "link",
            "type": "javascript",
            "scriptCode": "function action(t) { return t.toLowerCase().replace(/\\\\s+/g, '-'); }",
            "output": "text",
            "result": "paste-or-copy"
          }
        }
        ```
        </result>
        """
        AIServiceManager.shared.providerOverride = mock

        let synthesis = try await AICustomActionService.generate(userPrompt: "turn text into slug")
        XCTAssertEqual(synthesis.title, "Slugify")
        XCTAssertEqual(synthesis.kind, "javascript")
        XCTAssertEqual(synthesis.delivery, .replace)
    }

    func testGenerateThrowsWhenAIDisabled() async {
        AIServiceManager.shared.isAIEnabled = false

        do {
            _ = try await AICustomActionService.generate(userPrompt: "test")
            XCTFail("Expected error when AI is disabled")
        } catch {
            // Expected
        }
    }

    func testDeliveryModesLabelsAndIcons() {
        XCTAssertEqual(AIActionDeliveryMode.replace.label, "Paste")
        XCTAssertEqual(AIActionDeliveryMode.replace.icon, "arrow.triangle.2.circlepath")

        XCTAssertEqual(AIActionDeliveryMode.copy.label, "Copy")
        XCTAssertEqual(AIActionDeliveryMode.copy.icon, "doc.on.doc")

        XCTAssertEqual(AIActionDeliveryMode.preview.label, "Show")
        XCTAssertEqual(AIActionDeliveryMode.preview.icon, "eye")
    }

    func testCleanJSONResponseExtractsFromConversationalSurroundings() {
        let rawWithChat = """
        Here is the JSON manifest you requested:
        ```json
        {
          "name": "Trim Whitespace",
          "action": {
            "title": "Trim",
            "type": "javascript",
            "scriptCode": "function action(t) { return t.trim(); }"
          }
        }
        ```
        Hope that helps! Let me know if you need anything else.
        """

        let cleaned = AICustomActionService.cleanJSONResponse(rawWithChat)
        XCTAssertTrue(cleaned.hasPrefix("{"))
        XCTAssertTrue(cleaned.hasSuffix("}"))
        XCTAssertFalse(cleaned.contains("Here is the JSON"))
        XCTAssertFalse(cleaned.contains("Hope that helps"))
    }

    func testGenerateHandlesFlattenedJSONAndSynonymKeys() async throws {
        let mock = MockAIProvider()
        mock.responseToReturn = """
        {
          "identifier": "com.openclip.user.uppercase",
          "name": "Uppercase Text",
          "kind": "javascript",
          "code": "function action(text) { return text.toUpperCase(); }",
          "delivery": "paste-or-copy"
        }
        """
        AIServiceManager.shared.providerOverride = mock

        let synthesis = try await AICustomActionService.generate(userPrompt: "uppercase text")
        XCTAssertEqual(synthesis.title, "Uppercase Text")
        XCTAssertEqual(synthesis.kind, "javascript")
        XCTAssertEqual(synthesis.delivery, .replace)
        XCTAssertTrue(synthesis.scriptCode.contains("text.toUpperCase()"))
    }

    func testGenerateInfersAsyncForOpenClipFetch() async throws {
        let mock = MockAIProvider()
        mock.responseToReturn = """
        <result>
        {
          "identifier": "com.openclip.user.weather",
          "name": "Weather Fetcher",
          "action": {
            "title": "Weather",
            "type": "javascript",
            "scriptCode": "async function action(text) { const res = await openclip.fetch('https://api.weather.com/' + text); return res.text(); }",
            "result": "preview",
            "isAsync": false
          }
        }
        </result>
        """
        AIServiceManager.shared.providerOverride = mock

        let synthesis = try await AICustomActionService.generate(userPrompt: "fetch weather")
        XCTAssertEqual(synthesis.kind, "javascript")
        XCTAssertTrue(synthesis.isAsync, "Should infer isAsync == true when script contains openclip.fetch / async / await")
    }

    func testGenerateFallsBackOnInvalidSFSymbol() async throws {
        let mock = MockAIProvider()
        mock.responseToReturn = """
        <result>
        {
          "name": "Custom URL",
          "action": {
            "title": "Search",
            "type": "url",
            "url": "https://example.com/search?q={query}",
            "icon": "hallucinated_non_existent_symbol_12345"
          }
        }
        </result>
        """
        AIServiceManager.shared.providerOverride = mock

        let synthesis = try await AICustomActionService.generate(userPrompt: "search example")
        XCTAssertEqual(synthesis.kind, "url")
        XCTAssertEqual(synthesis.iconSymbol, "safari", "Should fall back to default icon for URL kind when symbol is invalid")
    }

    func testValidateJavaScriptSyntax() {
        let validCode = "function action(text) { return text.toUpperCase(); }"
        XCTAssertNil(AICustomActionService.validateJavaScriptSyntax(validCode))

        let invalidCode = "function action(text) { return text."
        let warning = AICustomActionService.validateJavaScriptSyntax(invalidCode)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("SyntaxError") == true)
    }

    func testPayloadContentAndHeaderLabel() {
        var urlSynthesis = AICustomActionSynthesis(
            title: "Search",
            description: "Search",
            iconSymbol: "safari",
            kind: "url",
            scriptCode: "",
            urlTemplate: "https://google.com/search?q={query}",
            delivery: .preview
        )
        XCTAssertEqual(urlSynthesis.payloadHeaderLabel, "URL TEMPLATE")
        XCTAssertEqual(urlSynthesis.payloadContent, "https://google.com/search?q={query}")

        urlSynthesis.payloadContent = "https://duckduckgo.com/?q={query}"
        XCTAssertEqual(urlSynthesis.urlTemplate, "https://duckduckgo.com/?q={query}")

        let shellSynthesis = AICustomActionSynthesis(
            title: "Shell",
            description: "Shell",
            iconSymbol: "terminal",
            kind: "shell",
            scriptCode: "echo test",
            delivery: .replace
        )
        XCTAssertEqual(shellSynthesis.payloadHeaderLabel, "SHELL SCRIPT")
        XCTAssertEqual(shellSynthesis.payloadContent, "echo test")

        let snippetSynthesis = AICustomActionSynthesis(
            title: "Snippet",
            description: "Snippet",
            iconSymbol: "text.quote",
            kind: "textsnippet",
            scriptCode: "**{text}**",
            delivery: .replace
        )
        XCTAssertEqual(snippetSynthesis.payloadHeaderLabel, "TEXT SNIPPET")
        XCTAssertEqual(snippetSynthesis.payloadContent, "**{text}**")
    }
}
