import XCTest
@testable import Core

final class CommandMatcherTests: XCTestCase {
    private let actions = [
        ActionDescriptor(id: "translate", title: "Translate", keywords: ["translation"]),
        ActionDescriptor(id: "markdown", title: "Copy as Markdown", keywords: ["markdown"]),
        ActionDescriptor(id: "uppercase", title: "Uppercase", keywords: ["upper case", "caps"]),
        ActionDescriptor(id: "search", title: "Google Search", keywords: ["google", "search the web"]),
        ActionDescriptor(id: "count", title: "Word Count", keywords: []),
    ]

    func testNormalizeLowercasesStripsPunctuationAndFiller() {
        XCTAssertEqual(CommandMatcher.normalize("Please, can you UPPERCASE this text?"), ["uppercase"])
        XCTAssertEqual(CommandMatcher.normalize("  Copy as Markdown! "), ["copy", "as", "markdown"])
        XCTAssertEqual(CommandMatcher.normalize("could you just make it upper-case for me"), ["make", "upper", "case"])
        XCTAssertEqual(CommandMatcher.normalize(""), [])
    }

    func testPluralsFoldSoASpokenSingularNamesTheAction() {
        let emDashes = [ActionDescriptor(id: "dashes", title: "Clean Em Dashes"), ActionDescriptor(id: "other", title: "Copy")]
        XCTAssertEqual(CommandMatcher.confidentMatch("clean the em dash", actions: emDashes), "dashes")
        XCTAssertEqual(CommandMatcher.stem("categories"), "category")
        XCTAssertEqual(CommandMatcher.stem("class"), "class")
    }

    func testExactTitleScoresOne() {
        let ranked = CommandMatcher.rank("Uppercase", actions: actions)
        XCTAssertEqual(ranked.first, CommandMatch(actionID: "uppercase", score: 1.0))
    }

    func testFillerDoesNotPreventExactMatch() {
        XCTAssertEqual(CommandMatcher.rank("please copy this as markdown", actions: actions).first?.actionID, "markdown")
        XCTAssertEqual(CommandMatcher.rank("please copy this as markdown", actions: actions).first?.score, 1.0)
    }

    func testKeywordExactMatchScoresOne() {
        XCTAssertEqual(CommandMatcher.rank("google this", actions: actions).first, CommandMatch(actionID: "search", score: 1.0))
    }

    func testContainedPhraseScoresBetweenPointSixAndOne() {
        let top = CommandMatcher.rank("translate to french", actions: actions).first
        XCTAssertEqual(top?.actionID, "translate")
        XCTAssertEqual(top?.score ?? 0, 0.8, accuracy: 0.0001)
    }

    func testPartialOverlapScoresBelowPointSix() {
        let top = CommandMatcher.rank("count the vowels", actions: actions).first
        XCTAssertEqual(top?.actionID, "count")
        XCTAssertEqual(top?.score ?? 0, 0.25, accuracy: 0.0001)
    }

    func testUnrelatedTranscriptHasNoMatches() {
        XCTAssertTrue(CommandMatcher.rank("what time is it in tokyo", actions: actions).isEmpty)
    }

    func testRankIsSortedDescendingWithIDTieBreak() {
        let tied = [
            ActionDescriptor(id: "b", title: "Format"),
            ActionDescriptor(id: "a", title: "Format"),
        ]
        XCTAssertEqual(CommandMatcher.rank("format", actions: tied).map(\.actionID), ["a", "b"])
        let ranked = CommandMatcher.rank("copy markdown upper", actions: actions)
        XCTAssertEqual(ranked.map(\.score), ranked.map(\.score).sorted(by: >))
    }

    func testConfidentMatch() {
        XCTAssertEqual(CommandMatcher.confidentMatch("uppercase it", actions: actions), "uppercase")
        XCTAssertNil(CommandMatcher.confidentMatch("translate to french", actions: actions))
        XCTAssertNil(CommandMatcher.confidentMatch("parse this json", actions: actions))
    }

    func testConfidentMatchRequiresClearWinner() {
        let tied = [
            ActionDescriptor(id: "a", title: "Format"),
            ActionDescriptor(id: "b", title: "Format"),
        ]
        XCTAssertNil(CommandMatcher.confidentMatch("format", actions: tied))
    }
}
