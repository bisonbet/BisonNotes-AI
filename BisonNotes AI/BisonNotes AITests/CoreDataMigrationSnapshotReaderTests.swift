import CoreData
import Foundation
import XCTest
@testable import BisonNotes_AI

final class CoreDataMigrationSnapshotReaderTests: XCTestCase {
    func testReadsAllActiveMetadataEntitiesWithoutAudioBytes() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("snapshot-reader.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let snapshot = try await CoreDataMigrationSnapshotReader(
            container: fixture.container,
            sourceModel: fixture.modelVersion.rawValue
        ).snapshot()

        XCTAssertEqual(snapshot.sourceModel, "BisonNotes_AI_v2")
        XCTAssertEqual(snapshot.rows.count, 6)
        XCTAssertEqual(snapshot.rows.map(\.entity), [
            .archiveLocations,
            .pendingCloudMutations,
            .processingJobs,
            .recordings,
            .summaries,
            .transcripts
        ])
        XCTAssertEqual(snapshot.sourceFingerprint.count, 64)
        XCTAssertTrue(snapshot.rows.allSatisfy { !$0.sourceObjectID.isEmpty })

        try assertActiveSnapshot(snapshot)
    }

    private func assertActiveSnapshot(
        _ snapshot: SQLiteMigrationSourceSnapshot
    ) throws {
        let recordings = try XCTUnwrap(snapshot.rows.first { $0.entity == .recordings })
        let transcripts = try XCTUnwrap(snapshot.rows.first { $0.entity == .transcripts })
        let summaries = try XCTUnwrap(snapshot.rows.first { $0.entity == .summaries })
        let processingJob = try XCTUnwrap(snapshot.rows.first { $0.entity == .processingJobs })
        let archiveLocation = try XCTUnwrap(snapshot.rows.first { $0.entity == .archiveLocations })
        let pendingMutation = try XCTUnwrap(snapshot.rows.first { $0.entity == .pendingCloudMutations })

        XCTAssertEqual(
            recordings.sourceObjectID,
            "recordings|id|10000000-0000-0000-0000-000000000001"
        )
        XCTAssertEqual(
            recordings.values["recordingName"],
            .text("Fixture recording")
        )
        XCTAssertEqual(recordings.values["fileSize"], .integer(42))
        XCTAssertEqual(recordings.values["recordingURL"], .text("recording.m4a"))

        XCTAssertEqual(
            transcripts.values["recordingStorageID"],
            .text(recordings.destinationStorageID)
        )
        XCTAssertEqual(
            summaries.values["recordingStorageID"],
            .text(recordings.destinationStorageID)
        )
        XCTAssertEqual(
            summaries.values["transcriptStorageID"],
            .text(transcripts.destinationStorageID)
        )
        XCTAssertEqual(
            processingJob.values["recordingStorageID"],
            .text(recordings.destinationStorageID)
        )
        XCTAssertEqual(
            archiveLocation.values["recordingId"],
            .text("10000000-0000-0000-0000-000000000001")
        )
        XCTAssertEqual(pendingMutation.values["payload"], .blob(Data([4, 5, 6])))
        XCTAssertTrue(pendingMutation.sourceObjectID.hasPrefix("pending_cloud_mutations|uri|"))
    }

    func testSkipsPendingMutationEntityForOriginalModel() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("snapshot-reader-original.sqlite"),
            version: .original
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let snapshot = try await CoreDataMigrationSnapshotReader(
            container: fixture.container,
            sourceModel: fixture.modelVersion.rawValue
        ).snapshot()

        XCTAssertEqual(snapshot.rows.count, 5)
        XCTAssertFalse(snapshot.rows.contains { $0.entity == .pendingCloudMutations })
        XCTAssertEqual(snapshot.sourceModel, "BisonNotes_AI")
    }
}
