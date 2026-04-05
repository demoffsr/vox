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
}
