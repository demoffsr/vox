import Testing
import AppKit
@testable import Vox

@Suite(.serialized)
struct ClipboardServiceTests {
    let service = ClipboardService()

    @Test func readStringFromClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Hello, world!", forType: .string)
        let result = service.readText()
        #expect(result == "Hello, world!")
    }

    @Test func readEmptyClipboard() {
        NSPasteboard.general.clearContents()
        let result = service.readText()
        #expect(result == nil)
    }

    @Test func readTruncatesLongText() {
        let longText = String(repeating: "A", count: Constants.maxClipboardLength + 100)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(longText, forType: .string)
        let result = service.readText()
        #expect(result?.count == Constants.maxClipboardLength)
    }
}
