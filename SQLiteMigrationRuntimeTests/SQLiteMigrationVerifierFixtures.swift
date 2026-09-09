import Foundation
import GRDB
@testable import BisonNotesSQLiteRuntime

func makeVerifierTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "BisonNotesSQLiteVerifier-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

func makeVerifierSnapshot(migrationRunID: String?) -> SQLiteMigrationSourceSnapshot {
    let recordingStorageID = "recording-storage"
    let transcriptStorageID = "transcript-storage"
    let summaryStorageID = "summary-storage"
    let rows = [
        makeVerifierRecordingRow(storageID: recordingStorageID),
        makeVerifierTranscriptRow(
            storageID: transcriptStorageID,
            recordingStorageID: recordingStorageID
        ),
        makeVerifierSummaryRow(
            storageID: summaryStorageID,
            recordingStorageID: recordingStorageID,
            transcriptStorageID: transcriptStorageID
        ),
        makeVerifierProcessingJobRow(recordingStorageID: recordingStorageID),
        makeVerifierArchiveLocationRow(),
        makeVerifierCloudMutationRow()
    ]
    return SQLiteMigrationSourceSnapshot(
        sourceModel: "BisonNotes_AI_v2",
        sourceFingerprint: "closed-fixture-sha256",
        migrationRunID: migrationRunID,
        rows: rows
    )
}

private func makeVerifierRecordingRow(storageID: String) -> SQLiteMigrationExpectedRow {
    SQLiteMigrationExpectedRow(
        entity: .recordings,
        sourceObjectID: "recording-source",
        destinationStorageID: storageID,
        values: completeVerifierValues(
            for: .recordings,
            storageID: storageID,
            overrides: [
                "audioQuality": .text("lossless"),
                "createdAt": .real(100),
                "duration": .real(7.5),
                "fileSize": .integer(42),
                "id": .text("recording-legacy"),
                "isCloudSyncDisabled": .boolean(false),
                "lastModified": .real(101),
                "recordingDate": .real(100),
                "recordingName": .text("Fixture recording"),
                "recordingURL": .text("recording.m4a"),
                "summaryId": .text("summary-legacy"),
                "summaryStatus": .text("complete"),
                "transcriptId": .text("transcript-legacy"),
                "transcriptionStatus": .text("complete"),
                "isArchived": .boolean(false)
            ]
        )
    )
}

private func makeVerifierTranscriptRow(
    storageID: String,
    recordingStorageID: String
) -> SQLiteMigrationExpectedRow {
    SQLiteMigrationExpectedRow(
        entity: .transcripts,
        sourceObjectID: "transcript-source",
        destinationStorageID: storageID,
        values: completeVerifierValues(
            for: .transcripts,
            storageID: storageID,
            overrides: [
                "confidence": .real(0.98),
                "createdAt": .real(102),
                "engine": .text("fixture-engine"),
                "id": .text("transcript-legacy"),
                "lastModified": .real(103),
                "processingTime": .real(1.5),
                "recordingStorageID": .text(recordingStorageID),
                "recordingId": .text("recording-legacy"),
                "segments": .text("{\"segments\":[]}"),
                "speakerMappings": .text("{}")
            ]
        )
    )
}

private func makeVerifierSummaryRow(
    storageID: String,
    recordingStorageID: String,
    transcriptStorageID: String
) -> SQLiteMigrationExpectedRow {
    SQLiteMigrationExpectedRow(
        entity: .summaries,
        sourceObjectID: "summary-source",
        destinationStorageID: storageID,
        values: completeVerifierValues(
            for: .summaries,
            storageID: storageID,
            overrides: [
                "aiMethod": .text("fixture-model"),
                "confidence": .real(0.9),
                "contentType": .text("summary"),
                "generatedAt": .real(104),
                "id": .text("summary-legacy"),
                "originalLength": .integer(12),
                "processingTime": .real(2),
                "recordingStorageID": .text(recordingStorageID),
                "recordingId": .text("recording-legacy"),
                "summary": .text("Fixture summary"),
                "transcriptStorageID": .text(transcriptStorageID),
                "transcriptId": .text("transcript-legacy"),
                "version": .integer(1),
                "wordCount": .integer(2)
            ]
        )
    )
}

