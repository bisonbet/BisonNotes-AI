import Foundation
import GRDB

private struct SQLiteMigrationBatchCheckpointInput {
    let rows: [SQLiteMigrationExpectedRow]
    let runID: String
    let existingRun: SQLiteMigrationRun
    let counts: (importedRowCount: Int, skippedRowCount: Int)
    let timestamp: Double
}

extension SQLiteLibraryStore {
    func importMetadataBatch(
        runID: String,
        rows: [SQLiteMigrationExpectedRow],
        at date: Date = Date()
    ) throws -> SQLiteMigrationBatchResult {
        guard !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteMigrationImportError.runNotFound(runID)
        }
        guard !rows.isEmpty else {
            throw SQLiteMigrationImportError.invalidSnapshot(
                "metadata batch must not be empty"
            )
        }
        try SQLiteMigrationImportSupport.validate(rows: rows)

        let orderedRows = SQLiteMigrationImportSupport.orderedRows(rows)
        let timestamp = date.timeIntervalSinceReferenceDate
        return try databaseQueue.write { database in
            guard let existingRun = try SQLiteMigrationStoreSupport.fetchRun(
                id: runID,
                from: database
            ) else {
                throw SQLiteMigrationImportError.runNotFound(runID)
            }

            let counts = try importRows(
                orderedRows,
                runID: runID,
                existingRun: existingRun,
                timestamp: timestamp,
                in: database
            )
            guard counts.importedRowCount > 0 else {
                return SQLiteMigrationBatchResult(
                    run: existingRun,
                    importedRowCount: 0,
                    skippedRowCount: counts.skippedRowCount
                )
            }
            return try checkpointImportedBatch(
                SQLiteMigrationBatchCheckpointInput(
                    rows: orderedRows,
                    runID: runID,
                    existingRun: existingRun,
                    counts: counts,
                    timestamp: timestamp
                ),
                in: database
            )
        }
    }

    private func checkpointImportedBatch(
        _ input: SQLiteMigrationBatchCheckpointInput,
        in database: Database
    ) throws -> SQLiteMigrationBatchResult {
        let metadataCompleted = try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM migration_row_map WHERE runID = ?",
            arguments: [input.runID]
        ) ?? 0
        let nextBatchCount = input.existingRun.batchCount + 1
        try SQLiteMigrationStoreSupport.validateProgress(
            phase: "metadata",
            status: "running",
            metadataTotal: input.existingRun.metadataTotal,
            metadataCompleted: metadataCompleted,
            batchCount: nextBatchCount
        )
        try database.execute(
            sql: """
            UPDATE migration_runs
            SET phase = ?,
                status = ?,
                metadataCompleted = ?,
                batchCursor = ?,
                batchCount = ?,
                batchSHA256 = ?,
                updatedAt = ?,
                errorMessage = NULL
            WHERE id = ?
            """,
            arguments: [
                "metadata",
                "running",
                metadataCompleted,
                SQLiteMigrationImportSupport.batchCursor(rows: input.rows),
                nextBatchCount,
                SQLiteMigrationImportSupport.batchSHA256(rows: input.rows),
                input.timestamp,
                input.runID
            ]
        )

        guard let updatedRun = try SQLiteMigrationStoreSupport.fetchRun(
            id: input.runID,
            from: database
        ) else {
            throw SQLiteLibraryStoreError.invalidMetadata
        }
        return SQLiteMigrationBatchResult(
            run: updatedRun,
            importedRowCount: input.counts.importedRowCount,
            skippedRowCount: input.counts.skippedRowCount
        )
    }

    private func importRows(
        _ rows: [SQLiteMigrationExpectedRow],
        runID: String,
        existingRun: SQLiteMigrationRun,
        timestamp: Double,
        in database: Database
    ) throws -> (importedRowCount: Int, skippedRowCount: Int) {
        var importedRowCount = 0
        var skippedRowCount = 0
        for row in rows {
            let existingMap = try Row.fetchOne(
                database,
                sql: """
                SELECT destinationStorageID
                FROM migration_row_map
                WHERE runID = ? AND sourceEntity = ? AND sourceObjectID = ?
                """,
                arguments: [runID, row.entity.rawValue, row.sourceObjectID]
            )

            if let existingMap {
                try validateMappedRow(
                    existingMap,
                    row: row,
                    in: database
                )
                skippedRowCount += 1
                continue
            }

            guard existingRun.status != "completed",
                  existingRun.status != "failed" else {
                throw SQLiteMigrationImportError.runNotResumable(
                    "the run is already \(existingRun.status)"
                )
            }
            try ensureDestinationRowIsFree(row, in: database)
            try insertDestinationRow(row, into: database)
            try database.execute(
                sql: """
                INSERT INTO migration_row_map (
                    runID, sourceEntity, sourceObjectID, destinationStorageID,
                    sourceURI, createdAt
                )
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    runID,
                    row.entity.rawValue,
                    row.sourceObjectID,
                    row.destinationStorageID,
                    nil,
                    timestamp
                ]
            )
            importedRowCount += 1
        }
        return (importedRowCount, skippedRowCount)
    }

    private func validateMappedRow(
        _ existingMap: Row,
        row: SQLiteMigrationExpectedRow,
        in database: Database
    ) throws {
        let mappedStorageID: String? = existingMap["destinationStorageID"]
        guard mappedStorageID == row.destinationStorageID else {
            throw SQLiteMigrationImportError.sourceRowConflict(
                entity: row.entity,
                sourceObjectID: row.sourceObjectID,
                detail: "row map points to a different destination storage ID"
            )
        }
        guard let destinationRow = try Row.fetchOne(
            database,
            sql: """
            SELECT * FROM \(SQLiteMigrationImportSupport.quoteIdentifier(row.entity.rawValue))
            WHERE storageID = ?
            """,
            arguments: [row.destinationStorageID]
        ) else {
            throw SQLiteMigrationImportError.destinationRowConflict(
                entity: row.entity,
                storageID: row.destinationStorageID,
                detail: "row map exists but destination row is missing"
            )
        }
        try validateDestinationRow(destinationRow, against: row)
    }

    private func ensureDestinationRowIsFree(
        _ row: SQLiteMigrationExpectedRow,
        in database: Database
    ) throws {
        let destinationExists = try Bool.fetchOne(
            database,
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM \(SQLiteMigrationImportSupport.quoteIdentifier(row.entity.rawValue))
                WHERE storageID = ?
            )
            """,
            arguments: [row.destinationStorageID]
        ) ?? false
        guard !destinationExists else {
            throw SQLiteMigrationImportError.destinationRowConflict(
                entity: row.entity,
                storageID: row.destinationStorageID,
                detail: "destination row exists without a matching row map"
            )
        }
    }

    private func insertDestinationRow(
        _ row: SQLiteMigrationExpectedRow,
        into database: Database
    ) throws {
        let columns = row.values.keys.sorted()
        let quotedColumns = columns
            .map(SQLiteMigrationImportSupport.quoteIdentifier)
            .joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count)
            .joined(separator: ", ")
        let arguments = StatementArguments(
            columns.map { row.values[$0]!.databaseValue }
        )
        try database.execute(
            sql: """
            INSERT INTO \(SQLiteMigrationImportSupport.quoteIdentifier(row.entity.rawValue))
            (\(quotedColumns)) VALUES (\(placeholders))
            """,
            arguments: arguments
        )
    }

    private func validateDestinationRow(
        _ destinationRow: Row,
        against expectedRow: SQLiteMigrationExpectedRow
    ) throws {
        for column in expectedRow.entity.destinationColumns.sorted() {
            guard let expectedValue = expectedRow.values[column] else {
                throw SQLiteMigrationImportError.invalidSnapshot(
                    "\(expectedRow.entity.rawValue) row is missing column \(column)"
                )
            }
            let actualValue = SQLiteMigrationValue(
                databaseValue: destinationRow[column] as DatabaseValue
            )
            guard expectedValue.databaseValue == actualValue.databaseValue else {
                throw SQLiteMigrationImportError.destinationRowConflict(
                    entity: expectedRow.entity,
                    storageID: expectedRow.destinationStorageID,
                    detail: "column \(column) differs from the source snapshot"
                )
            }
        }
    }
}
