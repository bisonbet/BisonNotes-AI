import Foundation

/// Owns a durable observation cursor for one consumer.
///
/// The cursor is anchored before the caller reads its initial repository
/// snapshot. Any commit that lands while that snapshot is being read is then
/// returned by the first poll instead of being lost between the snapshot and a
/// later `currentRevision()` call. The value is deliberately mutable and
/// caller-owned so one subscription cannot be polled concurrently by multiple
/// tasks and deliver the same batch twice.
struct LibraryObservationSubscription: Sendable {
    private let observation: any LibraryObservation
    private(set) var cursor: Int64
    private(set) var isCancelled = false

    init(
        observation: any LibraryObservation,
        startingRevision: Int64 = 0
    ) throws {
        guard startingRevision >= 0 else {
            throw LibraryObservationError.invalidCursor(startingRevision)
        }
        self.observation = observation
        self.cursor = startingRevision
    }

    /// Captures the revision before the initial snapshot is read.
    static func anchored(
        to observation: any LibraryObservation
    ) async throws -> LibraryObservationSubscription {
        let revision = try await observation.currentRevision()
        return try LibraryObservationSubscription(
            observation: observation,
            startingRevision: revision
        )
    }

    /// Returns committed changes after the current cursor and advances only
    /// after the entire batch is validated. Empty polls leave the cursor
    /// unchanged; callers may invoke this when a platform notification or
    /// lifecycle event indicates that new work may exist.
    mutating func poll() async throws -> [LibraryChange] {
        guard !isCancelled else { return [] }

        let changes = try await observation.changes(since: cursor)
        var nextCursor = cursor
        for change in changes {
            guard nextCursor < Int64.max else {
                throw LibraryObservationError.invalidStoredChange(revision: nextCursor)
            }
            let expectedRevision = nextCursor + 1
            guard change.revision == expectedRevision else {
                throw LibraryObservationError.missingStoredChange(
                    revision: expectedRevision
                )
            }
            nextCursor = change.revision
        }
        cursor = nextCursor
        return changes
    }

    mutating func cancel() {
        isCancelled = true
    }
}
