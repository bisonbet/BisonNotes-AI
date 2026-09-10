import CryptoKit
import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteMediaTransferRuntimeTests: XCTestCase {
    func testCoordinatorRecordsReceiptAndKeepsSourceUntilExplicitRemoval() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        let coordinator = SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        )

        let result = try await coordinator.reconcile(
            fixture.transfer,
            at: Date(timeIntervalSinceReferenceDate: 100)
        )
        XCTAssertEqual(result.operation.state, "completed")
        XCTAssertEqual(result.receipt.outcome, .committed)
        XCTAssertEqual(result.receipt.destinationStorageID, "asset-1")
        XCTAssertEqual(result.sourceRetention, .eligibleForRemoval)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destinationURL.path))

        let retry = try await coordinator.reconcile(
            fixture.transfer,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        XCTAssertEqual(retry.receipt, result.receipt)
        XCTAssertEqual(retry.sourceRetention, .eligibleForRemoval)
    }

    func testFailedCopyRetainsSourceAndDoesNotCreateReceipt() async throws {
        let fixture = try makeMediaTransferFixture(
            expectedSHA256: String(repeating: "0", count: 64)
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        let coordinator = SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        )

        do {
            _ = try await coordinator.reconcile(fixture.transfer)
            XCTFail("Expected checksum mismatch")
        } catch let error as SQLiteMediaFileOperationError {
            XCTAssertEqual(error, .integrityMismatch)
        }

        let operation = try await store.mediaFileOperation(id: "operation-1")
        XCTAssertEqual(operation?.state, "failed")
        let receipt = try await store.importReceipt(
            sourceTransferID: fixture.transfer.sourceTransferID
        )
        XCTAssertNil(receipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationURL.path))
    }

    func testReceiptConflictRetainsSourceAfterVerifiedCopy() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        _ = try await store.recordImportReceipt(
            sourceTransferID: fixture.transfer.sourceTransferID,
            destinationStorageID: "different-asset",
            outcome: .rejected,
            receiptID: "preexisting-receipt"
        )
        let coordinator = SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        )

        do {
            _ = try await coordinator.reconcile(fixture.transfer)
            XCTFail("Expected receipt conflict")
        } catch let error as SQLiteImportReceiptError {
            XCTAssertEqual(error, .receiptConflict)
        }

        let operation = try await store.mediaFileOperation(id: "operation-1")
        let receipt = try await store.importReceipt(
            sourceTransferID: fixture.transfer.sourceTransferID
        )
        XCTAssertEqual(operation?.state, "completed")
        XCTAssertEqual(receipt?.outcome, .rejected)
        XCTAssertEqual(
            try SQLiteMediaSourceRetentionPolicy.disposition(
                sourceTransferID: fixture.transfer.sourceTransferID,
                operation: try XCTUnwrap(operation),
                receipt: receipt
            ),
            .retain
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    func testRootRegistryRejectsBroadAndUnregisteredRoots() throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(
            try SQLiteMediaRootRegistry(
                sourceRoots: ["source": URL(fileURLWithPath: "/")],
                destinationRoots: ["destination": directory]
            )
        ) { error in
            XCTAssertEqual(error as? SQLiteMediaFileOperationError, .invalidRoot)
        }

        let registry = try SQLiteMediaRootRegistry(
            sourceRoots: ["source": directory],
            destinationRoots: ["destination": directory]
        )
        XCTAssertThrowsError(
            try registry.roots(
                sourceRoot: "unknown",
                destinationRoot: "destination"
            )
        ) { error in
            XCTAssertEqual(error as? SQLiteMediaFileOperationError, .invalidRoot)
        }
    }
}

struct SQLiteMediaTransferFixture {
    let directory: URL
    let sourceURL: URL
    let destinationURL: URL
    let registry: SQLiteMediaRootRegistry
    let transfer: SQLiteMediaTransferPlan
}

func makeMediaTransferFixture(
    expectedSHA256: String? = nil
) throws -> SQLiteMediaTransferFixture {
    let directory = try makeVerifierTemporaryDirectory()
    let sourceRoot = directory.appendingPathComponent("source", isDirectory: true)
    let destinationRoot = directory.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(
        at: sourceRoot,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: destinationRoot,
        withIntermediateDirectories: true
    )

    let data = Data("media-transfer-fixture".utf8)
    let sourceURL = sourceRoot
        .appendingPathComponent("incoming", isDirectory: true)
        .appendingPathComponent("recording.m4a")
    try FileManager.default.createDirectory(
        at: sourceURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: sourceURL)
    let digest = SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    let destinationURL = destinationRoot
        .appendingPathComponent("recordings", isDirectory: true)
        .appendingPathComponent("recording.m4a")
    let copyPlan = SQLiteMediaCopyPlan(
        operationID: "operation-1",
        assetID: "asset-1",
        ownerStorageID: "recording-1",
        ownerRevision: 1,
        sourceRoot: "source",
        sourceRelativePath: "incoming/recording.m4a",
        destinationRoot: "destination",
        destinationRelativePath: "recordings/recording.m4a",
        expectedByteLength: Int64(data.count),
        expectedSHA256: expectedSHA256 ?? digest
    )
    let registry = try makeMediaTransferRegistry(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
    return SQLiteMediaTransferFixture(
        directory: directory,
        sourceURL: sourceURL,
        destinationURL: destinationURL,
        registry: registry,
        transfer: SQLiteMediaTransferPlan(
            sourceTransferID: "watch-transfer-1",
            copyPlan: copyPlan
        )
    )
}

private func makeMediaTransferRegistry(
    sourceRoot: URL,
    destinationRoot: URL
) throws -> SQLiteMediaRootRegistry {
    try SQLiteMediaRootRegistry(
        sourceRoots: ["source": sourceRoot],
        destinationRoots: ["destination": destinationRoot]
    )
}
