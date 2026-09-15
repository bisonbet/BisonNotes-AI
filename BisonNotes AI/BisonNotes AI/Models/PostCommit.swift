//
//  PostCommit.swift
//  BisonNotes AI
//

import Foundation
import os.log

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
            "\(description) did not complete after its commit: \(error)",
            level: level,
            category: category
        )
        return error
    }
}
