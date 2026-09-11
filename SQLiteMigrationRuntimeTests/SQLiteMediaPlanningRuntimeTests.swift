import CryptoKit
import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteMediaPlanningRuntimeTests: XCTestCase {
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
