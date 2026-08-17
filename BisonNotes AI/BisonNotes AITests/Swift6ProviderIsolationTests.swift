import XCTest
@testable import BisonNotes_AI

final class Swift6ProviderIsolationTests: XCTestCase {
    func testPromptGeneratorAndParserRemainStateless() throws {
        let prompt = ChatCompletionPromptGenerator.createSystemPrompt(
            for: .summary,
            contentType: .general
        )
        XCTAssertFalse(prompt.isEmpty)

        let json = """
        {
          "summary": "A concise summary.",
          "tasks": [{"text": "Send the follow-up", "priority": "high", "category": "email"}],
          "reminders": [],
          "titles": [{"text": "Follow-Up Planning", "category": "general", "confidence": 0.9}]
        }
        """

        let parsed = try ChatCompletionResponseParser.parseCompleteResponseFromJSON(json)
        XCTAssertEqual(parsed.summary, "A concise summary.")
        XCTAssertEqual(parsed.tasks.count, 1)
        XCTAssertEqual(parsed.titles.count, 1)
    }

    func testProviderAndOnDeviceValueTypesAreSendable() {
        let values: [any Sendable] = [
            OllamaConfig(
                serverURL: "http://localhost",
                port: 11434,
                modelName: "llama3.2",
                maxTokens: 2_048,
                temperature: 0.1,
                maxContextTokens: 4_096,
                timeoutInterval: 30
            ),
            LLMChat(role: .user, content: "test"),
            InferenceMetrics(),
            OnDeviceLLMConfig()
        ]

        XCTAssertEqual(values.count, 4)
    }
}
