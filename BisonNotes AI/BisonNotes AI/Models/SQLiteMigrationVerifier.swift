import Foundation
import GRDB

enum SQLiteMigrationVerifier {
    static func verify(
        snapshot: SQLiteMigrationSourceSnapshot,
        databaseURL: URL,
        fileManager: FileManager = .default
    ) throws -> SQLiteMigrationVerificationReport {
        guard databaseURL.isFileURL, !databaseURL.path.isEmpty else {
            throw SQLiteMigrationVerificationError.invalidDatabaseURL
        }
        let normalizedURL = databaseURL.standardizedFileURL
        guard fileManager.fileExists(atPath: normalizedURL.path) else {
            throw SQLiteMigrationVerificationError.databaseNotFound(normalizedURL)
        }

        var configuration = Configuration()
        configuration.label = "BisonNotes.SQLiteMigrationVerifier"
        configuration.readonly = true
        let database = try DatabaseQueue(path: normalizedURL.path, configuration: configuration)
        return try database.read { sqliteDatabase in
            try verify(snapshot: snapshot, in: sqliteDatabase)
        }
    }

    private static func verify(
        snapshot: SQLiteMigrationSourceSnapshot,
        in database: Database
    ) throws -> SQLiteMigrationVerificationReport {
        try validate(snapshot: snapshot)
        var mismatches = [SQLiteMigrationVerificationMismatch]()
        if let migrationRunID = snapshot.migrationRunID,
           let mismatch = try verifyMigrationRun(
               id: migrationRunID,
               expectedFingerprint: snapshot.sourceFingerprint,
               in: database
           ) {
            mismatches.append(mismatch)
        }

        var verifiedRowCount = 0
        for entity in SQLiteMigrationSourceEntity.allCases {
            let expectedRows = snapshot.rows.filter { $0.entity == entity }
            let result = try verifyRows(expectedRows, for: entity, in: database)
            verifiedRowCount += result.verifiedRowCount
            mismatches.append(contentsOf: result.mismatches)
        }

        return SQLiteMigrationVerificationReport(
            sourceFingerprint: snapshot.sourceFingerprint,
            expectedRowCount: snapshot.rows.count,
            verifiedRowCount: verifiedRowCount,
            mismatches: mismatches
        )
    }

    private static func verifyMigrationRun(
        id: String,
        expectedFingerprint: String,
        in database: Database
    ) throws -> SQLiteMigrationVerificationMismatch? {
        let row = try Row.fetchOne(
            database,
            sql: "SELECT sourceFingerprint FROM migration_runs WHERE id = ?",
            arguments: [id]
        )
        guard let row else {
            return SQLiteMigrationVerificationMismatch(
                kind: .migrationRun,
                entity: nil,
                storageID: id,
                column: "sourceFingerprint",
                expected: .text(expectedFingerprint),
                actual: nil,
                detail: "migration run is missing"
            )
        }
        let actual: String? = row["sourceFingerprint"]
        guard actual == expectedFingerprint else {
            return SQLiteMigrationVerificationMismatch(
                kind: .migrationRun,
                entity: nil,
                storageID: id,
                column: "sourceFingerprint",
                expected: .text(expectedFingerprint),
                actual: actual.map(SQLiteMigrationValue.text),
                detail: "source fingerprint does not match"
            )
        }
        return nil
    }

    private static func verifyRows(
        _ expectedRows: [SQLiteMigrationExpectedRow],
        for entity: SQLiteMigrationSourceEntity,
        in database: Database
    ) throws -> (verifiedRowCount: Int, mismatches: [SQLiteMigrationVerificationMismatch]) {
        try validateSchema(for: entity, in: database)
        let table = quotedIdentifier(entity.rawValue)
        let actualIDs = Set(try String.fetchAll(database, sql: "SELECT storageID FROM \(table)"))
        let expectedIDs = Set(expectedRows.map(\.destinationStorageID))
        var mismatches = rowSetMismatches(
            expectedIDs: expectedIDs,
            actualIDs: actualIDs,
            entity: entity
        )
        let result = try verifyPresentRows(
            expectedRows,
            actualIDs: actualIDs,
            actualColumns: entity.destinationColumns,
            table: table,
            in: database
        )
        mismatches.append(contentsOf: result.mismatches)
        return (result.verifiedRowCount, mismatches)
    }

