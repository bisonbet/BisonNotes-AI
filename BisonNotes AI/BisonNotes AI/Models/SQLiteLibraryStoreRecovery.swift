import Foundation
import GRDB

extension SQLiteLibraryStore {
    func saveMigrationRecoveryReport(
        _ report: SQLiteMigrationRecoveryReport
    ) throws -> String {
        let reportID = UUID().uuidString
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(report)
        let createdAt = report.generatedAt.timeIntervalSinceReferenceDate

        try databaseQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO recovery_items (
                    id, category, relativePath, payload, reason, provenance, createdAt
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    reportID,
                    SQLiteMigrationRecoveryReporter.recoveryCategory,
                    nil,
                    payload,
                    "structured migration recovery report",
                    report.sourceModel,
                    createdAt
                ]
            )
        }
        return reportID
    }

    func migrationRecoveryReports() throws -> [SQLiteMigrationRecoveryReport] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT payload
                FROM recovery_items
                WHERE category = ?
                ORDER BY createdAt, id
                """,
                arguments: [SQLiteMigrationRecoveryReporter.recoveryCategory]
            )
            return try rows.map { row in
                guard let payload: Data = row["payload"] else {
                    throw SQLiteLibraryStoreError.invalidRecoveryReport(
                        "recovery report payload is missing"
                    )
                }
                do {
                    return try decoder.decode(
                        SQLiteMigrationRecoveryReport.self,
                        from: payload
                    )
                } catch {
                    throw SQLiteLibraryStoreError.invalidRecoveryReport(
                        error.localizedDescription
                    )
                }
            }
        }
    }
}
