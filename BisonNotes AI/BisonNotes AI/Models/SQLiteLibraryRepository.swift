import Foundation
import GRDB

/// Read-only repository adapter for the app-owned SQLite generation.
///
/// This adapter is intentionally not connected to production app startup yet.
/// It provides the storage-neutral boundary and contract-test target needed
/// before any caller is moved away from Core Data.
struct SQLiteLibraryRepository: LibraryRepository, Sendable {
    let store: SQLiteLibraryStore

    func fetchRecordingSummaries() async throws -> [LibraryRecordingSnapshot] {
        try await store.fetchRecordingSummaries()
    }
}

extension SQLiteLibraryStore {
    func fetchRecordingSummaries() throws -> [LibraryRecordingSnapshot] {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT storageID, id, recordingName, recordingDate, duration,
                       fileSize, recordingURL, isArchived, lastModified
                FROM recordings
                """
            )
            return try rows
                .map(SQLiteLibraryRepositoryMapper.snapshot(from:))
                .sorted(by: LibraryRecordingSnapshot.stableOrder)
        }
    }
}

private enum SQLiteLibraryRepositoryMapper {
    static func snapshot(from row: Row) throws -> LibraryRecordingSnapshot {
        guard let storageID: String = row["storageID"], !storageID.isEmpty else {
            throw LibraryRepositoryError.invalidRecord(
                entity: "recordings",
                field: "storageID"
            )
        }

        let archivedValue: Int64? = row["isArchived"]
        return LibraryRecordingSnapshot(
            storageID: storageID,
            legacyID: row["id"],
            name: row["recordingName"],
            recordingDate: date(from: row["recordingDate"]),
            duration: row["duration"],
            fileSize: row["fileSize"],
            recordingURL: row["recordingURL"],
            isArchived: archivedValue.map { $0 != 0 },
            lastModified: date(from: row["lastModified"])
        )
    }

    private static func date(from value: Double?) -> Date? {
        value.map(Date.init(timeIntervalSinceReferenceDate:))
    }
}
