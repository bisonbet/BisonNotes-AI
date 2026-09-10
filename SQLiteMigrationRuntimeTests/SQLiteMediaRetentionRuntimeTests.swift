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
        _ = try await coordinator.reconcile(fixture.transfer)
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
        ).reconcile(transfer)
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
        ).reconcile(fixture.transfer)
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
}
