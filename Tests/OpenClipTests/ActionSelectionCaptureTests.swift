import AppKit
import XCTest
@testable import Core
@testable import OpenClip

@MainActor
final class ActionSelectionCaptureTests: XCTestCase {
    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("com.openclip.rich-input.\(UUID().uuidString)"))
        board.setString("User clipboard", forType: .string)
        return board
    }

    func testReadingViewCapturesRTFFromHTMLAndRestoresClipboard() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let selection = SelectionContext(text: "Styled text", sourceApp: AppIdentity(bundleIdentifier: "md.obsidian", processIdentifier: 99999),
                                         selectionGeneration: 5, isEditable: false)
        let capture = ActionSelectionCapture(
            isSelectionCurrent: { $0.selectionGeneration == 5 }, frontmostPID: { 99999 }, activateSource: { _ in true },
            pasteboard: board, postCopy: {
                board.clearContents()
                board.setString("Styled text", forType: .string)
                board.setString("<b>Styled text</b>", forType: .html)
            }
        )
        let enriched = try await capture.capture(selection)
        XCTAssertEqual(enriched.text, selection.text)
        XCTAssertEqual(enriched.selectionGeneration, 5)
        XCTAssertEqual(enriched.isEditable, false)
        XCTAssertEqual(enriched.html, "<b>Styled text</b>")
        XCTAssertTrue(enriched.rtf?.contains("\\rtf") == true)
        XCTAssertEqual(board.string(forType: .string), "User clipboard")
    }

    func testQueuedCaptureRejectsAChangedSourceBeforePosting() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let lease = try await OpenSelection.ClipboardCoordinator.shared.acquireSession(priority: .userAction, pasteboard: board)
        var activated = false
        var pid: pid_t = 99999
        var copies = 0
        let capture = ActionSelectionCapture(frontmostPID: { pid }, activateSource: { _ in activated = true; return true },
                                             pasteboard: board, postCopy: { copies += 1 })
        let selection = SelectionContext(text: "Original selection", sourceApp: AppIdentity(bundleIdentifier: "md.obsidian", processIdentifier: 99999))
        let task = Task { try await capture.capture(selection) }
        while !activated { await Task.yield() }
        pid = 88888
        lease.commitPermanent()
        do {
            _ = try await task.value
            XCTFail("A changed source must not reach the extension")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The source selection is no longer available.")
        }
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(board.string(forType: .string), "User clipboard")
    }

    func testFactoryCapturesOnPerformAndExposesRTFToJavaScript() async throws {
        var captures = 0
        let factory = DefaultActionFactory(captureRichSelection: { selection in
            captures += 1
            return selection.withRichContent(html: nil, rtf: "{\\rtf1 Styled}", flavors: [])
        })
        let metadata = ExtensionActionMetadata(title: "Use RTF", type: "javascript", scriptCode: "return openclip.input.rtf;",
                                               captureRtf: true)
        let manifest = ExtensionMetadata(identifier: "test.rich-input", name: "Rich input", actions: [metadata])
        let optional = await factory.createAction(metadata: metadata, manifest: manifest,
                                                  directoryURL: FileManager.default.temporaryDirectory, index: 0)
        let action = try XCTUnwrap(optional)
        let context = ActionContext(selection: SelectionContext(text: "Styled"))
        XCTAssertTrue(action.isEnabled(for: context))
        XCTAssertEqual(captures, 0, "Discovery and visibility must not trigger clipboard operations")
        let result = try await action.perform(context)
        guard case .text(let text) = result else { return XCTFail("Expected the runtime's RTF input") }
        XCTAssertEqual(text, "{\\rtf1 Styled}")
        XCTAssertEqual(captures, 1)
    }

    func testExistingRTFAndOCRSkipCapture() async throws {
        let factory = DefaultActionFactory(captureRichSelection: { _ in
            XCTFail("No source Copy is needed")
            throw CancellationError()
        })
        let metadata = ExtensionActionMetadata(title: "Use RTF", type: "javascript", scriptCode: "return openclip.input.rtf;", captureRtf: true)
        let manifest = ExtensionMetadata(identifier: "test.rich-input", actions: [metadata])
        let optional = await factory.createAction(metadata: metadata, manifest: manifest,
                                                  directoryURL: FileManager.default.temporaryDirectory, index: 0)
        let action = try XCTUnwrap(optional)
        for selection in [SelectionContext(text: "Styled", rtf: "{\\rtf1 Styled}"), SelectionContext(text: "OCR", source: .ocr)] {
            _ = try await action.perform(ActionContext(selection: selection))
        }
    }

    func testHTMLCaptureAlsoReachesNonJavaScriptActions() async throws {
        let factory = DefaultActionFactory(captureRichSelection: { selection in
            selection.withRichContent(html: "<b>Styled</b>", rtf: nil, flavors: [])
        })
        let metadata = ExtensionActionMetadata(title: "HTML snippet", type: "textsnippet", scriptCode: "{html}", captureHtml: true)
        let manifest = ExtensionMetadata(identifier: "test.rich-html", actions: [metadata])
        let optional = await factory.createAction(metadata: metadata, manifest: manifest,
                                                  directoryURL: FileManager.default.temporaryDirectory, index: 0)
        let result = try await XCTUnwrap(optional).perform(ActionContext(selection: SelectionContext(text: "Styled")))
        guard case .text(let html) = result else { return XCTFail("Expected enriched HTML in the snippet") }
        XCTAssertEqual(html, "<b>Styled</b>")
    }

    func testCaptureFlagsRoundTripAndInlineCaptureIsRejected() throws {
        let metadata = ExtensionActionMetadata(title: "Use RTF", type: "javascript", scriptCode: "return openclip.input.rtf;",
                                               inline: true, captureRtf: true, captureHtml: true)
        let decoded = try JSONDecoder().decode(ExtensionActionMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(decoded.captureRtf, true)
        XCTAssertEqual(decoded.captureHtml, true)
        let manifest = ExtensionMetadata(identifier: "test.rich", actions: [decoded])
        XCTAssertTrue(ManifestValidator.validate(manifest).contains { $0.kind == .invalidInlineAction })
    }
}
