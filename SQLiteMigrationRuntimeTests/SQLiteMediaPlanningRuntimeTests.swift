import CryptoKit
import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteMediaPlanningRuntimeTests: XCTestCase {
    func testPlannerUsesExplicitDocumentsDestinationRoot() throws {
        let fixture = try makePlannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let sourceURL = fixture.documentsRoot
            .appendingPathComponent("Inbox", isDirectory: true)
            .appendingPathComponent("watch-recording.m4a")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("documents-destination".utf8).write(to: sourceURL)

        let plan = try SQLiteApplicationMediaTransferPlanner(
            mapping: fixture.mapping
        ).makePlan(
            SQLiteMediaTransferRequest(
                sourceTransferID: "documents-transfer-1",
                operationID: "documents-operation-1",
                assetID: "documents-asset-1",
                ownerStorageID: nil,
                ownerRevision: nil,
                sourceURL: sourceURL,
                destinationRootID: SQLiteApplicationMediaRootID.documents.rawValue,
                destinationRelativePath: "Imported/watch-recording.m4a"
            )
        )

        XCTAssertEqual(
            plan.copyPlan.destinationRoot,
            SQLiteApplicationMediaRootID.documents.rawValue
        )
        XCTAssertEqual(
            plan.copyPlan.destinationRelativePath,
            "Imported/watch-recording.m4a"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.documentsRoot
                    .appendingPathComponent("Imported/watch-recording.m4a")
                    .path
            )
        )
    }

    func testPlannerUsesMostSpecificDocumentsInboxRootAndFingerprintsSource() throws {
        let fixture = try makePlannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let sourceURL = fixture.documentsRoot
            .appendingPathComponent("Inbox", isDirectory: true)
            .appendingPathComponent("shared-recording.m4a")
        let data = Data("planner-fixture".utf8)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: sourceURL)

        let request = SQLiteMediaTransferRequest(
            sourceTransferID: "share-transfer-1",
            operationID: "operation-1",
            assetID: "asset-1",
            ownerStorageID: "recording-1",
            ownerRevision: 1,
            sourceURL: sourceURL,
            destinationRelativePath: "assets/asset-1.m4a"
        )
        let plan = try SQLiteApplicationMediaTransferPlanner(
            mapping: fixture.mapping
        ).makePlan(request)
        let expectedSHA256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(
            plan.copyPlan.sourceRoot,
            SQLiteApplicationMediaRootID.documentsInbox.rawValue
        )
        XCTAssertEqual(plan.copyPlan.sourceRelativePath, "shared-recording.m4a")
        XCTAssertEqual(plan.copyPlan.destinationRoot, SQLiteApplicationMediaRootID.sqliteMedia.rawValue)
        XCTAssertEqual(plan.copyPlan.expectedByteLength, Int64(data.count))
        XCTAssertEqual(plan.copyPlan.expectedSHA256, expectedSHA256)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.mapping.destinationURLs[.sqliteMedia]!.path
            )
        )
    }

    func testPlannerResolvesWatchTransferStagingRoot() throws {
        let fixture = try makePlannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let sourceURL = fixture.temporaryRoot
            .appendingPathComponent("WatchTransferStaging", isDirectory: true)
            .appendingPathComponent("watch-recording.m4a")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("watch-fixture".utf8).write(to: sourceURL)

        let request = SQLiteMediaTransferRequest(
            sourceTransferID: "watch-transfer-1",
            operationID: "operation-watch-1",
            assetID: "asset-watch-1",
            ownerStorageID: nil,
            ownerRevision: nil,
            sourceURL: sourceURL,
            destinationRelativePath: "assets/watch-1.m4a"
        )
        let plan = try SQLiteApplicationMediaTransferPlanner(
            mapping: fixture.mapping
        ).makePlan(request)

        XCTAssertEqual(
            plan.copyPlan.sourceRoot,
            SQLiteApplicationMediaRootID.watchTransferStaging.rawValue
        )
        XCTAssertEqual(plan.copyPlan.sourceRelativePath, "watch-recording.m4a")
    }

    func testPlannerRejectsSourceOutsideManagedRoots() throws {
        let fixture = try makePlannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let sourceURL = fixture.directory
            .appendingPathComponent("External", isDirectory: true)
            .appendingPathComponent("recording.m4a")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(to: sourceURL)

        XCTAssertThrowsError(
            try SQLiteApplicationMediaTransferPlanner(mapping: fixture.mapping).makePlan(
                SQLiteMediaTransferRequest(
                    sourceTransferID: "external-transfer",
                    operationID: "operation-external",
                    assetID: "asset-external",
                    ownerStorageID: nil,
                    ownerRevision: nil,
                    sourceURL: sourceURL,
                    destinationRelativePath: "assets/external.m4a"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SQLiteMediaPlanningError,
                .sourceOutsideManagedRoots
            )
        }
    }

    func testPlannerRejectsDirectorySource() throws {
        let fixture = try makePlannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let sourceURL = fixture.documentsRoot
            .appendingPathComponent("directory-recording.m4a", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try SQLiteApplicationMediaTransferPlanner(mapping: fixture.mapping).makePlan(
                SQLiteMediaTransferRequest(
                    sourceTransferID: "directory-transfer",
                    operationID: "operation-directory",
                    assetID: "asset-directory",
                    ownerStorageID: nil,
                    ownerRevision: nil,
                    sourceURL: sourceURL,
                    destinationRelativePath: "assets/directory.m4a"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SQLiteMediaPlanningError,
                .sourceNotRegularFile
            )
        }
    }

    func testArchiveRestorePlannerUsesBookmarkRootAndFingerprintsSource() throws {
        let fixture = try makePlannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let archiveRoot = fixture.directory.appendingPathComponent(
            "ResolvedArchive",
            isDirectory: true
        )
        let sourceURL = archiveRoot.appendingPathComponent(
            "Exports",
            isDirectory: true
        ).appendingPathComponent("restored-recording.m4a")
        let data = Data("archive-restore-planner-fixture".utf8)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: sourceURL)

        let plan = try SQLiteApplicationArchiveRestorePlanner(
            mapping: fixture.mapping
        ).makePlan(
            SQLiteArchiveRestoreRequest(
                operationID: "archive-restore-operation-1",
                archiveLocationID: "archive-location-1",
                ownerStorageID: "sqlite-recording-1",
                ownerRevision: 7,
                sourceRootID: "archive-bookmark-root-1",
                sourceRootURL: archiveRoot,
                sourceURL: sourceURL,
                destinationRelativePath: "recordings/recording-1.m4a"
            )
        )
        let expectedSHA256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(plan.sourceRoot, "archive-bookmark-root-1")
        XCTAssertEqual(plan.sourceRelativePath, "Exports/restored-recording.m4a")
        XCTAssertEqual(plan.destinationRoot, SQLiteApplicationMediaRootID.sqliteMedia.rawValue)
        XCTAssertEqual(plan.destinationRelativePath, "recordings/recording-1.m4a")
        XCTAssertEqual(plan.ownerRevision, 7)
        XCTAssertEqual(plan.expectedByteLength, Int64(data.count))
        XCTAssertEqual(plan.expectedSHA256, expectedSHA256)
        let registry = try fixture.mapping.registry(
            addingSourceRootID: plan.sourceRoot,
            url: archiveRoot
        )
        XCTAssertEqual(
            try registry.sourceURL(
                root: plan.sourceRoot,
                relativePath: plan.sourceRelativePath
            ),
            sourceURL.standardizedFileURL
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.mapping.destinationURLs[.sqliteMedia]!.path
            )
        )
    }

    func testArchiveRestorePlannerRejectsSourceOutsideResolvedBookmarkRoot() throws {
        let fixture = try makePlannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let archiveRoot = fixture.directory.appendingPathComponent(
            "ResolvedArchive",
            isDirectory: true
        )
        let outsideURL = fixture.directory.appendingPathComponent(
            "OutsideArchiveRoot",
            isDirectory: true
        ).appendingPathComponent("recording.m4a")
        try FileManager.default.createDirectory(
            at: archiveRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("outside-root".utf8).write(to: outsideURL)

        XCTAssertThrowsError(
            try SQLiteApplicationArchiveRestorePlanner(mapping: fixture.mapping).makePlan(
                SQLiteArchiveRestoreRequest(
                    operationID: "archive-restore-operation-outside",
                    archiveLocationID: "archive-location-outside",
                    ownerStorageID: nil,
                    ownerRevision: nil,
                    sourceRootID: "archive-bookmark-root-outside",
                    sourceRootURL: archiveRoot,
                    sourceURL: outsideURL,
                    destinationRelativePath: "recordings/outside.m4a"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SQLiteMediaPlanningError,
                .sourceOutsideManagedRoots
            )
        }
    }

    func testArchiveRestorePlannerRejectsSourceDestinationAlias() throws {
        let fixture = try makePlannerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let destinationRoot = try XCTUnwrap(
            fixture.mapping.destinationURLs[.sqliteMedia]
        )
        let sourceURL = destinationRoot.appendingPathComponent("same-file.m4a")
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        try Data("alias".utf8).write(to: sourceURL)

        XCTAssertThrowsError(
            try SQLiteApplicationArchiveRestorePlanner(mapping: fixture.mapping).makePlan(
                SQLiteArchiveRestoreRequest(
                    operationID: "archive-restore-operation-alias",
                    archiveLocationID: "archive-location-alias",
                    ownerStorageID: nil,
                    ownerRevision: nil,
                    sourceRootID: "archive-bookmark-root-alias",
                    sourceRootURL: destinationRoot,
                    sourceURL: sourceURL,
                    destinationRelativePath: "same-file.m4a"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SQLiteMediaPlanningError,
                .sourceDestinationAlias
            )
        }
    }
}

private struct SQLiteMediaPlannerFixture {
    let directory: URL
    let documentsRoot: URL
    let applicationSupportRoot: URL
    let temporaryRoot: URL
    let mapping: SQLiteApplicationMediaRootMapping
}

private func makePlannerFixture() throws -> SQLiteMediaPlannerFixture {
    let directory = try makeVerifierTemporaryDirectory()
    let documentsRoot = directory.appendingPathComponent("Documents", isDirectory: true)
    let applicationSupportRoot = directory.appendingPathComponent(
        "ApplicationSupport",
        isDirectory: true
    )
    let temporaryRoot = directory.appendingPathComponent("Temporary", isDirectory: true)
    return SQLiteMediaPlannerFixture(
        directory: directory,
        documentsRoot: documentsRoot,
        applicationSupportRoot: applicationSupportRoot,
        temporaryRoot: temporaryRoot,
        mapping: try SQLiteApplicationMediaRootMapping(
            documentsRoot: documentsRoot,
            applicationSupportRoot: applicationSupportRoot,
            temporaryRoot: temporaryRoot
        )
    )
}
