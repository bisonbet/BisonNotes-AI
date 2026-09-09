import Foundation
import GRDB

extension SQLiteLibraryStore {
    func currentLibraryRevision() throws -> Int64 {
        try databaseQueue.read { database in
            guard let revision = try Int64.fetchOne(
                database,
                sql: "SELECT revision FROM library_metadata WHERE id = 1"
            ), revision >= 0 else {
                throw SQLiteLibraryStoreError.invalidMetadata
            }
            return revision
        }
    }

    func libraryChanges(since revision: Int64) throws -> [LibraryChange] {
        guard revision >= 0 else {
            throw LibraryObservationError.invalidCursor(revision)
        }

        return try databaseQueue.read { database in
            guard let currentRevision = try Int64.fetchOne(
                database,
                sql: "SELECT revision FROM library_metadata WHERE id = 1"
            ), currentRevision >= 0 else {
                throw SQLiteLibraryStoreError.invalidMetadata
            }
            guard revision <= currentRevision else {
                throw LibraryObservationError.cursorAhead(
                    current: currentRevision,
                    requested: revision
                )
            }

            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT revision, entity, storageID, operation, committedAt
                FROM library_changes
                WHERE revision > ?
                ORDER BY revision
                """,
                arguments: [revision]
            )
            return try Self.validatedChanges(
                from: rows,
                after: revision,
                through: currentRevision
            )
        }
    }

    private static func validatedChanges(
        from rows: [Row],
        after revision: Int64,
        through currentRevision: Int64
    ) throws -> [LibraryChange] {
        var expectedRevision = revision
        var changes: [LibraryChange] = []
        for row in rows {
            guard expectedRevision < Int64.max else {
                throw LibraryObservationError.invalidStoredChange(
                    revision: expectedRevision
                )
            }
            let change = try libraryChange(from: row)
            let nextRevision = expectedRevision + 1
            guard change.revision == nextRevision else {
                throw LibraryObservationError.missingStoredChange(
                    revision: nextRevision
                )
            }
            changes.append(change)
            expectedRevision = change.revision
        }
        guard expectedRevision == currentRevision else {
            throw LibraryObservationError.missingStoredChange(
                revision: expectedRevision + 1
            )
        }
        return changes
    }

    static func recordChange(
        in database: Database,
        entity: LibraryChangeEntity,
        storageID: String,
        operation: LibraryChangeOperation,
        at date: Date
    ) throws -> Int64 {
        guard !storageID.isEmpty else {
            throw LibraryObservationError.invalidStoredChange(revision: 0)
        }
        let committedAt = date.timeIntervalSinceReferenceDate
        guard committedAt.isFinite else {
            throw LibraryObservationError.invalidStoredChange(revision: 0)
        }

        try database.execute(
            sql: """
            UPDATE library_metadata
            SET revision = revision + 1, updatedAt = ?
            WHERE id = 1
            """,
            arguments: [committedAt]
        )
        guard database.changesCount == 1,
              let revision = try Int64.fetchOne(
                  database,
                  sql: "SELECT revision FROM library_metadata WHERE id = 1"
              ), revision > 0 else {
            throw SQLiteLibraryStoreError.invalidMetadata
        }

        try database.execute(
            sql: """
            INSERT INTO library_changes (
                revision, entity, storageID, operation, committedAt
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [
                revision,
                entity.rawValue,
                storageID,
                operation.rawValue,
                committedAt
            ]
        )
        return revision
    }

    private static func libraryChange(from row: Row) throws -> LibraryChange {
        guard let revision: Int64 = row["revision"],
              revision > 0,
              let entityRawValue: String = row["entity"],
              let entity = LibraryChangeEntity(rawValue: entityRawValue),
              let storageID: String = row["storageID"],
              !storageID.isEmpty,
              let operationRawValue: String = row["operation"],
              let operation = LibraryChangeOperation(rawValue: operationRawValue),
              let committedAt: Double = row["committedAt"],
              committedAt.isFinite else {
            let revision: Int64 = row["revision"] ?? 0
            throw LibraryObservationError.invalidStoredChange(revision: revision)
        }

        return LibraryChange(
            revision: revision,
            entity: entity,
            storageID: storageID,
            operation: operation,
            committedAt: Date(timeIntervalSinceReferenceDate: committedAt)
        )
    }
}
