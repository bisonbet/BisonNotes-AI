import CryptoKit
import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteMediaTransferRuntimeTests: XCTestCase {
    func testMetadataDescriptorRejectsPayloadLargerThanJournalLimit() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        let oversizedPayload = Data(repeating: 0x01, count: 64 * 1024 + 1)
        let plan = SQLiteMediaCopyPlan(
            operationID: fixture.transfer.copyPlan.operationID,
            assetID: fixture.transfer.copyPlan.assetID,
            ownerStorageID: fixture.transfer.copyPlan.ownerStorageID,
            ownerRevision: fixture.transfer.copyPlan.ownerRevision,
            sourceRoot: fixture.transfer.copyPlan.sourceRoot,
            sourceRelativePath: fixture.transfer.copyPlan.sourceRelativePath,
            destinationRoot: fixture.transfer.copyPlan.destinationRoot,
            destinationRelativePath: fixture.transfer.copyPlan.destinationRelativePath,
            expectedByteLength: fixture.transfer.copyPlan.expectedByteLength,
            expectedSHA256: fixture.transfer.copyPlan.expectedSHA256,
            metadataPayload: oversizedPayload
        )

        do {
            _ = try await store.enqueueMediaCopy(
                SQLiteMediaTransferPlan(
                    sourceTransferID: fixture.transfer.sourceTransferID,
                    copyPlan: plan
                )
            )
            XCTFail("Expected the metadata descriptor size limit")
        } catch let error as SQLiteMediaFileOperationError {
            XCTAssertEqual(error, .invalidMetadataPayload)
        }
    }

    func testMetadataDescriptorSurvivesReopenAndConflictingRetryFailsClosed() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let databaseURL = fixture.directory.appendingPathComponent("library.sqlite")
        let payload = Data("watch-metadata-v1".utf8)
        let plan = SQLiteMediaCopyPlan(
            operationID: fixture.transfer.copyPlan.operationID,
            assetID: fixture.transfer.copyPlan.assetID,
            ownerStorageID: fixture.transfer.copyPlan.ownerStorageID,
            ownerRevision: fixture.transfer.copyPlan.ownerRevision,
            sourceRoot: fixture.transfer.copyPlan.sourceRoot,
            sourceRelativePath: fixture.transfer.copyPlan.sourceRelativePath,
            destinationRoot: fixture.transfer.copyPlan.destinationRoot,
            destinationRelativePath: fixture.transfer.copyPlan.destinationRelativePath,
            expectedByteLength: fixture.transfer.copyPlan.expectedByteLength,
            expectedSHA256: fixture.transfer.copyPlan.expectedSHA256,
            metadataPayload: payload
        )
        let transfer = SQLiteMediaTransferPlan(
            sourceTransferID: fixture.transfer.sourceTransferID,
            copyPlan: plan
        )

        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let operation = try await store.enqueueMediaCopy(transfer)
        XCTAssertEqual(operation.metadataPayload, payload)

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let reopenedOperationValue = try await reopenedStore.mediaFileOperation(id: operation.id)
        let reopenedOperation = try XCTUnwrap(reopenedOperationValue)
        XCTAssertEqual(reopenedOperation.metadataPayload, payload)

        let conflictingPlan = SQLiteMediaCopyPlan(
            operationID: plan.operationID,
            assetID: plan.assetID,
            ownerStorageID: plan.ownerStorageID,
            ownerRevision: plan.ownerRevision,
            sourceRoot: plan.sourceRoot,
            sourceRelativePath: plan.sourceRelativePath,
            destinationRoot: plan.destinationRoot,
            destinationRelativePath: plan.destinationRelativePath,
            expectedByteLength: plan.expectedByteLength,
            expectedSHA256: plan.expectedSHA256,
            metadataPayload: Data("different-metadata".utf8)
        )
        do {
            _ = try await reopenedStore.enqueueMediaCopy(
                SQLiteMediaTransferPlan(
                    sourceTransferID: transfer.sourceTransferID,
                    copyPlan: conflictingPlan
                )
            )
            XCTFail("Expected metadata descriptor conflict")
        } catch let error as SQLiteMediaFileOperationError {
            XCTAssertEqual(error, .operationConflict)
        }
    }

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
            at: Date(timeIntervalSinceReferenceDate: 100),
            metadataCommit: { _ in }
        )
        XCTAssertEqual(result.operation.state, "completed")
        XCTAssertEqual(result.operation.metadataState, SQLiteMediaMetadataState.committed)
        XCTAssertEqual(
            result.operation.metadataAcknowledgedAt,
            Date(timeIntervalSinceReferenceDate: 100)
        )
        XCTAssertEqual(result.receipt.outcome, .committed)
        XCTAssertEqual(result.receipt.destinationStorageID, "asset-1")
        XCTAssertEqual(result.sourceRetention, .eligibleForRemoval)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destinationURL.path))

        let retry = try await coordinator.reconcile(
            fixture.transfer,
            at: Date(timeIntervalSinceReferenceDate: 200),
            metadataCommit: { _ in }
        )
        XCTAssertEqual(retry.receipt, result.receipt)
        XCTAssertEqual(retry.sourceRetention, .eligibleForRemoval)
    }

    func testEligibleSourceQuerySupportsRestartCleanup() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        ).reconcile(
            fixture.transfer,
            metadataCommit: { _ in }
        )

        let sourcePaths = try await store.mediaSourceRelativePaths(sourceRoot: "source")
        XCTAssertEqual(
            sourcePaths,
            Set([fixture.transfer.copyPlan.sourceRelativePath])
        )

        let eligible = try await store.mediaOperationsEligibleForSourceRemoval(
            sourceRoot: "source"
        )
        XCTAssertEqual(eligible.map(\.id), [fixture.transfer.copyPlan.operationID])

        _ = try await SQLiteMediaSourceRetentionExecutor(
            store: store,
            rootRegistry: fixture.registry
        ).removeSourceIfEligible(
            sourceTransferID: fixture.transfer.sourceTransferID,
            operationID: fixture.transfer.copyPlan.operationID
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    func testMetadataFailureRetainsPublishedSourceWithoutReceiptAndCanRetry() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        let coordinator = SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        )
        let recorder = SQLiteMediaMetadataCommitRecorder()

        do {
            _ = try await coordinator.reconcile(
                fixture.transfer,
                metadataCommit: { operation in
                    recorder.append(operation)
                    throw SQLiteMediaMetadataCommitTestError.rejected
                }
            )
            XCTFail("Expected metadata acknowledgement failure")
        } catch let error as SQLiteMediaMetadataCommitTestError {
            XCTAssertEqual(error, .rejected)
        }

        let persistedFailedOperation = try await store.mediaFileOperation(
            id: fixture.transfer.copyPlan.operationID
        )
        let failedOperation = try XCTUnwrap(persistedFailedOperation)
        XCTAssertEqual(failedOperation.state, "completed")
        XCTAssertEqual(failedOperation.metadataState, SQLiteMediaMetadataState.failed)
        XCTAssertNil(failedOperation.metadataAcknowledgedAt)
        let failedReceipt = try await store.importReceipt(
            sourceTransferID: fixture.transfer.sourceTransferID
        )
        XCTAssertNil(failedReceipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destinationURL.path))

        let result = try await coordinator.reconcile(
            fixture.transfer,
            at: Date(timeIntervalSinceReferenceDate: 200),
            metadataCommit: { operation in
                recorder.append(operation)
            }
        )
        XCTAssertEqual(result.operation.metadataState, SQLiteMediaMetadataState.committed)
        XCTAssertEqual(
            result.operation.metadataAcknowledgedAt,
            Date(timeIntervalSinceReferenceDate: 200)
        )
        XCTAssertEqual(result.receipt.outcome, .committed)
        XCTAssertEqual(recorder.states, [
            SQLiteMediaMetadataState.committing,
            SQLiteMediaMetadataState.committing
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
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
            _ = try await coordinator.reconcile(
                fixture.transfer,
                metadataCommit: { _ in }
            )
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
            _ = try await coordinator.reconcile(
                fixture.transfer,
                metadataCommit: { _ in }
            )
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

    func testSourceTransferIDSurvivesReopenAndMismatchedRemovalRetainsSource() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let databaseURL = fixture.directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        _ = try await SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        ).reconcile(
            fixture.transfer,
            metadataCommit: { _ in }
        )

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let persistedOperation = try await reopenedStore.mediaFileOperation(
            id: fixture.transfer.copyPlan.operationID
        )
        let operation = try XCTUnwrap(persistedOperation)
        XCTAssertEqual(operation.sourceTransferID, fixture.transfer.sourceTransferID)

        let executor = SQLiteMediaSourceRetentionExecutor(
            store: reopenedStore,
            rootRegistry: fixture.registry
        )
        do {
            _ = try await executor.removeSourceIfEligible(
                sourceTransferID: "different-source-transfer",
                operationID: operation.id
            )
            XCTFail("Expected a mismatched source transfer to retain the source")
        } catch let error as SQLiteMediaSourceRetentionError {
            XCTAssertEqual(error, .sourceNotEligible)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    func testBackgroundReconcilerCopiesQueuedMediaAndRecordsReceipt() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        ).enqueue(fixture.transfer)

        let progressRecorder = SQLiteMediaProgressRecorder()
        let report = try await SQLiteMediaBackgroundReconciler(
            store: store,
            rootRegistry: fixture.registry
        ).run(
            at: Date(timeIntervalSinceReferenceDate: 500),
            metadataCommit: { _ in },
            progress: { update in
                progressRecorder.append(update)
            }
        )

        XCTAssertEqual(report.recoveredOperationCount, 0)
        XCTAssertEqual(report.selectedOperationCount, 1)
        XCTAssertEqual(report.completedOperationCount, 1)
        XCTAssertEqual(report.failedOperationCount, 0)
        XCTAssertEqual(progressRecorder.values.map(\.completed), [0, 1])
        let receipt = try await store.importReceipt(
            sourceTransferID: fixture.transfer.sourceTransferID
        )
        XCTAssertEqual(receipt?.outcome, .committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    func testBackgroundReconcilerFinishesReceiptAfterReopen() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let databaseURL = fixture.directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        _ = try await SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        ).enqueue(fixture.transfer)
        _ = try await SQLiteMediaFileOperationWorker(store: store).run(
            operationID: fixture.transfer.copyPlan.operationID,
            rootRegistry: fixture.registry,
            at: Date(timeIntervalSinceReferenceDate: 600)
        )
        let receiptBeforeReopen = try await store.importReceipt(
            sourceTransferID: fixture.transfer.sourceTransferID
        )
        XCTAssertNil(receiptBeforeReopen)

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let report = try await SQLiteMediaBackgroundReconciler(
            store: reopenedStore,
            rootRegistry: fixture.registry
        ).run(
            at: Date(timeIntervalSinceReferenceDate: 601),
            metadataCommit: { _ in }
        )

        XCTAssertEqual(report.selectedOperationCount, 1)
        XCTAssertEqual(report.completedOperationCount, 1)
        XCTAssertEqual(report.failedOperationCount, 0)
        let receipt = try await reopenedStore.importReceipt(
            sourceTransferID: fixture.transfer.sourceTransferID
        )
        XCTAssertEqual(receipt?.outcome, .committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    func testBackgroundReconcilerRecoversMetadataClaimAfterReopen() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let databaseURL = fixture.directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        _ = try await SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        ).enqueue(fixture.transfer)
        _ = try await SQLiteMediaFileOperationWorker(store: store).run(
            operationID: fixture.transfer.copyPlan.operationID,
            rootRegistry: fixture.registry,
            at: Date(timeIntervalSinceReferenceDate: 800)
        )
        let claimed = try await store.claimMediaMetadataAcknowledgement(
            id: fixture.transfer.copyPlan.operationID,
            at: Date(timeIntervalSinceReferenceDate: 801)
        )
        XCTAssertEqual(claimed.metadataState, SQLiteMediaMetadataState.committing)

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let recorder = SQLiteMediaMetadataCommitRecorder()
        let report = try await SQLiteMediaBackgroundReconciler(
            store: reopenedStore,
            rootRegistry: fixture.registry
        ).run(
            at: Date(timeIntervalSinceReferenceDate: 802),
            metadataCommit: { operation in
                recorder.append(operation)
            }
        )

        XCTAssertEqual(report.recoveredOperationCount, 1)
        XCTAssertEqual(report.selectedOperationCount, 1)
        XCTAssertEqual(report.completedOperationCount, 1)
        XCTAssertEqual(report.failedOperationCount, 0)
        XCTAssertEqual(recorder.states, [SQLiteMediaMetadataState.committing])
        let persistedOperation = try await reopenedStore.mediaFileOperation(
            id: fixture.transfer.copyPlan.operationID
        )
        let operation = try XCTUnwrap(persistedOperation)
        XCTAssertEqual(operation.metadataState, SQLiteMediaMetadataState.committed)
        XCTAssertEqual(
            operation.metadataAcknowledgedAt,
            Date(timeIntervalSinceReferenceDate: 802)
        )
        let recoveredReceipt = try await reopenedStore.importReceipt(
            sourceTransferID: fixture.transfer.sourceTransferID
        )
        XCTAssertNotNil(recoveredReceipt)
    }

    func testBackgroundReconcilerRecordsReceiptAfterMetadataAcknowledgementWasPersisted() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let databaseURL = fixture.directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        _ = try await SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        ).enqueue(fixture.transfer)
        _ = try await SQLiteMediaFileOperationWorker(store: store).run(
            operationID: fixture.transfer.copyPlan.operationID,
            rootRegistry: fixture.registry,
            at: Date(timeIntervalSinceReferenceDate: 900)
        )
        _ = try await store.claimMediaMetadataAcknowledgement(
            id: fixture.transfer.copyPlan.operationID,
            at: Date(timeIntervalSinceReferenceDate: 901)
        )
        _ = try await store.completeMediaMetadataAcknowledgement(
            id: fixture.transfer.copyPlan.operationID,
            at: Date(timeIntervalSinceReferenceDate: 902)
        )

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let recorder = SQLiteMediaMetadataCommitRecorder()
        let report = try await SQLiteMediaBackgroundReconciler(
            store: reopenedStore,
            rootRegistry: fixture.registry
        ).run(
            at: Date(timeIntervalSinceReferenceDate: 903),
            metadataCommit: { operation in
                recorder.append(operation)
            }
        )

        XCTAssertEqual(report.selectedOperationCount, 1)
        XCTAssertEqual(report.completedOperationCount, 1)
        XCTAssertEqual(report.failedOperationCount, 0)
        XCTAssertEqual(recorder.states, [])
        let receipt = try await reopenedStore.importReceipt(
            sourceTransferID: fixture.transfer.sourceTransferID
        )
        XCTAssertNotNil(receipt)
    }

    func testBackgroundReconcilerDoesNotReceiptChangedPublishedDestination() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let databaseURL = fixture.directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        _ = try await SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        ).enqueue(fixture.transfer)
        _ = try await SQLiteMediaFileOperationWorker(store: store).run(
            operationID: fixture.transfer.copyPlan.operationID,
            rootRegistry: fixture.registry,
            at: Date(timeIntervalSinceReferenceDate: 700)
        )
        try Data("changed-after-publication".utf8).write(to: fixture.destinationURL)

        let report = try await SQLiteMediaBackgroundReconciler(
            store: store,
            rootRegistry: fixture.registry
        ).run(
            at: Date(timeIntervalSinceReferenceDate: 701),
            metadataCommit: { _ in }
        )

        XCTAssertEqual(report.selectedOperationCount, 1)
        XCTAssertEqual(report.completedOperationCount, 0)
        XCTAssertEqual(report.failedOperationCount, 1)
        let receipt = try await store.importReceipt(
            sourceTransferID: fixture.transfer.sourceTransferID
        )
        XCTAssertNil(receipt)
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

private final class SQLiteMediaProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [SQLiteMediaReconciliationProgress] = []

    var values: [SQLiteMediaReconciliationProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: SQLiteMediaReconciliationProgress) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}

private enum SQLiteMediaMetadataCommitTestError: Error, Equatable {
    case rejected
}

private final class SQLiteMediaMetadataCommitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStates: [String] = []

    var states: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedStates
    }

    func append(_ operation: SQLiteMediaFileOperation) {
        lock.lock()
        storedStates.append(operation.metadataState)
        lock.unlock()
    }
}
