import CryptoKit
import Foundation
import GRDB

private struct SQLiteMigrationBatchImportRequest {
    let rows: [SQLiteMigrationExpectedRow]
    let runID: String
    let batchSize: Int
    let store: SQLiteLibraryStore
    let date: Date
    let progress: (@Sendable (SQLiteMigrationBatchResult) async -> Void)?
}

enum SQLiteMigrationImportSupport {
    static let dependencyOrder: [SQLiteMigrationSourceEntity] = [
        .recordings,
        .transcripts,
        .summaries,
        .processingJobs,
        .archiveLocations,
        .pendingCloudMutations
    ]

    static func orderedRows(
        _ rows: [SQLiteMigrationExpectedRow]
    ) -> [SQLiteMigrationExpectedRow] {
        rows.sorted { lhs, rhs in
            let lhsOrder = dependencyOrder.firstIndex(of: lhs.entity) ?? dependencyOrder.count
            let rhsOrder = dependencyOrder.firstIndex(of: rhs.entity) ?? dependencyOrder.count
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            if lhs.entity != rhs.entity {
                return lhs.entity.rawValue < rhs.entity.rawValue
            }
            if lhs.destinationStorageID != rhs.destinationStorageID {
                return lhs.destinationStorageID < rhs.destinationStorageID
            }
            return lhs.sourceObjectID < rhs.sourceObjectID
        }
    }

