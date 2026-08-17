import XCTest
@testable import BisonNotes_AI

private enum Swift6ValueSemanticsTestError: Error {
    case expected
}

final class Swift6ValueSemanticsTests: XCTestCase {
    func testStructuredResponseSchemaRoundTripsWithTheProviderWireShape() throws {
        let responseFormat = ResponseFormat.completeResponseSchema
        let encoded = try JSONEncoder().encode(responseFormat)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let jsonSchema = try XCTUnwrap(object["json_schema"] as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "json_schema")
        XCTAssertEqual(jsonSchema["name"] as? String, "complete_response")
        XCTAssertEqual(jsonSchema["strict"] as? Bool, true)

        let decoded = try JSONDecoder().decode(ResponseFormat.self, from: encoded)
        XCTAssertEqual(decoded.type, responseFormat.type)
        XCTAssertEqual(decoded.jsonSchema?.name, responseFormat.jsonSchema?.name)
        XCTAssertEqual(decoded.jsonSchema?.schema, responseFormat.jsonSchema?.schema)
        XCTAssertEqual(decoded.jsonSchema?.strict, responseFormat.jsonSchema?.strict)
    }

    func testProviderRequestModelsAreTransferableValueContracts() {
        let request = ChatCompletionRequest(
            model: "test-model",
            messages: [ChatMessage(role: "user", content: "Summarize this.")],
            responseFormat: .json
        )

        let transferred = acceptSendable(request)
        XCTAssertEqual(transferred.model, "test-model")
        XCTAssertEqual(transferred.responseFormat?.type, "json_object")
        XCTAssertEqual(transferred.messages.first?.content, "Summarize this.")
    }

    func testTimeoutReturnsCompletedSendableValue() async throws {
        let result = try await withTimeout(seconds: 1) {
            "completed"
        }

        XCTAssertEqual(result, "completed")
    }

    func testTimeoutPreservesTheCallerProvidedError() async {
        do {
            _ = try await withTimeout(
                seconds: 0.01,
                timeoutError: Swift6ValueSemanticsTestError.expected
            ) {
                try await Task.sleep(nanoseconds: 100_000_000)
                return "late"
            }
            XCTFail("Expected the timeout error")
        } catch Swift6ValueSemanticsTestError.expected {
            // The timeout error is preserved for callers to classify.
        } catch {
            XCTFail("Unexpected timeout error: \(error)")
        }
    }

    private func acceptSendable<T: Sendable>(_ value: T) -> T {
        value
    }
}
