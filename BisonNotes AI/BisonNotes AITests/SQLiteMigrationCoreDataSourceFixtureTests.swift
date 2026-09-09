import CoreData
import XCTest
@testable import BisonNotes_AI

final class CoreDataMigrationFixtureTests: XCTestCase {
    func testActiveModelFixtureEmitsAllSixEntitiesAndRelationships() throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("active.sqlite")
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: storeURL,
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let snapshot = fixture.snapshot
        XCTAssertEqual(snapshot.sourceModel, "BisonNotes_AI_v2")
        XCTAssertFalse(snapshot.sourceFingerprint.isEmpty)
        XCTAssertEqual(snapshot.rows.count, 6)
        XCTAssertEqual(
            Set(snapshot.rows.map(\.entity)),
            Set(SQLiteMigrationSourceEntity.allCases)
        )
        for row in snapshot.rows {
            XCTAssertEqual(Set(row.values.keys), row.entity.destinationColumns)
        }

        let rowsByEntity = Dictionary(uniqueKeysWithValues: snapshot.rows.map {
            ($0.entity, $0)
        })
        let recording = try XCTUnwrap(rowsByEntity[.recordings])
        let transcript = try XCTUnwrap(rowsByEntity[.transcripts])
        let summary = try XCTUnwrap(rowsByEntity[.summaries])
        let processingJob = try XCTUnwrap(rowsByEntity[.processingJobs])

        XCTAssertEqual(recording.values["recordingName"], .text("Fixture recording"))
        XCTAssertEqual(
            transcript.values["recordingStorageID"],
            .text(recording.destinationStorageID)
        )
        XCTAssertEqual(
            summary.values["recordingStorageID"],
            .text(recording.destinationStorageID)
        )
        XCTAssertEqual(
            summary.values["transcriptStorageID"],
            .text(transcript.destinationStorageID)
        )
        XCTAssertEqual(
            processingJob.values["recordingStorageID"],
            .text(recording.destinationStorageID)
        )
    }

    func testOriginalModelFixtureExcludesVersionTwoPendingMutations() throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("original.sqlite")
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: storeURL,
            version: .original
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertEqual(fixture.snapshot.sourceModel, "BisonNotes_AI")
        XCTAssertEqual(fixture.snapshot.rows.count, 5)
        XCTAssertFalse(
            fixture.snapshot.rows.contains { $0.entity == .pendingCloudMutations }
        )
        XCTAssertTrue(
            fixture.snapshot.rows.allSatisfy {
                Set($0.values.keys) == $0.entity.destinationColumns
            }
        )
    }

    func testSnapshotFingerprintChangesWhenSourceMetadataChanges() throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let storeURL = directory.appendingPathComponent("fingerprint.sqlite")
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: storeURL,
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let original = fixture.snapshot
        let context = fixture.container.viewContext
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RecordingEntry")
            let recording = try XCTUnwrap(context.fetch(request).first)
            recording.setValue("Changed fixture recording", forKey: "recordingName")
            try context.save()
        }
        let changed = try SQLiteMigrationCoreDataSourceFixtureFactory.snapshot(
            from: fixture.container,
            version: .active
        )

        XCTAssertNotEqual(changed.sourceFingerprint, original.sourceFingerprint)
        let changedRecording = try XCTUnwrap(
            changed.rows.first { $0.entity == .recordings }
        )
        XCTAssertEqual(
            changedRecording.values["recordingName"],
            .text("Changed fixture recording")
        )
    }
}
