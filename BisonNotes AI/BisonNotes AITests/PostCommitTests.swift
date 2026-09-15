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

    func testThrowingBodyDoesNotPreventTheEnclosingScopeFromContinuing() {
        var reachedAfterCommit = false

        afterCommit("non-propagating work", category: .general) {
            throw TestError()
        }
        reachedAfterCommit = true

        XCTAssertTrue(reachedAfterCommit)
    }

    func testDescriptionAppearsInLoggedContext() async {
        let description = "PostCommitTests-\(UUID().uuidString)"

        _ = afterCommit(description, category: .general) {
            throw TestError()
        }

        let deadline = Date().addingTimeInterval(1)
        var persistedLog = ""
        while Date() < deadline {
            persistedLog = AppLog.shared.persistedErrorLog()
            if persistedLog.contains(description) {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(
            persistedLog.contains(description),
            "The post-commit description should be present in the persisted error log"
        )
    }
}
