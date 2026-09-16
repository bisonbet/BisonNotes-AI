//
//  PostCommitTests.swift
//  BisonNotes AITests
//

import XCTest
@testable import BisonNotes_AI

final class PostCommitTests: XCTestCase {
    private final class TestError: LocalizedError {
        let message: String

        init(_ message: String = "post-commit test failure") {
            self.message = message
        }

        var errorDescription: String? { message }
    }

    func testSuccessfulBodyRunsOnceAndReturnsNil() {
        var runCount = 0

        let returnedError = afterCommit("successful work", category: .general) {
            runCount += 1
        }

        XCTAssertNil(returnedError)
        XCTAssertEqual(runCount, 1)
    }

    func testThrowingBodyReturnsTheExactError() {
        let expectedError = TestError()

        let returnedError = afterCommit("failing work", category: .general) {
            throw expectedError
        }

        guard let returnedError else {
            return XCTFail("A throwing body must return its error")
        }
        XCTAssertTrue(
            (returnedError as AnyObject) === expectedError,
            "The helper must return the exact error instance"
        )
    }

    /// Non-propagation is a compile-time property — the helper is not `rethrows`.
    /// What is worth pinning is that a failed loose end does not stop the *next*
    /// one: each post-commit step has to be attempted on its own.
    func testAFailedStepDoesNotSkipTheNextOne() {
        var secondStepRan = false

        let firstError = afterCommit("first loose end", category: .general) {
            throw TestError()
        }
        let secondError = afterCommit("second loose end", category: .general) {
            secondStepRan = true
        }

        XCTAssertNotNil(firstError)
        XCTAssertNil(secondError)
        XCTAssertTrue(secondStepRan, "A failed post-commit step must not skip the one after it")
    }

    /// Asserts the wording through the pure formatter the helper uses. Reading
    /// `AppLog.shared.persistedErrorLog()` instead would assert against the app's
    /// real rolling error log — the same file the troubleshooting export ships —
    /// and leave a fabricated ERROR line in it on every run.
    func testDescriptionAndErrorAppearInTheLoggedMessage() {
        let description = "PostCommitTests-\(UUID().uuidString)"
        let error = TestError("the underlying failure")

        let message = PostCommitLog.message(description, error: error)

        XCTAssertTrue(
            message.contains(description),
            "The post-commit description should be present in the logged message"
        )
        XCTAssertTrue(
            message.contains("the underlying failure"),
            "The underlying error should be present in the logged message"
        )
    }

    func testAsyncOverloadReturnsTheExactErrorAndKeepsGoing() async {
        let expectedError = TestError()
        var secondStepRan = false

        let firstError = await afterCommit("awaiting work", category: .general) {
            try await Task.sleep(for: .milliseconds(1))
            throw expectedError
        }
        let secondError = await afterCommit("later awaiting work", category: .general) {
            try await Task.sleep(for: .milliseconds(1))
            secondStepRan = true
        }

        XCTAssertTrue(
            (firstError as AnyObject?) === expectedError,
            "The async overload must return the exact error instance"
        )
        XCTAssertNil(secondError)
        XCTAssertTrue(secondStepRan, "A failed async post-commit step must not skip the one after it")
    }
}
