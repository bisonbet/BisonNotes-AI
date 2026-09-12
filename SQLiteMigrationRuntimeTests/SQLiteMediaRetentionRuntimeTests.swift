import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteMediaRetentionRuntimeTests: XCTestCase {
    func testApplicationRootMappingClassifiesObservedSandboxPaths() throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentsRoot = directory.appendingPathComponent("Documents")
        let applicationSupportRoot = directory.appendingPathComponent("ApplicationSupport")
        let temporaryRoot = directory.appendingPathComponent("Temporary")
        let shareContainerRoot = directory.appendingPathComponent("Shared")
        let mapping = try SQLiteApplicationMediaRootMapping(
            documentsRoot: documentsRoot,
            applicationSupportRoot: applicationSupportRoot,
            temporaryRoot: temporaryRoot,
            shareContainerRoot: shareContainerRoot
        )

        XCTAssertEqual(
            mapping.sourceURLs[.documentsInbox]?.standardizedFileURL.path,
            documentsRoot.appendingPathComponent("Inbox").standardizedFileURL.path
        )
        XCTAssertEqual(
            mapping.sourceURLs[.watchTransferStaging]?.standardizedFileURL.path,
            temporaryRoot.appendingPathComponent("WatchTransferStaging")
                .standardizedFileURL.path
        )
        XCTAssertEqual(
            mapping.sourceURLs[.shareInbox]?.standardizedFileURL.path,
            shareContainerRoot.appendingPathComponent("ShareInbox")
                .standardizedFileURL.path
        )
        let roots = try mapping.registry.roots(
            sourceRoot: SQLiteApplicationMediaRootID.documents.rawValue,
            destinationRoot: SQLiteApplicationMediaRootID.sqliteMedia.rawValue
        )
        XCTAssertEqual(
            roots.source[SQLiteApplicationMediaRootID.documents.rawValue]?.standardizedFileURL.path,
            documentsRoot.standardizedFileURL.path
        )
        XCTAssertEqual(
            roots.destination[SQLiteApplicationMediaRootID.sqliteMedia.rawValue]?
                .standardizedFileURL.path,
            applicationSupportRoot.appendingPathComponent("SQLiteMedia")
                .standardizedFileURL.path
        )
    }

    func testRetentionExecutorRemovesSourceAfterCommittedReceipt() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        let coordinator = SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        )
        _ = try await coordinator.reconcile(
            fixture.transfer,
            metadataCommit: { _ in }
        )
        let executor = SQLiteMediaSourceRetentionExecutor(
            store: store,
            rootRegistry: fixture.registry
        )

        let removed = try await executor.removeSourceIfEligible(
            sourceTransferID: fixture.transfer.sourceTransferID,
            operationID: fixture.transfer.copyPlan.operationID
        )
        XCTAssertEqual(removed.state, "completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destinationURL.path))

        let repeated = try await executor.removeSourceIfEligible(
            sourceTransferID: fixture.transfer.sourceTransferID,
            operationID: fixture.transfer.copyPlan.operationID
        )
        XCTAssertEqual(repeated.state, "completed")
    }

    func testRetentionExecutorRefusesPendingOperation() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        let coordinator = SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        )
        _ = try await coordinator.enqueue(fixture.transfer)
        let executor = SQLiteMediaSourceRetentionExecutor(
            store: store,
            rootRegistry: fixture.registry
        )

        do {
            _ = try await executor.removeSourceIfEligible(
                sourceTransferID: fixture.transfer.sourceTransferID,
                operationID: fixture.transfer.copyPlan.operationID
            )
            XCTFail("Expected pending operation to retain its source")
        } catch let error as SQLiteMediaSourceRetentionError {
            XCTAssertEqual(error, .sourceNotEligible)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    func testRetentionExecutorRefusesReceiptBeforeMetadataAcknowledgement() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: fixture.registry
        ).enqueue(fixture.transfer)
        _ = try await SQLiteMediaFileOperationWorker(store: store).run(
            operationID: fixture.transfer.copyPlan.operationID,
            rootRegistry: fixture.registry
        )
        _ = try await store.recordImportReceipt(
            sourceTransferID: fixture.transfer.sourceTransferID,
            destinationStorageID: fixture.transfer.copyPlan.assetID,
            outcome: .committed
        )

        let executor = SQLiteMediaSourceRetentionExecutor(
            store: store,
            rootRegistry: fixture.registry
        )
        do {
            _ = try await executor.removeSourceIfEligible(
                sourceTransferID: fixture.transfer.sourceTransferID,
                operationID: fixture.transfer.copyPlan.operationID
            )
            XCTFail("Expected a receipt without metadata acknowledgement to retain the source")
        } catch let error as SQLiteMediaSourceRetentionError {
            XCTAssertEqual(error, .sourceNotEligible)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    func testRetentionExecutorRefusesSourceDestinationAlias() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let sourceRoot = fixture.sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let aliasRegistry = try SQLiteMediaRootRegistry(
            sourceRoots: ["source": sourceRoot],
            destinationRoots: ["destination": sourceRoot]
        )
        let aliasPlan = SQLiteMediaCopyPlan(
            operationID: "alias-operation",
            assetID: "alias-asset",
            ownerStorageID: "recording-alias",
            ownerRevision: 1,
            sourceRoot: "source",
            sourceRelativePath: "incoming/recording.m4a",
            destinationRoot: "destination",
            destinationRelativePath: "incoming/recording.m4a",
            expectedByteLength: fixture.transfer.copyPlan.expectedByteLength,
            expectedSHA256: fixture.transfer.copyPlan.expectedSHA256
        )
        let transfer = SQLiteMediaTransferPlan(
            sourceTransferID: "alias-transfer",
            copyPlan: aliasPlan
        )
        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMediaTransferCoordinator(
            store: store,
            rootRegistry: aliasRegistry
        ).reconcile(
            transfer,
            metadataCommit: { _ in }
        )
        let executor = SQLiteMediaSourceRetentionExecutor(
            store: store,
            rootRegistry: aliasRegistry
        )

        do {
            _ = try await executor.removeSourceIfEligible(
                sourceTransferID: transfer.sourceTransferID,
                operationID: aliasPlan.operationID
            )
            XCTFail("Expected source and destination alias to be rejected")
        } catch let error as SQLiteMediaSourceRetentionError {
            XCTAssertEqual(error, .sourceDestinationAlias)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    func testRetentionExecutorRefusesDestinationDrift() async throws {
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
        try Data("changed-destination".utf8).write(to: fixture.destinationURL)
        let executor = SQLiteMediaSourceRetentionExecutor(
            store: store,
            rootRegistry: fixture.registry
        )

        do {
            _ = try await executor.removeSourceIfEligible(
                sourceTransferID: fixture.transfer.sourceTransferID,
                operationID: fixture.transfer.copyPlan.operationID
            )
            XCTFail("Expected changed destination to retain the source")
        } catch let error as SQLiteMediaSourceRetentionError {
            XCTAssertEqual(error, .sourceNotEligible)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    func testArchiveRestoreReconcilerCommitsMetadataBeforeRemovingSource() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let databaseURL = fixture.directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let plan = makeArchiveRestorePlan(from: fixture)
        _ = try await store.enqueueArchiveRestore(plan)
        let metadataRecorder = SQLiteArchiveRestoreMetadataRecorder()

        let report = try await SQLiteArchiveRestoreReconciler(
            store: store,
            rootRegistry: fixture.registry
        ).run { operation in
            metadataRecorder.record(operation)
        }

        XCTAssertEqual(report.recoveredOperationCount, 0)
        XCTAssertEqual(report.selectedOperationCount, 1)
        XCTAssertEqual(report.completedOperationCount, 1)
        XCTAssertEqual(report.failedOperationCount, 0)
        XCTAssertEqual(metadataRecorder.phases, [SQLiteArchiveRestorePhase.committingMetadata])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        let restoredURL = fixture.directory
            .appendingPathComponent("destination", isDirectory: true)
            .appendingPathComponent("restored", isDirectory: true)
            .appendingPathComponent("recording.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredURL.path))

        let persistedOperation = try await store.archiveRestoreOperation(id: plan.operationID)
        let operation = try XCTUnwrap(persistedOperation)
        XCTAssertEqual(operation.phase, SQLiteArchiveRestorePhase.completed)
        XCTAssertEqual(operation.attemptCount, 3)

        let repeatedReport = try await SQLiteArchiveRestoreReconciler(
            store: store,
            rootRegistry: fixture.registry
        ).run { operation in
            metadataRecorder.record(operation)
        }
        XCTAssertEqual(repeatedReport.selectedOperationCount, 0)
        XCTAssertEqual(metadataRecorder.phases, [SQLiteArchiveRestorePhase.committingMetadata])
    }

    func testArchiveRestoreMetadataFailureRetainsCopiedFileForRetry() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        let plan = makeArchiveRestorePlan(from: fixture)
        _ = try await store.enqueueArchiveRestore(plan)
        let metadataRecorder = SQLiteArchiveRestoreMetadataRecorder(failuresRemaining: 1)

        let failedReport = try await SQLiteArchiveRestoreReconciler(
            store: store,
            rootRegistry: fixture.registry
        ).run { operation in
            try metadataRecorder.recordOrFail(operation)
        }

        XCTAssertEqual(failedReport.completedOperationCount, 0)
        XCTAssertEqual(failedReport.failedOperationCount, 1)
        let persistedFailedOperation = try await store.archiveRestoreOperation(id: plan.operationID)
        let failedOperation = try XCTUnwrap(persistedFailedOperation)
        XCTAssertEqual(failedOperation.phase, SQLiteArchiveRestorePhase.metadataFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        let restoredURL = fixture.directory
            .appendingPathComponent("destination", isDirectory: true)
            .appendingPathComponent("restored", isDirectory: true)
            .appendingPathComponent("recording.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredURL.path))

        let retryReport = try await SQLiteArchiveRestoreReconciler(
            store: store,
            rootRegistry: fixture.registry
        ).run { operation in
            try metadataRecorder.recordOrFail(operation)
        }
        XCTAssertEqual(retryReport.completedOperationCount, 1)
        XCTAssertEqual(retryReport.failedOperationCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    func testArchiveRestoreMetadataRetryRefusesChangedDestination() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: fixture.directory.appendingPathComponent("library.sqlite")
        )
        let plan = makeArchiveRestorePlan(from: fixture)
        _ = try await store.enqueueArchiveRestore(plan)
        let metadataRecorder = SQLiteArchiveRestoreMetadataRecorder(failuresRemaining: 1)

        _ = try await SQLiteArchiveRestoreReconciler(
            store: store,
            rootRegistry: fixture.registry
        ).run { operation in
            try metadataRecorder.recordOrFail(operation)
        }
        let restoredURL = fixture.directory
            .appendingPathComponent("destination", isDirectory: true)
            .appendingPathComponent("restored", isDirectory: true)
            .appendingPathComponent("recording.m4a")
        try Data("changed-after-copy".utf8).write(to: restoredURL)

        let retryReport = try await SQLiteArchiveRestoreReconciler(
            store: store,
            rootRegistry: fixture.registry
        ).run { operation in
            try metadataRecorder.recordOrFail(operation)
        }

        XCTAssertEqual(retryReport.selectedOperationCount, 1)
        XCTAssertEqual(retryReport.completedOperationCount, 0)
        XCTAssertEqual(retryReport.failedOperationCount, 1)
        XCTAssertEqual(
            metadataRecorder.phases,
            [SQLiteArchiveRestorePhase.committingMetadata]
        )
        let failedOperation = try await store.archiveRestoreOperation(
            id: plan.operationID
        )
        XCTAssertEqual(
            failedOperation?.phase,
            SQLiteArchiveRestorePhase.metadataFailed
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    func testArchiveRestoreRecoversInFlightMetadataAndSourceDeletionPhases() async throws {
        let fixture = try makeMediaTransferFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let databaseURL = fixture.directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let plan = makeArchiveRestorePlan(from: fixture)
        _ = try await store.enqueueArchiveRestore(plan)
        let claimedCopy = try await store.claimArchiveRestoreCopy(id: plan.operationID)
        XCTAssertEqual(claimedCopy.phase, SQLiteArchiveRestorePhase.copying)
        let recoveredCopyCount = try await store.recoverInterruptedArchiveRestores()
        XCTAssertEqual(recoveredCopyCount, 1)
        let pendingOperation = try await store.archiveRestoreOperation(id: plan.operationID)
        XCTAssertEqual(pendingOperation?.phase, SQLiteArchiveRestorePhase.pending)

        let copied = try await SQLiteArchiveRestoreCopyWorker(store: store).run(
            operationID: plan.operationID,
            rootRegistry: fixture.registry
        )
        XCTAssertEqual(copied.phase, SQLiteArchiveRestorePhase.copied)
        let committing = try await store.claimArchiveRestoreMetadata(id: plan.operationID)
        XCTAssertEqual(committing.phase, SQLiteArchiveRestorePhase.committingMetadata)
        _ = try await store.recoverInterruptedArchiveRestores()
        let copiedAfterRecovery = try await store.archiveRestoreOperation(id: plan.operationID)
        XCTAssertEqual(copiedAfterRecovery?.phase, SQLiteArchiveRestorePhase.copied)
        _ = try await store.claimArchiveRestoreMetadata(id: plan.operationID)
        _ = try await store.completeArchiveRestoreMetadata(id: plan.operationID)
        let deleting = try await store.claimArchiveRestoreSourceDeletion(id: plan.operationID)
        XCTAssertEqual(deleting.phase, SQLiteArchiveRestorePhase.deletingSource)

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let recoveredDeleteCount = try await reopenedStore.recoverInterruptedArchiveRestores()
        XCTAssertEqual(recoveredDeleteCount, 1)
        let committedAfterRecovery = try await reopenedStore.archiveRestoreOperation(id: plan.operationID)
        XCTAssertEqual(committedAfterRecovery?.phase, SQLiteArchiveRestorePhase.metadataCommitted)
        let completed = try await SQLiteArchiveRestoreSourceDeletionWorker(
            store: reopenedStore
        ).run(
            operationID: plan.operationID,
            rootRegistry: fixture.registry
        )
        XCTAssertEqual(completed.phase, SQLiteArchiveRestorePhase.completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }
}

private func makeArchiveRestorePlan(
    from fixture: SQLiteMediaTransferFixture
) -> SQLiteArchiveRestorePlan {
    SQLiteArchiveRestorePlan(
        operationID: "archive-restore-operation",
        archiveLocationID: "archive-location-1",
        ownerStorageID: "recording-1",
        ownerRevision: 1,
        sourceRoot: "source",
        sourceRelativePath: "incoming/recording.m4a",
        destinationRoot: "destination",
        destinationRelativePath: "restored/recording.m4a",
        expectedByteLength: fixture.transfer.copyPlan.expectedByteLength,
        expectedSHA256: fixture.transfer.copyPlan.expectedSHA256
    )
}

private final class SQLiteArchiveRestoreMetadataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPhases: [String] = []
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    var phases: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedPhases
    }

    func record(_ operation: SQLiteArchiveRestoreOperation) {
        lock.lock()
        storedPhases.append(operation.phase)
        lock.unlock()
    }

    func recordOrFail(_ operation: SQLiteArchiveRestoreOperation) throws {
        lock.lock()
        storedPhases.append(operation.phase)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            lock.unlock()
            throw SQLiteArchiveRestoreTestError.metadataCommitFailed
        }
        lock.unlock()
    }
}

private enum SQLiteArchiveRestoreTestError: Error {
    case metadataCommitFailed
}