    private static func validateSchema(
        for entity: SQLiteMigrationSourceEntity,
        in database: Database
    ) throws {
        let actualColumns = try fetchColumns(for: entity, in: database)
        guard actualColumns == entity.destinationColumns else {
            let missing = entity.destinationColumns.subtracting(actualColumns).sorted().joined(separator: ", ")
            let unexpected = actualColumns.subtracting(entity.destinationColumns).sorted().joined(separator: ", ")
            throw SQLiteMigrationVerificationError.unsupportedSchema(
                "\(entity.rawValue) columns differ; missing [\(missing)], unexpected [\(unexpected)]"
            )
        }
    }

    private static func rowSetMismatches(
        expectedIDs: Set<String>,
        actualIDs: Set<String>,
        entity: SQLiteMigrationSourceEntity
    ) -> [SQLiteMigrationVerificationMismatch] {
        let missing = expectedIDs.subtracting(actualIDs).sorted().map { storageID in
            SQLiteMigrationVerificationMismatch(
                kind: .missingRow,
                entity: entity,
                storageID: storageID,
                column: nil,
                expected: nil,
                actual: nil,
                detail: "destination row is missing"
            )
        }
        let unexpected = actualIDs.subtracting(expectedIDs).sorted().map { storageID in
            SQLiteMigrationVerificationMismatch(
                kind: .unexpectedRow,
                entity: entity,
                storageID: storageID,
                column: nil,
                expected: nil,
                actual: nil,
                detail: "destination row was not present in the source snapshot"
            )
        }
        return missing + unexpected
    }

    private static func verifyPresentRows(
        _ expectedRows: [SQLiteMigrationExpectedRow],
        actualIDs: Set<String>,
        actualColumns: Set<String>,
        table: String,
        in database: Database
    ) throws -> (verifiedRowCount: Int, mismatches: [SQLiteMigrationVerificationMismatch]) {
        var verifiedRowCount = 0
        var mismatches = [SQLiteMigrationVerificationMismatch]()
        for expectedRow in expectedRows where actualIDs.contains(expectedRow.destinationStorageID) {
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM \(table) WHERE storageID = ?",
                arguments: [expectedRow.destinationStorageID]
            ) else {
                continue
            }
            verifiedRowCount += 1
            for column in actualColumns.sorted() {
                guard let expectedValue = expectedRow.values[column] else {
                    throw SQLiteMigrationVerificationError.invalidSnapshot(
                        "\(expectedRow.entity.rawValue) row is missing column \(column)"
                    )
                }
                let actualValue = SQLiteMigrationValue(databaseValue: row[column] as DatabaseValue)
                guard expectedValue.databaseValue != actualValue.databaseValue else {
                    continue
                }
                mismatches.append(
                    SQLiteMigrationVerificationMismatch(
                        kind: .valueMismatch,
                        entity: expectedRow.entity,
                        storageID: expectedRow.destinationStorageID,
                        column: column,
                        expected: expectedValue,
                        actual: actualValue,
                        detail: "destination value differs from the source snapshot"
                    )
                )
            }
        }
        return (verifiedRowCount, mismatches)
    }

    private static func validate(snapshot: SQLiteMigrationSourceSnapshot) throws {
        guard !snapshot.sourceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteMigrationVerificationError.invalidSnapshot("source model must not be empty")
        }
        guard !snapshot.sourceFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteMigrationVerificationError.invalidSnapshot(
                "source fingerprint must not be empty"
            )
        }

        for entity in SQLiteMigrationSourceEntity.allCases {
            let rows = snapshot.rows.filter { $0.entity == entity }
            var sourceIDs = Set<String>()
            var destinationIDs = Set<String>()
            for row in rows {
                guard !row.sourceObjectID.isEmpty,
                      sourceIDs.insert(row.sourceObjectID).inserted else {
                    throw SQLiteMigrationVerificationError.invalidSnapshot(
                        "duplicate or empty source ID in \(entity.rawValue)"
                    )
                }
                guard !row.destinationStorageID.isEmpty,
                      destinationIDs.insert(row.destinationStorageID).inserted else {
                    throw SQLiteMigrationVerificationError.invalidSnapshot(
                        "duplicate or empty destination ID in \(entity.rawValue)"
                    )
                }
                guard Set(row.values.keys) == entity.destinationColumns,
                      row.values["storageID"] == .text(row.destinationStorageID) else {
                    throw SQLiteMigrationVerificationError.invalidSnapshot(
                        "\(entity.rawValue) row does not declare every destination column"
                    )
                }
            }
        }
    }

    private static func fetchColumns(
        for entity: SQLiteMigrationSourceEntity,
        in database: Database
    ) throws -> Set<String> {
        let rows = try Row.fetchAll(
            database,
            sql: "PRAGMA table_info(\(quotedIdentifier(entity.rawValue)))"
        )
        return Set(rows.compactMap { row in
            let name: String? = row["name"]
            return name
        })
    }

    private static func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
