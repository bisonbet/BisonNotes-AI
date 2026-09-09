import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteMigrationRecoveryRuntimeTests: XCTestCase {
    func testRecoveryReportRedactsConflictIdentifiersAndSurvivesReopen() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let snapshot = makeVerifierSnapshot(migrationRunID: nil)
        let report = SQLiteMigrationRecoveryReporter.report(
            for: .destinationRowConflict(
                entity: .recordings,
                storageID: "secret-storage-id",
                detail: "do not persist this detail"
            ),
            snapshot: snapshot,
            runID: "secret-run-id",
            at: Date(timeIntervalSinceReferenceDate: 500)
        )

        XCTAssertTrue(report.isBlocking)
        let issue = try XCTUnwrap(report.issues.first)
        XCTAssertEqual(issue.kind, .destinationConflict)
        XCTAssertEqual(issue.entity, SQLiteMigrationSourceEntity.recordings.rawValue)
        XCTAssertEqual(issue.identifierDigest?.count, 64)
        XCTAssertFalse(issue.identifierDigest?.contains("secret") ?? true)
        XCTAssertFalse(issue.detail.contains("secret"))

        let reportID = try await store.saveMigrationRecoveryReport(report)
        XCTAssertFalse(reportID.isEmpty)

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let persistedReports = try await reopenedStore.migrationRecoveryReports()
        XCTAssertEqual(persistedReports, [report])
    }

    func testValidationReportIsEmptyForValidSnapshotAndRedactedForInvalidSnapshot() throws {
        let snapshot = makeVerifierSnapshot(migrationRunID: nil)
        let validReport = SQLiteMigrationRecoveryReporter.validationReport(
            for: snapshot,
            at: Date(timeIntervalSinceReferenceDate: 600)
        )
        XCTAssertFalse(validReport.isBlocking)
        XCTAssertTrue(validReport.issues.isEmpty)

        var incompleteValues = snapshot.rows[0].values
        incompleteValues.removeValue(forKey: "recordingName")
        var incompleteRows = snapshot.rows
        incompleteRows[0] = SQLiteMigrationExpectedRow(
            entity: snapshot.rows[0].entity,
            sourceObjectID: snapshot.rows[0].sourceObjectID,
            destinationStorageID: snapshot.rows[0].destinationStorageID,
            values: incompleteValues
        )
        let invalidSnapshot = SQLiteMigrationSourceSnapshot(
            sourceModel: snapshot.sourceModel,
            sourceFingerprint: snapshot.sourceFingerprint,
            migrationRunID: nil,
            rows: incompleteRows
        )

        let invalidReport = SQLiteMigrationRecoveryReporter.validationReport(
            for: invalidSnapshot,
            at: Date(timeIntervalSinceReferenceDate: 601)
        )
        let issue = try XCTUnwrap(invalidReport.issues.first)
        XCTAssertEqual(issue.kind, .invalidSnapshot)
        XCTAssertEqual(issue.detail, "snapshot validation failed")
        XCTAssertNil(issue.identifierDigest)
    }
}