    static func validate(
        snapshot: SQLiteMigrationSourceSnapshot
    ) throws {
        guard !snapshot.sourceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteMigrationImportError.invalidSnapshot("source model must not be empty")
        }
        guard !snapshot.sourceFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            throw SQLiteMigrationImportError.invalidSnapshot(
                "source fingerprint must not be empty"
            )
        }
        try validate(rows: snapshot.rows)
    }

    static func validate(
        rows: [SQLiteMigrationExpectedRow]
    ) throws {
        var sourceIDsByEntity = [SQLiteMigrationSourceEntity: Set<String>]()
        var destinationIDsByEntity = [SQLiteMigrationSourceEntity: Set<String>]()

        for row in rows {
            guard !row.sourceObjectID.isEmpty else {
                throw SQLiteMigrationImportError.invalidSnapshot(
                    "\(row.entity.rawValue) has an empty source object ID"
                )
            }
            guard !row.destinationStorageID.isEmpty else {
                throw SQLiteMigrationImportError.invalidSnapshot(
                    "\(row.entity.rawValue) has an empty destination storage ID"
                )
            }
            guard Set(row.values.keys) == row.entity.destinationColumns,
                  row.values["storageID"] == .text(row.destinationStorageID) else {
                throw SQLiteMigrationImportError.invalidSnapshot(
                    "\(row.entity.rawValue) does not declare every destination column"
                )
            }

            var sourceIDs = sourceIDsByEntity[row.entity, default: []]
            guard sourceIDs.insert(row.sourceObjectID).inserted else {
                throw SQLiteMigrationImportError.invalidSnapshot(
                    "duplicate source object ID in \(row.entity.rawValue)"
                )
            }
            sourceIDsByEntity[row.entity] = sourceIDs

            var destinationIDs = destinationIDsByEntity[row.entity, default: []]
            guard destinationIDs.insert(row.destinationStorageID).inserted else {
                throw SQLiteMigrationImportError.invalidSnapshot(
                    "duplicate destination storage ID in \(row.entity.rawValue)"
                )
            }
            destinationIDsByEntity[row.entity] = destinationIDs
        }
    }

    static func batchSHA256(
        rows: [SQLiteMigrationExpectedRow]
    ) -> String {
        let canonical = orderedRows(rows).map { row in
            let values = row.values.keys.sorted().map { column in
                "\(column)=\(canonicalValue(row.values[column]!))"
            }.joined(separator: "|")
            return [
                row.entity.rawValue,
                row.sourceObjectID,
                row.destinationStorageID,
                values
            ].joined(separator: "\n")
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func batchCursor(
        rows: [SQLiteMigrationExpectedRow]
    ) -> Data? {
        guard let lastRow = orderedRows(rows).last else {
            return nil
        }
        let cursor = [
            lastRow.entity.rawValue,
            lastRow.sourceObjectID,
            lastRow.destinationStorageID
        ].joined(separator: "|")
        return Data(cursor.utf8)
    }

    static func canonicalValue(_ value: SQLiteMigrationValue) -> String {
        switch value {
        case .null:
            return "null"
        case .text(let value):
            return "text:\(value)"
        case .integer(let value):
            return "integer:\(value)"
        case .real(let value):
            return "real:\(value)"
        case .blob(let value):
            return "blob:\(value.base64EncodedString())"
        case .boolean(let value):
            return "boolean:\(value ? 1 : 0)"
        }
    }

    static func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

struct SQLiteMigrationMetadataImporter: Sendable {
    static let version = "metadata-importer-v1"

    static func importSnapshot(
        _ snapshot: SQLiteMigrationSourceSnapshot,
        into store: SQLiteLibraryStore,
        batchSize: Int = 100,
        runID: String? = nil,
        at date: Date = Date(),
        progress: (@Sendable (SQLiteMigrationBatchResult) async -> Void)? = nil
    ) async throws -> SQLiteMigrationImportResult {
        guard batchSize > 0 else {
            throw SQLiteMigrationImportError.invalidSnapshot(
                "batch size must be greater than zero"
            )
        }
        guard snapshot.migrationRunID == nil else {
            throw SQLiteMigrationImportError.invalidSnapshot(
                "source snapshot must not contain a destination migration run ID"
            )
        }
        try SQLiteMigrationImportSupport.validate(snapshot: snapshot)

        let orderedRows = SQLiteMigrationImportSupport.orderedRows(snapshot.rows)
        let run = try await resolveRun(
            snapshot: snapshot,
            runID: runID,
            store: store,
            at: date
        )
        let counts = try await importBatches(
            SQLiteMigrationBatchImportRequest(
                rows: orderedRows,
                runID: run.id,
                batchSize: batchSize,
                store: store,
                date: date,
                progress: progress
            )
        )
        try Task.checkCancellation()
        let completedRun = try await completeRun(
            runID: run.id,
            snapshotRowCount: snapshot.rows.count,
            store: store,
            at: date
        )

        return SQLiteMigrationImportResult(
            run: completedRun,
            importedRowCount: counts.importedRowCount,
            skippedRowCount: counts.skippedRowCount
        )
    }

    private static func resolveRun(
        snapshot: SQLiteMigrationSourceSnapshot,
        runID: String?,
        store: SQLiteLibraryStore,
        at date: Date
    ) async throws -> SQLiteMigrationRun {
        if let runID {
            guard let existingRun = try await store.migrationRun(id: runID) else {
                throw SQLiteMigrationImportError.runNotFound(runID)
            }
            try validateRun(
                existingRun,
                snapshot: snapshot,
                expectedMetadataTotal: snapshot.rows.count
            )
            return existingRun
        }
        return try await store.beginMigrationRun(
            sourceFingerprint: snapshot.sourceFingerprint,
            importerVersion: version,
            sourceModel: snapshot.sourceModel,
            metadataTotal: snapshot.rows.count,
            at: date
        )
    }

    private static func importBatches(
        _ request: SQLiteMigrationBatchImportRequest
    ) async throws -> (importedRowCount: Int, skippedRowCount: Int) {
        var importedRowCount = 0
        var skippedRowCount = 0
        for batch in batches(request.rows, size: request.batchSize) {
            try Task.checkCancellation()
            let result = try await request.store.importMetadataBatch(
                runID: request.runID,
                rows: batch,
                at: request.date
            )
            importedRowCount += result.importedRowCount
            skippedRowCount += result.skippedRowCount
            await request.progress?(result)
        }
        return (importedRowCount, skippedRowCount)
    }

    private static func completeRun(
        runID: String,
        snapshotRowCount: Int,
        store: SQLiteLibraryStore,
        at date: Date
    ) async throws -> SQLiteMigrationRun {
        guard let currentRun = try await store.migrationRun(id: runID) else {
            throw SQLiteMigrationImportError.runNotFound(runID)
        }
        guard currentRun.metadataCompleted == snapshotRowCount else {
            throw SQLiteMigrationImportError.incompleteImport(
                expected: snapshotRowCount,
                actual: currentRun.metadataCompleted
            )
        }
        guard currentRun.status != "completed" else {
            return currentRun
        }
        return try await store.checkpointMigrationRun(
            id: currentRun.id,
            phase: "metadata",
            status: "completed",
            metadataCompleted: currentRun.metadataCompleted,
            batchCursor: currentRun.batchCursor,
            batchCount: currentRun.batchCount,
            batchSHA256: currentRun.batchSHA256,
            at: date
        )
    }

    private static func validateRun(
        _ run: SQLiteMigrationRun,
        snapshot: SQLiteMigrationSourceSnapshot,
        expectedMetadataTotal: Int
    ) throws {
        guard run.sourceFingerprint == snapshot.sourceFingerprint else {
            throw SQLiteMigrationImportError.runConfigurationMismatch(
                "source fingerprint differs"
            )
        }
        guard run.importerVersion == version else {
            throw SQLiteMigrationImportError.runConfigurationMismatch(
                "importer version differs"
            )
        }
        guard run.sourceModel == snapshot.sourceModel else {
            throw SQLiteMigrationImportError.runConfigurationMismatch(
                "source model differs"
            )
        }
        guard run.metadataTotal == expectedMetadataTotal else {
            throw SQLiteMigrationImportError.runConfigurationMismatch(
                "metadata total differs"
            )
        }
    }

    private static func batches(
        _ rows: [SQLiteMigrationExpectedRow],
        size: Int
    ) -> [[SQLiteMigrationExpectedRow]] {
        guard !rows.isEmpty else {
            return []
        }
        return stride(from: 0, to: rows.count, by: size).map { start in
            Array(rows[start..<min(start + size, rows.count)])
        }
    }
}
