import XCTest
@testable import Core

final class CodeBlockExtractorTests: XCTestCase {
    func testAliases() {
        XCTAssertEqual(CodeBlockExtractor.aliases(for: .javascript), ["javascript", "js"])
        XCTAssertEqual(CodeBlockExtractor.aliases(for: .shell), ["shell", "sh", "bash", "zsh"])
        XCTAssertEqual(CodeBlockExtractor.aliases(for: .applescript), ["applescript", "osascript"])
    }

    func testBareCodeIsReturnedTrimmed() {
        XCTAssertEqual(CodeBlockExtractor.extract(from: "\n  return input.toUpperCase()\n", expected: .javascript), "return input.toUpperCase()")
    }

    func testSingleFenceWithLanguage() {
        let raw = "Here:\n```js\nconst a = 1;\nreturn a;\n```\nThat's it."
        XCTAssertEqual(CodeBlockExtractor.extract(from: raw, expected: .javascript), "const a = 1;\nreturn a;")
    }

    func testPrefersFenceMatchingExpectedLanguage() {
        let raw = "```json\n{\"a\":1}\n```\n```Bash\necho hi\n```"
        XCTAssertEqual(CodeBlockExtractor.extract(from: raw, expected: .shell), "echo hi")
    }

    func testFallsBackToFirstFenceWhenNoLanguageMatches() {
        let raw = "```\ndisplay dialog \"x\"\n```\n```python\nprint(1)\n```"
        XCTAssertEqual(CodeBlockExtractor.extract(from: raw, expected: .applescript), "display dialog \"x\"")
    }

    func testUnterminatedFenceTakesRestOfReply() {
        XCTAssertEqual(CodeBlockExtractor.extract(from: "```sh\ndate +%s\n", expected: .shell), "date +%s")
    }

    func testEmptyReplyOrEmptyFenceIsNil() {
        XCTAssertNil(CodeBlockExtractor.extract(from: "   \n", expected: .javascript))
        XCTAssertNil(CodeBlockExtractor.extract(from: "```js\n\n```", expected: .javascript))
    }
}