private func makeVerifierProcessingJobRow(recordingStorageID: String) -> SQLiteMigrationExpectedRow {
    let storageID = "job-storage"
    return SQLiteMigrationExpectedRow(
        entity: .processingJobs,
        sourceObjectID: "job-source",
        destinationStorageID: storageID,
        values: completeVerifierValues(
            for: .processingJobs,
            storageID: storageID,
            overrides: [
                "engine": .text("fixture-engine"),
                "id": .text("job-legacy"),
                "jobType": .text("transcription"),
                "lastModified": .real(105),
                "modelName": .text("fixture-model"),
                "progress": .real(1),
                "recordingName": .text("Fixture recording"),
                "recordingURL": .text("recording.m4a"),
                "recordingStorageID": .text(recordingStorageID),
                "startTime": .real(104),
                "status": .text("complete")
            ]
        )
    )
}

private func makeVerifierArchiveLocationRow() -> SQLiteMigrationExpectedRow {
    let storageID = "archive-storage"
    return SQLiteMigrationExpectedRow(
        entity: .archiveLocations,
        sourceObjectID: "archive-source",
        destinationStorageID: storageID,
        values: completeVerifierValues(
            for: .archiveLocations,
            storageID: storageID,
            overrides: [
                "bookmarkData": .blob(Data([1, 2, 3])),
                "destinationURLString": .text("archive://fixture"),
                "displayName": .text("Fixture archive"),
                "exportedAt": .real(106),
                "exportedFilename": .text("fixture.m4a"),
                "fileSize": .integer(42),
                "id": .text("archive-legacy"),
                "lastVerifiedAt": .real(107),
                "providerDisplayName": .text("Fixture provider"),
                "recordingId": .text("recording-legacy"),
                "status": .text("verified")
            ]
        )
    )
}

private func makeVerifierCloudMutationRow() -> SQLiteMigrationExpectedRow {
    let storageID = "mutation-storage"
    return SQLiteMigrationExpectedRow(
        entity: .pendingCloudMutations,
        sourceObjectID: "mutation-source",
        destinationStorageID: storageID,
        values: completeVerifierValues(
            for: .pendingCloudMutations,
            storageID: storageID,
            overrides: [
                "kind": .text("update"),
                "payload": .blob(Data([4, 5, 6])),
                "recordingId": .text("recording-legacy"),
                "requestedAt": .real(108),
                "targetId": .text("recording-legacy"),
                "version": .integer(1)
            ]
        )
    )
}

private func completeVerifierValues(
    for entity: SQLiteMigrationSourceEntity,
    storageID: String,
    overrides: [String: SQLiteMigrationValue]
) -> [String: SQLiteMigrationValue] {
    var values = Dictionary(
        uniqueKeysWithValues: entity.destinationColumns.map {
            ($0, SQLiteMigrationValue.null)
        }
    )
    values["storageID"] = .text(storageID)
    values.merge(overrides) { _, newValue in newValue }
    return values
}

func insertVerifierRows(
    rows: [SQLiteMigrationExpectedRow],
    into databaseURL: URL
) throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    try database.write { sqliteDatabase in
        for row in rows {
            let columns = row.values.keys.sorted()
            let quotedColumns = columns.map(quoteVerifierIdentifier).joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
            let arguments = StatementArguments(
                columns.map { row.values[$0]!.databaseValue }
            )
            let sql = """
            INSERT INTO \(quoteVerifierIdentifier(row.entity.rawValue))
            (\(quotedColumns)) VALUES (\(placeholders))
            """
            try sqliteDatabase.execute(sql: sql, arguments: arguments)
        }
    }
}

private func quoteVerifierIdentifier(_ identifier: String) -> String {
    "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
}
