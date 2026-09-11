import CoreData
import Foundation
import XCTest
@testable import BisonNotes_AI

final class LibraryRepositoryContractTests: XCTestCase {
    func testCoreDataRepositoryAccessWaitsBehindSharedMaintenanceGate() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-gated.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let gate = LibraryMaintenanceGate()
        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext,
            maintenanceGate: gate
        )
        let exclusiveLease = try await gate.acquireExclusive()
        let writeTask = Task {
            try await repository.renameRecording(
                LibraryRecordingRenameCommand(
                    reference: LibraryRecordingReference(
                        legacyID: "10000000-0000-0000-0000-000000000001"
                    ),
                    name: "Gated recording",
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 300)
                )
            )
        }

        for _ in 0..<100 where await gate.status().waitingNormalCount != 1 {
            await Task.yield()
        }
        let waitingStatus = await gate.status()
        XCTAssertEqual(waitingStatus.waitingNormalCount, 1)

        await exclusiveLease.release()
        let updated = try await writeTask.value
        XCTAssertEqual(updated.name, "Gated recording")
        let finalStatus = await gate.status()
        XCTAssertEqual(finalStatus.activeNormalCount, 0)
    }

    func testCoreDataRepositoryReturnsStorageNeutralRecordingSnapshot() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let recordings = try await repository.fetchRecordingSummaries()

        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].legacyID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(recordings[0].name, "Fixture recording")
        XCTAssertEqual(recordings[0].recordingDate, Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(recordings[0].duration, 7.5)
        XCTAssertEqual(recordings[0].fileSize, 42)
        XCTAssertEqual(recordings[0].recordingURL, "recording.m4a")
        XCTAssertEqual(recordings[0].isArchived, false)
        XCTAssertEqual(recordings[0].isCloudSyncDisabled, false)
        XCTAssertEqual(recordings[0].lastModified, Date(timeIntervalSinceReferenceDate: 101))
    }

    func testCoreDataRepositoryReturnsAllMetadataSnapshots() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-all.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let transcripts = try await repository.fetchTranscriptSnapshots()
        let summaries = try await repository.fetchSummarySnapshots()
        let processingJobs = try await repository.fetchProcessingJobSnapshots()
        let archiveLocations = try await repository.fetchArchiveLocationSnapshots()
        let pendingMutations = try await repository.fetchPendingCloudMutationSnapshots()

        let recordingStorageID = "core-data-recording-10000000-0000-0000-0000-000000000001"
        let transcriptStorageID = "core-data-transcript-10000000-0000-0000-0000-000000000002"

        try assertTranscript(
            try XCTUnwrap(transcripts.first),
            recordingStorageID: recordingStorageID
        )
        try assertSummary(
            try XCTUnwrap(summaries.first),
            recordingStorageID: recordingStorageID,
            transcriptStorageID: transcriptStorageID
        )
        try assertProcessingJob(
            try XCTUnwrap(processingJobs.first),
            recordingStorageID: recordingStorageID
        )
        try assertArchiveLocation(try XCTUnwrap(archiveLocations.first))
        try assertPendingMutation(try XCTUnwrap(pendingMutations.first))
    }

    func testCoreDataRepositoryRenamesRecordingThroughStorageNeutralCommand() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-rename.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let recordingID = "10000000-0000-0000-0000-000000000001"
        let updated = try await repository.renameRecording(
            LibraryRecordingRenameCommand(
                reference: LibraryRecordingReference(legacyID: recordingID),
                name: "Renamed [Watch]",
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 101),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 300)
            )
        )

        XCTAssertEqual(updated.legacyID, recordingID)
        XCTAssertEqual(updated.name, "Renamed")
        XCTAssertEqual(updated.lastModified, Date(timeIntervalSinceReferenceDate: 300))
        let persistedRecordings = try await repository.fetchRecordingSummaries()
        XCTAssertEqual(persistedRecordings.first?.name, "Renamed")
    }

    func testCoreDataRepositoryCloudSyncToggleCommitsRecordingAndPendingMutationTogether() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-cloud-sync.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let recordingID = "10000000-0000-0000-0000-000000000001"
        let disabled = try await repository.setCloudSyncDisabled(
            LibraryRecordingCloudSyncCommand(
                reference: LibraryRecordingReference(legacyID: recordingID),
                disabled: true,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 101),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 300),
                requestedAt: Date(timeIntervalSinceReferenceDate: 250)
            )
        )

        XCTAssertEqual(disabled.isCloudSyncDisabled, true)
        XCTAssertEqual(disabled.lastModified, Date(timeIntervalSinceReferenceDate: 300))
        let pendingAfterDisable = try await repository.fetchPendingCloudMutationSnapshots()
            .filter { $0.kind == PendingCloudMutationKind.localOnlyRemoval.rawValue }
        XCTAssertEqual(pendingAfterDisable.count, 1)
        XCTAssertEqual(pendingAfterDisable[0].targetID, recordingID)
        XCTAssertEqual(
            pendingAfterDisable[0].requestedAt,
            Date(timeIntervalSinceReferenceDate: 250)
        )

        let enabled = try await repository.setCloudSyncDisabled(
            LibraryRecordingCloudSyncCommand(
                reference: LibraryRecordingReference(legacyID: recordingID),
                disabled: false,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 300),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        XCTAssertEqual(enabled.isCloudSyncDisabled, false)
        XCTAssertEqual(enabled.lastModified, Date(timeIntervalSinceReferenceDate: 301))
        let pendingAfterEnable = try await repository.fetchPendingCloudMutationSnapshots()
            .filter { $0.kind == PendingCloudMutationKind.localOnlyRemoval.rawValue }
        XCTAssertTrue(pendingAfterEnable.isEmpty)
    }

    func testCoreDataRepositoryReplacesTranscriptByRecordingAndPreservesIdentity() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-transcript-upsert.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let updated = try await repository.upsertTranscript(
            LibraryTranscriptUpsertCommand(
                id: try XCTUnwrap(
                    UUID(uuidString: "10000000-0000-0000-0000-000000000015")
                ),
                recordingReference: LibraryRecordingReference(
                    legacyID: "10000000-0000-0000-0000-000000000001"
                ),
                createdAt: Date(timeIntervalSinceReferenceDate: 300),
                segments: "[{\"text\":\"replacement\"}]",
                speakerMappings: "{\"Speaker 1\":\"A\"}",
                engine: "replacement-engine",
                processingTime: 4.5,
                confidence: 0.91,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        XCTAssertEqual(
            updated.storageID,
            "core-data-transcript-10000000-0000-0000-0000-000000000002"
        )
        XCTAssertEqual(updated.legacyID, "10000000-0000-0000-0000-000000000002")
        XCTAssertEqual(updated.createdAt, Date(timeIntervalSinceReferenceDate: 102))
        XCTAssertEqual(updated.lastModified, Date(timeIntervalSinceReferenceDate: 301))
        XCTAssertEqual(updated.engine, "replacement-engine")
        XCTAssertEqual(updated.processingTime, 4.5)
        XCTAssertEqual(updated.confidence, 0.91)
        XCTAssertEqual(updated.segments, "[{\"text\":\"replacement\"}]")
        XCTAssertEqual(updated.speakerMappings, "{\"Speaker 1\":\"A\"}")

        let persisted = try await repository.fetchTranscriptSnapshots()
        XCTAssertEqual(persisted, [updated])
        let recordings = try await repository.fetchRecordingSummaries()
        XCTAssertEqual(recordings.first?.lastModified, Date(timeIntervalSinceReferenceDate: 301))
    }

    func testCoreDataRepositoryUpdatesArchiveStateWithExpectedRevision() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-archive-state.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let archived = try await repository.setArchiveState(
            LibraryRecordingArchiveCommand(
                reference: LibraryRecordingReference(
                    legacyID: "10000000-0000-0000-0000-000000000001"
                ),
                archived: true,
                archivedAt: Date(timeIntervalSinceReferenceDate: 301),
                archiveNote: "Exported to iCloud Drive",
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 101),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        XCTAssertEqual(archived.isArchived, true)
        XCTAssertEqual(archived.archivedAt, Date(timeIntervalSinceReferenceDate: 301))
        XCTAssertEqual(archived.archiveNote, "Exported to iCloud Drive")
        XCTAssertEqual(archived.lastModified, Date(timeIntervalSinceReferenceDate: 301))

        let restored = try await repository.setArchiveState(
            LibraryRecordingArchiveCommand(
                reference: LibraryRecordingReference(
                    legacyID: "10000000-0000-0000-0000-000000000001"
                ),
                archived: false,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 301),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 302)
            )
        )

        XCTAssertEqual(restored.isArchived, false)
        XCTAssertNil(restored.archivedAt)
        XCTAssertNil(restored.archiveNote)
        XCTAssertEqual(restored.lastModified, Date(timeIntervalSinceReferenceDate: 302))
    }

    func testCoreDataRepositoryCreatesArchiveLocationWithStableIdentityAndRetryDoesNotDuplicate() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-archive-location.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let archiveID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000017")
        )
        let command = LibraryArchiveLocationUpsertCommand(
            id: archiveID,
            recordingReference: LibraryRecordingReference(
                legacyID: "10000000-0000-0000-0000-000000000001"
            ),
            bookmarkData: Data([9, 8, 7]),
            destinationURLString: "archive://repository-retry",
            displayName: "Repository archive",
            exportedAt: Date(timeIntervalSinceReferenceDate: 401),
            exportedFilename: "repository.m4a",
            fileSize: 42,
            lastVerifiedAt: Date(timeIntervalSinceReferenceDate: 402),
            providerDisplayName: "Fixture provider",
            status: "available",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 403)
        )

        let created = try await repository.upsertArchiveLocation(command)
        let retried = try await repository.upsertArchiveLocation(command)
        let locations = try await repository.fetchArchiveLocationSnapshots()

        XCTAssertEqual(created, retried)
        XCTAssertEqual(created.legacyID, archiveID.uuidString)
        XCTAssertEqual(created.bookmarkData, Data([9, 8, 7]))
        XCTAssertEqual(created.destinationURLString, "archive://repository-retry")
        XCTAssertEqual(
            created.recordingLegacyID,
            "10000000-0000-0000-0000-000000000001"
        )
        XCTAssertEqual(locations.count, 2)
        XCTAssertEqual(locations.filter { $0.storageID == created.storageID }.count, 1)
    }

    func testCoreDataRepositoryReplacesSummaryByRecordingAndPreservesIdentity() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-summary-upsert.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let updated = try await repository.upsertSummary(
            LibrarySummaryUpsertCommand(
                id: try XCTUnwrap(
                    UUID(uuidString: "10000000-0000-0000-0000-000000000019")
                ),
                recordingReference: LibraryRecordingReference(
                    legacyID: "10000000-0000-0000-0000-000000000001"
                ),
                transcriptID: try XCTUnwrap(
                    UUID(uuidString: "10000000-0000-0000-0000-000000000002")
                ),
                summary: "This replacement summary is long enough to be persisted safely.",
                tasks: "[{\"text\":\"replacement task\"}]",
                reminders: "[{\"text\":\"replacement reminder\"}]",
                titles: "[{\"text\":\"Replacement title\"}]",
                contentType: "meeting",
                aiMethod: "{\"engine\":\"replacement-engine\",\"model\":\"replacement-model\"}",
                generatedAt: Date(timeIntervalSinceReferenceDate: 301),
                version: 2,
                wordCount: 9,
                originalLength: 48,
                compressionRatio: 0.19,
                confidence: 0.88,
                processingTime: 3.5
            )
        )

        XCTAssertEqual(
            updated.storageID,
            "core-data-summary-10000000-0000-0000-0000-000000000003"
        )
        XCTAssertEqual(updated.legacyID, "10000000-0000-0000-0000-000000000003")
        XCTAssertEqual(updated.generatedAt, Date(timeIntervalSinceReferenceDate: 301))
        XCTAssertEqual(updated.aiMethod, "{\"engine\":\"replacement-engine\",\"model\":\"replacement-model\"}")
        XCTAssertEqual(updated.contentType, "meeting")
        XCTAssertEqual(updated.summary, "This replacement summary is long enough to be persisted safely.")
        XCTAssertEqual(updated.tasks, "[{\"text\":\"replacement task\"}]")
        XCTAssertEqual(updated.reminders, "[{\"text\":\"replacement reminder\"}]")
        XCTAssertEqual(updated.titles, "[{\"text\":\"Replacement title\"}]")
        XCTAssertEqual(
            updated.transcriptStorageID,
            "core-data-transcript-10000000-0000-0000-0000-000000000002"
        )
        XCTAssertEqual(updated.transcriptLegacyID, "10000000-0000-0000-0000-000000000002")
        XCTAssertEqual(updated.version, 2)
        XCTAssertEqual(updated.wordCount, 9)

        let persisted = try await repository.fetchSummarySnapshots()
        XCTAssertEqual(persisted, [updated])
        let recordings = try await repository.fetchRecordingSummaries()
        XCTAssertEqual(recordings.first?.lastModified, Date(timeIntervalSinceReferenceDate: 301))
    }

    func testCoreDataRepositoryUpdatesProcessingJobWithoutExposingManagedObject() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-processing-job.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let jobID = "10000000-0000-0000-0000-000000000004"
        let failed = try await repository.updateProcessingJob(
            LibraryProcessingJobUpdateCommand(
                reference: LibraryProcessingJobReference(legacyID: jobID),
                status: "Failed",
                progress: 0.75,
                error: .set("Processing failed"),
                completionTime: .set(Date(timeIntervalSinceReferenceDate: 300)),
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 105),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        XCTAssertEqual(failed.status, "Failed")
        XCTAssertEqual(failed.progress, 0.75)
        XCTAssertEqual(failed.error, "Processing failed")
        XCTAssertEqual(
            failed.completionTime,
            Date(timeIntervalSinceReferenceDate: 300)
        )
        XCTAssertEqual(failed.lastModified, Date(timeIntervalSinceReferenceDate: 301))

        let preserved = try await repository.updateProcessingJob(
            LibraryProcessingJobUpdateCommand(
                reference: LibraryProcessingJobReference(legacyID: jobID),
                status: "Processing",
                progress: 0.8,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 301),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 302)
            )
        )

        XCTAssertEqual(preserved.error, "Processing failed")
        XCTAssertEqual(
            preserved.completionTime,
            Date(timeIntervalSinceReferenceDate: 300)
        )
        XCTAssertEqual(preserved.lastModified, Date(timeIntervalSinceReferenceDate: 302))

        let persisted = try await repository.fetchProcessingJobSnapshots()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0], preserved)
    }

    func testCoreDataRepositoryCreatesProcessingJobWithRecordingLink() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-processing-job-create.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let jobID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000006")
        )
        let created = try await repository.createProcessingJob(
            LibraryProcessingJobCreateCommand(
                id: jobID,
                jobType: "Summarization (mlxSwift)",
                engine: "mlxSwift",
                recordingURL: "recording.m4a",
                recordingName: "Fixture recording",
                modelName: "fixture-model",
                status: "Queued",
                progress: 0,
                startTime: Date(timeIntervalSinceReferenceDate: 300),
                recordingReference: LibraryRecordingReference(
                    legacyID: "10000000-0000-0000-0000-000000000001"
                ),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        XCTAssertEqual(created.legacyID, jobID.uuidString.lowercased())
        XCTAssertEqual(
            created.storageID,
            "core-data-processingjob-\(jobID.uuidString.lowercased())"
        )
        XCTAssertEqual(
            created.recordingStorageID,
            "core-data-recording-10000000-0000-0000-0000-000000000001"
        )
        XCTAssertEqual(created.status, "Queued")
        XCTAssertEqual(created.progress, 0)
        XCTAssertEqual(created.startTime, Date(timeIntervalSinceReferenceDate: 300))
        XCTAssertEqual(created.lastModified, Date(timeIntervalSinceReferenceDate: 301))

        do {
            _ = try await repository.createProcessingJob(
                LibraryProcessingJobCreateCommand(
                    id: jobID,
                    jobType: "Summarization (mlxSwift)",
                    engine: "mlxSwift",
                    recordingURL: "recording.m4a",
                    recordingName: "Fixture recording",
                    status: "Queued",
                    progress: 0,
                    startTime: Date(timeIntervalSinceReferenceDate: 302),
                    recordingReference: LibraryRecordingReference(
                        legacyID: "10000000-0000-0000-0000-000000000001"
                    ),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 303)
                )
            )
            XCTFail("Expected duplicate processing-job creation to fail")
        } catch let error as LibraryRepositoryError {
            XCTAssertEqual(
                error,
                .processingJobAlreadyExists(reference: jobID.uuidString.lowercased())
            )
        }
    }

    func testCoreDataRepositoryDeletesProcessingJobWithRevisionGuard() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-processing-job-delete.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let jobID = "10000000-0000-0000-0000-000000000004"
        let deleted = try await repository.deleteProcessingJob(
            LibraryProcessingJobDeleteCommand(
                reference: LibraryProcessingJobReference(legacyID: jobID),
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 105),
                deletedAt: Date(timeIntervalSinceReferenceDate: 305)
            )
        )

        XCTAssertEqual(deleted.legacyID, jobID)
        let jobsAfterDelete = try await repository.fetchProcessingJobSnapshots()
        XCTAssertTrue(jobsAfterDelete.isEmpty)

        do {
            _ = try await repository.deleteProcessingJob(
                LibraryProcessingJobDeleteCommand(
                    reference: LibraryProcessingJobReference(legacyID: jobID),
                    deletedAt: Date(timeIntervalSinceReferenceDate: 306)
                )
            )
            XCTFail("Expected deleting a missing processing job to fail")
        } catch let error as LibraryRepositoryError {
            XCTAssertEqual(
                error,
                .processingJobNotFound(reference: jobID)
            )
        }
    }

    func testCoreDataRepositoryDeletesTerminalProcessingJobsCaseInsensitively() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-processing-job-terminal-cleanup.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        _ = try await repository.updateProcessingJob(
            LibraryProcessingJobUpdateCommand(
                reference: LibraryProcessingJobReference(
                    legacyID: "10000000-0000-0000-0000-000000000004"
                ),
                status: "Completed",
                progress: 1,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 105),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        let terminalID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000011")
        )
        let activeID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000012")
        )
        for (id, status) in [(terminalID, " CANCELLED "), (activeID, "Processing")] {
            _ = try await repository.createProcessingJob(
                LibraryProcessingJobCreateCommand(
                    id: id,
                    jobType: "Test job",
                    engine: "fixture-engine",
                    recordingURL: "recording.m4a",
                    recordingName: "Fixture recording",
                    status: status,
                    progress: status.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == "processing" ? 0.5 : 1,
                    startTime: Date(timeIntervalSinceReferenceDate: 302),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 303)
                )
            )
        }

        let deleted = try await repository.deleteTerminalProcessingJobs(
            LibraryProcessingJobTerminalCleanupCommand(
                deletedAt: Date(timeIntervalSinceReferenceDate: 304)
            )
        )

        XCTAssertEqual(deleted.count, 2)
        XCTAssertEqual(
            Set(
                deleted.compactMap(\.status).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            ),
            Set(["completed", "cancelled"])
        )
        let remaining = try await repository.fetchProcessingJobSnapshots()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].status, "Processing")
    }

    func testCoreDataRepositoryRecoversKnownUnfinishedJobsAfterCrash() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository-processing-job-crash-recovery.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let existingJobID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000004")
        )
        _ = try await repository.updateProcessingJob(
            LibraryProcessingJobUpdateCommand(
                reference: LibraryProcessingJobReference(
                    legacyID: existingJobID.uuidString
                ),
                status: "Processing",
                progress: 0.4,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 105),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        let completedJobID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000021")
        )
        let queuedJobID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000022")
        )
        for (id, status, progress) in [
            (completedJobID, "Completed", 1.0),
            (queuedJobID, "queued", 0.0)
        ] {
            _ = try await repository.createProcessingJob(
                LibraryProcessingJobCreateCommand(
                    id: id,
                    jobType: "Test job",
                    engine: "fixture-engine",
                    recordingURL: "recording.m4a",
                    recordingName: "Fixture recording",
                    status: status,
                    progress: progress,
                    startTime: Date(timeIntervalSinceReferenceDate: 302),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 303)
                )
            )
        }

        let failureMessage = "Not restarted because the previous app session crashed."
        let recovered = try await repository.recoverProcessingJobsAfterCrash(
            LibraryProcessingJobCrashRecoveryCommand(
                references: [
                    existingJobID,
                    completedJobID,
                    queuedJobID
                ].map {
                    LibraryProcessingJobReference(legacyID: $0.uuidString)
                },
                failureMessage: failureMessage,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 304)
            )
        )

        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(
            Set(recovered.compactMap(\.legacyID)),
            Set([
                existingJobID.uuidString.lowercased(),
                queuedJobID.uuidString.lowercased()
            ])
        )
        for snapshot in recovered {
            XCTAssertEqual(snapshot.status, "Failed")
            XCTAssertEqual(snapshot.error, failureMessage)
            XCTAssertEqual(snapshot.completionTime, Date(timeIntervalSinceReferenceDate: 304))
            XCTAssertEqual(snapshot.lastModified, Date(timeIntervalSinceReferenceDate: 304))
        }
        let persisted = try await repository.fetchProcessingJobSnapshots()
        let completed = try XCTUnwrap(
            persisted.first { $0.legacyID == completedJobID.uuidString.lowercased() }
        )
        XCTAssertEqual(completed.status, "Completed")
        XCTAssertNil(completed.error)
    }

    private func assertTranscript(
        _ transcript: LibraryTranscriptSnapshot,
        recordingStorageID: String
    ) throws {
        XCTAssertEqual(transcript.legacyID, "10000000-0000-0000-0000-000000000002")
        XCTAssertEqual(transcript.confidence, 0.98)
        XCTAssertEqual(transcript.createdAt, Date(timeIntervalSinceReferenceDate: 102))
        XCTAssertEqual(transcript.engine, "fixture-engine")
        XCTAssertEqual(transcript.lastModified, Date(timeIntervalSinceReferenceDate: 103))
        XCTAssertEqual(transcript.processingTime, 1.5)
        XCTAssertEqual(transcript.recordingStorageID, recordingStorageID)
        XCTAssertEqual(transcript.recordingLegacyID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(transcript.segments, "{\"segments\":[]}")
        XCTAssertEqual(transcript.speakerMappings, "{}")
    }

    private func assertSummary(
        _ summary: LibrarySummarySnapshot,
        recordingStorageID: String,
        transcriptStorageID: String
    ) throws {
        XCTAssertEqual(summary.legacyID, "10000000-0000-0000-0000-000000000003")
        XCTAssertEqual(summary.aiMethod, "fixture-model")
        XCTAssertEqual(summary.compressionRatio, 0.25)
        XCTAssertEqual(summary.confidence, 0.9)
        XCTAssertEqual(summary.contentType, "summary")
        XCTAssertEqual(summary.generatedAt, Date(timeIntervalSinceReferenceDate: 104))
        XCTAssertEqual(summary.originalLength, 12)
        XCTAssertEqual(summary.processingTime, 2)
        XCTAssertEqual(summary.recordingStorageID, recordingStorageID)
        XCTAssertEqual(summary.recordingLegacyID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(summary.reminders, "[{\"text\":\"follow up\"}]")
        XCTAssertEqual(summary.summary, "Fixture summary")
        XCTAssertEqual(summary.tasks, "[{\"text\":\"task\"}]")
        XCTAssertEqual(summary.titles, "[{\"text\":\"Fixture\"}]")
        XCTAssertEqual(summary.transcriptStorageID, transcriptStorageID)
        XCTAssertEqual(summary.transcriptLegacyID, "10000000-0000-0000-0000-000000000002")
        XCTAssertEqual(summary.version, 1)
        XCTAssertEqual(summary.wordCount, 2)
    }

    private func assertProcessingJob(
        _ processingJob: LibraryProcessingJobSnapshot,
        recordingStorageID: String
    ) throws {
        XCTAssertEqual(processingJob.legacyID, "10000000-0000-0000-0000-000000000004")
        XCTAssertEqual(processingJob.completionTime, Date(timeIntervalSinceReferenceDate: 106))
        XCTAssertEqual(processingJob.engine, "fixture-engine")
        XCTAssertNil(processingJob.error)
        XCTAssertEqual(processingJob.jobType, "transcription")
        XCTAssertEqual(processingJob.lastModified, Date(timeIntervalSinceReferenceDate: 105))
        XCTAssertEqual(processingJob.modelName, "fixture-model")
        XCTAssertEqual(processingJob.progress, 1)
        XCTAssertEqual(processingJob.recordingName, "Fixture recording")
        XCTAssertEqual(processingJob.recordingURL, "recording.m4a")
        XCTAssertEqual(processingJob.recordingStorageID, recordingStorageID)
        XCTAssertEqual(processingJob.startTime, Date(timeIntervalSinceReferenceDate: 104))
        XCTAssertEqual(processingJob.status, "complete")
    }

    private func assertArchiveLocation(
        _ archiveLocation: LibraryArchiveLocationSnapshot
    ) throws {
        XCTAssertEqual(archiveLocation.legacyID, "10000000-0000-0000-0000-000000000005")
        XCTAssertEqual(archiveLocation.bookmarkData, Data([1, 2, 3]))
        XCTAssertEqual(archiveLocation.destinationURLString, "archive://fixture")
        XCTAssertEqual(archiveLocation.displayName, "Fixture archive")
        XCTAssertEqual(archiveLocation.exportedAt, Date(timeIntervalSinceReferenceDate: 106))
        XCTAssertEqual(archiveLocation.exportedFilename, "fixture.m4a")
        XCTAssertEqual(archiveLocation.fileSize, 42)
        XCTAssertEqual(archiveLocation.lastVerifiedAt, Date(timeIntervalSinceReferenceDate: 107))
        XCTAssertEqual(archiveLocation.providerDisplayName, "Fixture provider")
        XCTAssertEqual(archiveLocation.recordingLegacyID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(archiveLocation.status, "verified")
    }

    private func assertPendingMutation(
        _ pendingMutation: LibraryPendingCloudMutationSnapshot
    ) throws {
        XCTAssertEqual(pendingMutation.kind, "update")
        XCTAssertEqual(pendingMutation.payload, Data([4, 5, 6]))
        XCTAssertEqual(pendingMutation.recordingLegacyID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(pendingMutation.requestedAt, Date(timeIntervalSinceReferenceDate: 108))
        XCTAssertEqual(pendingMutation.targetID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(pendingMutation.version, 1)
    }
}
