import Testing
@testable import Vox

struct ClaudeAPIServiceTests {
    @Test func parseContentDelta() throws {
        let line = """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Привет"}}
        """
        let result = ClaudeAPIService.parseSSELine(line)
        #expect(result == "Привет")
    }

    @Test func parseNonDeltaLine() {
        let line = "data: {\"type\":\"message_start\"}"
        let result = ClaudeAPIService.parseSSELine(line)
        #expect(result == nil)
    }

    @Test func parseEmptyLine() {
        let result = ClaudeAPIService.parseSSELine("")
        #expect(result == nil)
    }

    @Test func parseEventLine() {
        let result = ClaudeAPIService.parseSSELine("event: content_block_delta")
        #expect(result == nil)
    }

    @Test func buildRequest() throws {
        let request = try ClaudeAPIService.buildRequest(
            text: "Hello",
            model: .haiku,
            apiKey: "sk-test"
        )
        #expect(request.url == Constants.apiURL)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == Constants.apiVersion)
    }

    // MARK: - extractJSON

    @Test func extractJSON_rawJSON_returnedUnchanged() {
        let input = #"{"a":1}"#
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"a":1}"#)
    }

    @Test func extractJSON_rawJSONWithSurroundingWhitespace() {
        let input = "\n\t " + #"{"a":1}"# + " \n"
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"a":1}"#)
    }

    @Test func extractJSON_fenceWithJSONTag() {
        let input = "```json\n" + #"{"a":1}"# + "\n```"
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"a":1}"#)
    }

    @Test func extractJSON_fenceNoTag() {
        let input = "```\n" + #"{"a":1}"# + "\n```"
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"a":1}"#)
    }

    @Test func extractJSON_fenceMissingClose() {
        let input = "```json\n" + #"{"a":1}"#
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"a":1}"#)
    }

    @Test func extractJSON_fenceWithTrailingGarbage() {
        let input = "```json\n" + #"{"a":1}"# + "\n```\nprose here"
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"a":1}"#)
    }

    @Test func extractJSON_textBeforeJSON() {
        let input = "Here you go:\n" + #"{"a":1}"#
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"a":1}"#)
    }

    // Regression: old impl used lastIndex(of: "}"), which swallowed trailing prose.
    @Test func extractJSON_textAfterJSON_withBrace() {
        let input = #"{"a":1}"# + "\nThe closing brace } ends it."
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"a":1}"#)
    }

    @Test func extractJSON_closingBraceInsideStringValue() {
        let input = #"{"note":"use } carefully"}"#
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"note":"use } carefully"}"#)
    }

    @Test func extractJSON_openingBraceInsideStringValue() {
        let input = "Intro:\n" + #"{"note":"use { carefully"}"#
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"note":"use { carefully"}"#)
    }

    // The value is a single backslash; valid JSON as-is.
    @Test func extractJSON_escapedBackslashBeforeQuote() {
        let input = #"{"a":"\\"}"#
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"a":"\\"}"#)
    }

    // Same payload with prose prefix — forces the brace-matching scanner path
    // to prove it handles \\ correctly (doesn't misread the final " as escaped).
    @Test func extractJSON_escapedBackslashBeforeQuote_viaScanner() {
        let input = "Intro\n" + #"{"a":"\\"}"#
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"a":"\\"}"#)
    }

    @Test func extractJSON_nestedObjects() {
        let input = #"{"a":{"b":{"c":1}},"d":2}"#
        #expect(ClaudeAPIService.extractJSON(from: input) == #"{"a":{"b":{"c":1}},"d":2}"#)
    }

    @Test func extractJSON_invalidInput_returnsInputUnchanged() {
        #expect(ClaudeAPIService.extractJSON(from: "not json at all") == "not json at all")
    }
}
