import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteMediaFileOperationRuntimeTests: XCTestCase {
    func testMediaCopyPublishesOnlyAfterVerifiedFile() async throws {
        let fixture = try makeFixture(data: Data("audio-fixture".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let databaseURL = fixture.directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let plan = fixture.plan
        _ = try await store.enqueueMediaCopy(
            plan,
            at: Date(timeIntervalSinceReferenceDate: 100)
        )

        let operation = try await SQLiteMediaFileOperationWorker(store: store).run(
            operationID: plan.operationID,
            roots: fixture.roots,
            at: Date(timeIntervalSinceReferenceDate: 101)
        )

        XCTAssertEqual(operation.state, "completed")
        XCTAssertEqual(operation.attemptCount, 1)
        XCTAssertNil(operation.lastError)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), fixture.data)
        let persistedAssetState = try assetState(
            databaseURL: databaseURL,
            storageID: plan.assetID
        )
        XCTAssertEqual(
            persistedAssetState,
            "available"
        )
    }

    func testMediaCopyRecoversDestinationPublishedBeforeDatabaseCheckpoint() async throws {
        let fixture = try makeFixture(data: Data("already-installed".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let databaseURL = fixture.directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        _ = try await store.enqueueMediaCopy(fixture.plan)
        try FileManager.default.createDirectory(
            at: fixture.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: fixture.sourceURL,
            to: fixture.destinationURL
        )
        try FileManager.default.removeItem(at: fixture.sourceURL)
        let claimed = try await store.claimMediaOperation(
            id: fixture.plan.operationID,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        XCTAssertEqual(claimed.state, "running")
        XCTAssertEqual(claimed.attemptCount, 1)

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let recoveredCount = try await reopenedStore.recoverInterruptedMediaOperations(
            at: Date(timeIntervalSinceReferenceDate: 201)
        )
        XCTAssertEqual(
            recoveredCount,
            1
        )
        let operation = try await SQLiteMediaFileOperationWorker(store: reopenedStore).run(
            operationID: fixture.plan.operationID,
            roots: fixture.roots,
            at: Date(timeIntervalSinceReferenceDate: 202)
        )

        XCTAssertEqual(operation.state, "completed")
        XCTAssertEqual(operation.attemptCount, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), fixture.data)
    }

    func testMediaCopyDoesNotOverwriteConflictingDestination() async throws {
        let fixture = try makeFixture(data: Data("expected-audio".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let databaseURL = fixture.directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        _ = try await store.enqueueMediaCopy(fixture.plan)
        try FileManager.default.createDirectory(
            at: fixture.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let conflictingData = Data("different-audio".utf8)
        try conflictingData.write(to: fixture.destinationURL)

        do {
            _ = try await SQLiteMediaFileOperationWorker(store: store).run(
                operationID: fixture.plan.operationID,
                roots: fixture.roots,
                at: Date(timeIntervalSinceReferenceDate: 300)
            )
            XCTFail("Expected the conflicting destination to stop the copy")
        } catch let error as SQLiteMediaFileOperationError {
            XCTAssertEqual(error, .destinationConflict)
        }

        let operation = try await store.mediaFileOperation(id: fixture.plan.operationID)
        XCTAssertEqual(operation?.state, "failed")
        XCTAssertEqual(operation?.lastError, "media copy failed; retry required")
        XCTAssertFalse(operation?.lastError?.contains(fixture.destinationURL.path) == true)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationURL), conflictingData)
        XCTAssertEqual(
            try assetState(databaseURL: databaseURL, storageID: fixture.plan.assetID),
            "unavailable"
        )
    }

    func testMediaCopyRejectsTraversalBeforeEnqueue() async throws {
        let fixture = try makeFixture(data: Data("audio".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        let invalidPlan = SQLiteMediaCopyPlan(
            operationID: fixture.plan.operationID,
            assetID: fixture.plan.assetID,
            ownerStorageID: nil,
            ownerRevision: nil,
            sourceRoot: fixture.plan.sourceRoot,
            sourceRelativePath: "../outside.m4a",
            destinationRoot: fixture.plan.destinationRoot,
            destinationRelativePath: fixture.plan.destinationRelativePath,
            expectedByteLength: fixture.plan.expectedByteLength,
            expectedSHA256: fixture.plan.expectedSHA256
        )

        do {
            _ = try await store.enqueueMediaCopy(invalidPlan)
            XCTFail("Expected traversal to be rejected")
        } catch let error as SQLiteMediaFileOperationError {
            XCTAssertEqual(error, .invalidRelativePath)
        }
        let persistedOperation = try await store.mediaFileOperation(
            id: fixture.plan.operationID
        )
        XCTAssertNil(persistedOperation)
    }

    func testEnqueueingTheSameMediaCopyIsIdempotent() async throws {
        let fixture = try makeFixture(data: Data("idempotent-audio".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        let first = try await store.enqueueMediaCopy(fixture.plan)
        let second = try await store.enqueueMediaCopy(
            fixture.plan,
            at: Date(timeIntervalSinceReferenceDate: 400)
        )
        XCTAssertEqual(second, first)
    }
}

private struct MediaFixture {
    let directory: URL
    let sourceURL: URL
    let destinationURL: URL
    let data: Data
    let plan: SQLiteMediaCopyPlan
    let roots: SQLiteMediaFileOperationRoots
}

private func makeFixture(data: Data) throws -> MediaFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BisonNotesSQLiteMedia-\(UUID().uuidString)", isDirectory: true)
    let sourceRoot = directory.appendingPathComponent("legacy-audio", isDirectory: true)
    let destinationRoot = directory.appendingPathComponent("sqlite-audio", isDirectory: true)
    let sourceURL = sourceRoot.appendingPathComponent("recordings/source.m4a")
    let destinationURL = destinationRoot.appendingPathComponent("recordings/source.m4a")
    try FileManager.default.createDirectory(
        at: sourceURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: sourceURL)
    let plan = SQLiteMediaCopyPlan(
        operationID: "operation-\(UUID().uuidString)",
        assetID: "asset-\(UUID().uuidString)",
        ownerStorageID: "recording-1",
        ownerRevision: 1,
        sourceRoot: "legacyAudio",
        sourceRelativePath: "recordings/source.m4a",
        destinationRoot: "sqliteAudio",
        destinationRelativePath: "recordings/source.m4a",
        expectedByteLength: Int64(data.count),
        expectedSHA256: mediaSHA256(data)
    )
    return MediaFixture(
        directory: directory,
        sourceURL: sourceURL,
        destinationURL: destinationURL,
        data: data,
        plan: plan,
        roots: SQLiteMediaFileOperationRoots(
            source: ["legacyAudio": sourceRoot],
            destination: ["sqliteAudio": destinationRoot]
        )
    )
}

private func mediaSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func assetState(databaseURL: URL, storageID: String) throws -> String? {
    let database = try DatabaseQueue(path: databaseURL.path)
    return try database.read { database in
        try String.fetchOne(
            database,
            sql: "SELECT state FROM asset_catalog WHERE storageID = ?",
            arguments: [storageID]
        )
    }
}
