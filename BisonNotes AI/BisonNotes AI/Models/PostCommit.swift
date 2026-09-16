//
//  PostCommit.swift
//  BisonNotes AI
//

import Foundation
import os.log

/// The one wording every post-commit failure is reported with.
///
/// Pure so a test can pin that the caller's description survives into the log
/// line without writing to the app's real rolling error log, which the
/// troubleshooting export ships to the user.
///
/// Carries both forms deliberately. `localizedDescription` is what the five
/// migrated sites logged and is the readable half for `NSError`s out of Core
/// Data; the raw value is what keeps an enum case and its associated values
/// legible, where `localizedDescription` degrades to "The operation couldn't be
/// completed."
enum PostCommitLog {
    static func message(_ description: String, error: Error) -> String {
        "\(description) did not complete after its commit: "
            + "\(error.localizedDescription) (\(error))"
    }
}

/// Runs work that follows a durable commit and must not fail the operation.
///
/// By the time this runs the commit has already happened, so an error here is
/// not a failure of what the caller was doing — it is a loose end to report,
/// never to propagate. Returning the error instead of throwing it is the point:
/// a caller has to opt in to caring, and cannot leak it into a `catch` written
/// for pre-commit failures.
///
/// See docs/post-commit-convention-plan.md for the five bugs this replaces.
@discardableResult
func afterCommit(
    _ description: String,
    category: LogCategory,
    level: OSLogType = .error,
    _ body: () throws -> Void
) -> Error? {
    do {
        try body()
        return nil
    } catch {
        AppLog.shared.log(
            PostCommitLog.message(description, error: error),
            level: level,
            category: category
        )
        return error
    }
}

/// The `async` form, for post-commit work that awaits.
///
/// Not speculative API: the 0.95 progress write in `processSummarizationJob`
/// follows `createSummary` and is `async`, so without this overload that site
/// had no way to adopt the convention and kept failing a job whose summary was
/// already durable.
///
/// The `isolation` parameter keeps the body on the caller's actor. Without it
/// the closure would be sent to the generic executor, which both breaks the
/// `@MainActor` managers that need this and makes the closure non-Sendable.
@discardableResult
func afterCommit(
    _ description: String,
    category: LogCategory,
    level: OSLogType = .error,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> Void
) async -> Error? {
    do {
        try await body()
        return nil
    } catch {
        AppLog.shared.log(
            PostCommitLog.message(description, error: error),
            level: level,
            category: category
        )
        return error
    }
}
