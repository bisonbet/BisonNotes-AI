import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteApplicationArchiveRestoreRuntimeTests: XCTestCase {
    func testCoordinatorCopiesIntoDocumentsCommitsMetadataAndDeletesSource() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runtime = SQLiteApplicationArchiveRestoreRuntime(
            coordinator: SQLiteArchiveRestoreCoordinator(
                store: fixture.store,
                mapping: fixture.mapping
            )
        )
        let recorder = SQLiteArchiveRestoreCoordinatorRecorder()
        let completed = try await runtime.restore(
            fixture.request,
            rootAccess: fixture.rootAccess,
            metadataCommit: { operation, destinationURL in
                await recorder.record(operation, destinationURL: destinationURL)
            }
        )

        XCTAssertEqual(completed.phase, SQLiteArchiveRestorePhase.completed)
        XCTAssertEqual(completed.ownerLastModified, fixture.request.ownerLastModified)
        let recordedCount = await recorder.recordedCount()
        XCTAssertEqual(recordedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.destinationURL),
            fixture.payload
        )
    }

    func testCoordinatorLeavesJournalRetryableWhenMetadataCommitFails() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runtime = SQLiteApplicationArchiveRestoreRuntime(
            coordinator: SQLiteArchiveRestoreCoordinator(
                store: fixture.store,
                mapping: fixture.mapping
            )
        )

        do {
            _ = try await runtime.restore(
                fixture.request,
                rootAccess: fixture.rootAccess,
                metadataCommit: { _, _ in
                    throw SQLiteApplicationArchiveRestoreTestError.metadataCommitFailed
                }
            )
            XCTFail("Expected metadata commit failure to remain retryable")
        } catch let error as SQLiteApplicationArchiveRestoreError {
            XCTAssertEqual(
                error,
                .operationDidNotComplete(
                    phase: SQLiteArchiveRestorePhase.metadataFailed
                )
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destinationURL.path))

        let report = try await runtime.reconcilePending(
            maxOperations: 1,
            rootAccessForOperation: { _ in fixture.rootAccess },
            metadataCommit: { _, _ in }
        )
        XCTAssertEqual(report.completedOperationCount, 1)
        XCTAssertEqual(report.failedOperationCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    private struct Fixture {
        let directory: URL
        let sourceURL: URL
        let destinationURL: URL
        let payload: Data
        let mapping: SQLiteApplicationMediaRootMapping
        let store: SQLiteLibraryStore
        let rootAccess: SQLiteArchiveRestoreRootAccess
        let request: SQLiteArchiveRestoreRequest
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BisonNotesSQLiteArchiveRestore-\(UUID().uuidString)",
                isDirectory: true
            )
        let documentsRoot = directory.appendingPathComponent("Documents", isDirectory: true)
        let applicationSupportRoot = directory.appendingPathComponent(
            "ApplicationSupport",
            isDirectory: true
        )
        let temporaryRoot = directory.appendingPathComponent("Temporary", isDirectory: true)
        let archiveRoot = directory.appendingPathComponent("ArchiveProvider", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentsRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupportRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: archiveRoot.appendingPathComponent("incoming", isDirectory: true),
            withIntermediateDirectories: true
        )

        let sourceURL = archiveRoot
            .appendingPathComponent("incoming", isDirectory: true)
            .appendingPathComponent("recording.m4a")
        let destinationURL = documentsRoot
            .appendingPathComponent("Restored", isDirectory: true)
            .appendingPathComponent("recording.m4a")
        let payload = Data("archive-restore-runtime".utf8)
        try payload.write(to: sourceURL)

        let mapping = try SQLiteApplicationMediaRootMapping(
            documentsRoot: documentsRoot,
            applicationSupportRoot: applicationSupportRoot,
            temporaryRoot: temporaryRoot
        )
        let store = try SQLiteLibraryStore(
            databaseURL: applicationSupportRoot.appendingPathComponent("journal.sqlite")
        )
        let sourceRootID = "archive-provider"
        let rootRegistry = try mapping.registry(
            addingSourceRootID: sourceRootID,
            url: archiveRoot
        )
        let ownerLastModified = Date(timeIntervalSinceReferenceDate: 4321)
        return Fixture(
            directory: directory,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            payload: payload,
            mapping: mapping,
            store: store,
            rootAccess: SQLiteArchiveRestoreRootAccess(rootRegistry: rootRegistry),
            request: SQLiteArchiveRestoreRequest(
                operationID: "archive-restore-runtime",
                archiveLocationID: "archive-location-1",
                ownerStorageID: "recording-1",
                ownerRevision: nil,
                ownerLastModified: ownerLastModified,
                sourceRootID: sourceRootID,
                sourceRootURL: archiveRoot,
                sourceURL: sourceURL,
                destinationRootID: SQLiteApplicationMediaRootID.documents.rawValue,
                destinationRelativePath: "Restored/recording.m4a"
            )
        )
    }
}

private actor SQLiteArchiveRestoreCoordinatorRecorder {
    private(set) var count = 0

    func recordedCount() -> Int {
        count
    }

    func record(
        _ operation: SQLiteArchiveRestoreOperation,
        destinationURL: URL
    ) {
        _ = operation
        _ = destinationURL
        count += 1
    }
}

private enum SQLiteApplicationArchiveRestoreTestError: Error {
    case metadataCommitFailed
}
