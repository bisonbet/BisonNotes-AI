import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteLibraryRepositoryRuntimeTests: XCTestCase {
    func testRepositoryAccessWaitsBehindSharedMaintenanceGate() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            makeVerifierSnapshot(migrationRunID: nil),
            into: store,
            batchSize: 10,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )

        let gate = LibraryMaintenanceGate()
        let repository = SQLiteLibraryRepository(store: store, maintenanceGate: gate)
        let exclusiveLease = try await gate.acquireExclusive()
        let writeTask = Task {
            try await repository.renameRecording(
                LibraryRecordingRenameCommand(
                    reference: LibraryRecordingReference(storageID: "recording-storage"),
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

    func testRepositoryReturnsStorageNeutralRecordingSnapshot() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )

        let repository = SQLiteLibraryRepository(store: store)
        let recordings = try await repository.fetchRecordingSummaries()

        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(
            recordings[0],
            LibraryRecordingSnapshot(
                storageID: "recording-storage",
                legacyID: "recording-legacy",
                name: "Fixture recording",
                recordingDate: Date(timeIntervalSinceReferenceDate: 100),
                duration: 7.5,
                fileSize: 42,
                recordingURL: "recording.m4a",
                isArchived: false,
                archivedAt: nil,
                archiveNote: nil,
                isCloudSyncDisabled: false,
                lastModified: Date(timeIntervalSinceReferenceDate: 101)
            )
        )
    }

    func testRepositoryReturnsEmptyLibraryBeforeMetadataImport() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let repository = SQLiteLibraryRepository(store: store)
        let recordings = try await repository.fetchRecordingSummaries()

        XCTAssertTrue(recordings.isEmpty)
    }

    func testRepositoryCreatesRecordingWithStableIdentityAndObservationChange() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let repository = SQLiteLibraryRepository(store: store)
        let recordingID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000010")
        )
        let command = LibraryRecordingCreateCommand(
            id: recordingID,
            recordingURL: "new-recording.m4a",
            name: "New recording",
            recordingDate: Date(timeIntervalSinceReferenceDate: 100),
            createdAt: Date(timeIntervalSinceReferenceDate: 101),
            duration: 12.25,
            fileSize: 512,
            audioQuality: "Whisper Optimized",
            locationAccuracy: 7.0,
            locationAddress: "New address",
            locationLatitude: 39.25,
            locationLongitude: -76.71,
            locationTimestamp: Date(timeIntervalSinceReferenceDate: 99),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 102)
        )

        let created = try await repository.createRecording(command)

        XCTAssertEqual(
            created.storageID,
            "sqlite-recording-\(recordingID.uuidString.lowercased())"
        )
        XCTAssertEqual(created.legacyID, recordingID.uuidString.lowercased())
        XCTAssertEqual(created.name, "New recording")
        XCTAssertEqual(created.recordingDate, Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(created.duration, 12.25)
        XCTAssertEqual(created.fileSize, 512)
        XCTAssertEqual(created.recordingURL, "new-recording.m4a")
        XCTAssertEqual(created.isArchived, false)
        XCTAssertEqual(created.isCloudSyncDisabled, false)
        XCTAssertEqual(created.lastModified, Date(timeIntervalSinceReferenceDate: 102))

        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(changes.map(\.entity), [.recording])
        XCTAssertEqual(changes.map(\.operation), [.inserted])
        XCTAssertEqual(changes.map(\.revision), [1])

        do {
            _ = try await repository.createRecording(command)
            XCTFail("Expected duplicate recording creation to fail")
        } catch let error as LibraryRepositoryError {
            XCTAssertEqual(
                error,
                .recordingAlreadyExists(reference: recordingID.uuidString.lowercased())
            )
        }
        let recordings = try await repository.fetchRecordingSummaries()
        XCTAssertEqual(recordings.count, 1)
    }

    func testRepositoryDiscardsRecordingAndLeavesDurableDeleteChange() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let repository = SQLiteLibraryRepository(store: store)
        let recordingID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000011")
        )
        let created = try await repository.createRecording(
            LibraryRecordingCreateCommand(
                id: recordingID,
                recordingURL: "discard-me.m4a",
                name: "Discard me",
                recordingDate: Date(timeIntervalSinceReferenceDate: 100),
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                duration: 0.1,
                fileSize: 1,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 101)
            )
        )

        try await repository.discardRecording(
            LibraryRecordingDiscardCommand(
                reference: LibraryRecordingReference(storageID: created.storageID),
                expectedLastModified: created.lastModified,
                discardedAt: Date(timeIntervalSinceReferenceDate: 102)
            )
        )

        let recordings = try await repository.fetchRecordingSummaries()
        XCTAssertTrue(recordings.isEmpty)
        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(changes.map(\.entity), [.recording, .recording])
        XCTAssertEqual(changes.map(\.operation), [.inserted, .deleted])
        XCTAssertEqual(changes.map(\.revision), [1, 2])
        XCTAssertEqual(changes.last?.storageID, created.storageID)
        XCTAssertEqual(
            changes.last?.committedAt,
            Date(timeIntervalSinceReferenceDate: 102)
        )
    }

    func testRepositoryDeletesRecordingGraphAndQueuesCloudRemovalIntents() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let repository = SQLiteLibraryRepository(store: store)
        let graph = try await createRecordingGraph(using: repository)

        try await repository.deleteRecording(
            LibraryRecordingDeleteCommand(
                reference: LibraryRecordingReference(storageID: graph.recording.storageID),
                requestedAt: Date(timeIntervalSinceReferenceDate: 200)
            )
        )

        let recordings = try await repository.fetchRecordingSummaries()
        let transcripts = try await repository.fetchTranscriptSnapshots()
        let summaries = try await repository.fetchSummarySnapshots()
        let processingJobs = try await repository.fetchProcessingJobSnapshots()
        XCTAssertTrue(recordings.isEmpty)
        XCTAssertTrue(transcripts.isEmpty)
        XCTAssertTrue(summaries.isEmpty)
        XCTAssertTrue(processingJobs.isEmpty)

        // Archive locations remain owned by the separate archive lifecycle until
        // that command has a repository boundary of its own.
        let archiveLocations = try await repository.fetchArchiveLocationSnapshots()
        XCTAssertEqual(archiveLocations.count, 1)
        XCTAssertEqual(
            archiveLocations[0].recordingLegacyID,
            graph.recording.legacyID
        )

        let pendingMutations = try await repository.fetchPendingCloudMutationSnapshots()
        let recordingDeletion = try XCTUnwrap(
            pendingMutations.first { $0.kind == "recordingDeletion" }
        )
        let summaryRemoval = try XCTUnwrap(
            pendingMutations.first { $0.kind == "summaryRemoval" }
        )
        XCTAssertNil(pendingMutations.first { $0.kind == "importedAudioRemoval" })
        XCTAssertEqual(recordingDeletion.targetID, graph.recording.legacyID)
        XCTAssertEqual(
            recordingDeletion.requestedAt,
            Date(timeIntervalSinceReferenceDate: 200)
        )
        XCTAssertEqual(summaryRemoval.targetID, graph.summaryID.uuidString.lowercased())
        XCTAssertEqual(
            summaryRemoval.recordingLegacyID,
            graph.recording.legacyID
        )

        struct DeletionPayload: Decodable {
            let transcriptIds: [String]
            let summaryIds: [String]
        }
        let payload = try JSONDecoder().decode(
            DeletionPayload.self,
            from: try XCTUnwrap(recordingDeletion.payload)
        )
        XCTAssertEqual(
            Set(payload.transcriptIds),
            [graph.transcriptID.uuidString.lowercased()]
        )
        XCTAssertEqual(
            Set(payload.summaryIds),
            [graph.summaryID.uuidString.lowercased()]
        )

        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(
            changes.filter { $0.entity == .transcript && $0.operation == .deleted }.count,
            1
        )
        XCTAssertEqual(
            changes.filter { $0.entity == .summary && $0.operation == .deleted }.count,
            1
        )
        XCTAssertEqual(
            changes.filter { $0.entity == .processingJob && $0.operation == .deleted }.count,
            1
        )
        XCTAssertEqual(
            changes.filter { $0.entity == .recording && $0.operation == .deleted }.count,
            1
        )
    }

    func testRepositoryAppliesRecordingDeleteLocallyWithoutRaisingCloudIntent() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let repository = SQLiteLibraryRepository(store: store)
        let graph = try await createRecordingGraph(using: repository)

        try await repository.deleteRecording(
            LibraryRecordingDeleteCommand(
                reference: LibraryRecordingReference(legacyID: graph.recording.legacyID),
                requestedAt: Date(timeIntervalSinceReferenceDate: 201),
                enqueueCloudDeletion: false
            )
        )

        let recordings = try await repository.fetchRecordingSummaries()
        let transcripts = try await repository.fetchTranscriptSnapshots()
        let summaries = try await repository.fetchSummarySnapshots()
        let processingJobs = try await repository.fetchProcessingJobSnapshots()
        let pendingMutations = try await repository.fetchPendingCloudMutationSnapshots()
        XCTAssertTrue(recordings.isEmpty)
        XCTAssertTrue(transcripts.isEmpty)
        XCTAssertTrue(summaries.isEmpty)
        XCTAssertTrue(processingJobs.isEmpty)
        XCTAssertTrue(pendingMutations.isEmpty)
    }

    func testRepositoryPreservesSummaryAndQueuesTranscriptAudioRemovalIntents() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let repository = SQLiteLibraryRepository(store: store)
        let graph = try await createRecordingGraph(using: repository)
        let staleTranscriptID = try XCTUnwrap(
            UUID(uuidString: "20000000-0000-0000-0000-000000000006")
        )
        let requestedAt = Date(timeIntervalSinceReferenceDate: 200)

        try await repository.deleteRecordingPreservingSummary(
            LibraryRecordingPreserveSummaryDeleteCommand(
                reference: LibraryRecordingReference(storageID: graph.recording.storageID),
                transcriptIds: [staleTranscriptID],
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 104),
                requestedAt: requestedAt
            )
        )

        let recordings = try await repository.fetchRecordingSummaries()
        let transcripts = try await repository.fetchTranscriptSnapshots()
        let summaries = try await repository.fetchSummarySnapshots()
        let processingJobs = try await repository.fetchProcessingJobSnapshots()
        XCTAssertEqual(recordings.count, 1)
        XCTAssertNil(recordings[0].recordingURL)
        XCTAssertEqual(
            recordings[0].lastModified,
            requestedAt
        )
        XCTAssertTrue(transcripts.isEmpty)
        XCTAssertEqual(processingJobs.count, 1)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].legacyID, graph.summaryID.uuidString.lowercased())
        XCTAssertNil(summaries[0].transcriptStorageID)
        XCTAssertNil(summaries[0].transcriptLegacyID)

        // Archive metadata remains available to the separate archive lifecycle.
        let archiveLocations = try await repository.fetchArchiveLocationSnapshots()
        XCTAssertEqual(archiveLocations.count, 1)

        let pendingMutations = try await repository.fetchPendingCloudMutationSnapshots()
        let transcriptRemovals = pendingMutations.filter { $0.kind == "transcriptRemoval" }
        XCTAssertEqual(transcriptRemovals.count, 2)
        XCTAssertEqual(
            Set(transcriptRemovals.compactMap(\.targetID)),
            Set([
                graph.transcriptID.uuidString.lowercased(),
                staleTranscriptID.uuidString.lowercased()
            ])
        )
        let audioRemoval = try XCTUnwrap(
            pendingMutations.first { $0.kind == "importedAudioRemoval" }
        )
        XCTAssertEqual(audioRemoval.targetID, graph.recording.legacyID)
        XCTAssertEqual(
            audioRemoval.requestedAt,
            requestedAt
        )

        let changes = try await repository.changes(since: 0)
        let committedChanges = changes.filter { $0.committedAt == requestedAt }
        XCTAssertEqual(
            committedChanges.filter { $0.entity == .transcript && $0.operation == .deleted }.count,
            1
        )
        XCTAssertEqual(
            committedChanges.filter { $0.entity == .summary && $0.operation == .updated }.count,
            1
        )
        XCTAssertEqual(
            committedChanges.filter { $0.entity == .recording && $0.operation == .updated }.count,
            1
        )
    }

    func testRepositoryPreservesSummaryLocallyWithoutCloudIntents() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let repository = SQLiteLibraryRepository(store: store)
        let graph = try await createRecordingGraph(using: repository)

        try await repository.deleteRecordingPreservingSummary(
            LibraryRecordingPreserveSummaryDeleteCommand(
                reference: LibraryRecordingReference(legacyID: graph.recording.legacyID),
                requestedAt: Date(timeIntervalSinceReferenceDate: 201),
                enqueueCloudDeletion: false
            )
        )

        let recordings = try await repository.fetchRecordingSummaries()
        let transcripts = try await repository.fetchTranscriptSnapshots()
        let summaries = try await repository.fetchSummarySnapshots()
        let processingJobs = try await repository.fetchProcessingJobSnapshots()
        let pendingMutations = try await repository.fetchPendingCloudMutationSnapshots()
        XCTAssertEqual(recordings.count, 1)
        XCTAssertTrue(transcripts.isEmpty)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(processingJobs.count, 1)
        XCTAssertTrue(pendingMutations.isEmpty)
    }

    func testRepositoryRefusesToDiscardRecordingWithDependentMetadata() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)

        do {
            try await repository.discardRecording(
                LibraryRecordingDiscardCommand(
                    reference: LibraryRecordingReference(storageID: "recording-storage")
                )
            )
            XCTFail("Expected a recording with dependent metadata to be retained")
        } catch let error as LibraryRepositoryError {
            XCTAssertEqual(
                error,
                .recordingHasDependents(reference: "recording-storage")
            )
        }

        let recordings = try await repository.fetchRecordingSummaries()
        let transcripts = try await repository.fetchTranscriptSnapshots()
        let revision = try await repository.currentRevision()
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(transcripts.count, 1)
        XCTAssertEqual(revision, 0)
    }

    func testRepositoryReturnsAllMetadataSnapshotsFromImportedRows() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)
        let transcripts = try await repository.fetchTranscriptSnapshots()
        let summaries = try await repository.fetchSummarySnapshots()
        let processingJobs = try await repository.fetchProcessingJobSnapshots()
        let archiveLocations = try await repository.fetchArchiveLocationSnapshots()
        let pendingMutations = try await repository.fetchPendingCloudMutationSnapshots()

        XCTAssertEqual(transcripts, [expectedTranscript()])
        XCTAssertEqual(summaries, [expectedSummary()])
        XCTAssertEqual(processingJobs, [expectedProcessingJob()])
        XCTAssertEqual(archiveLocations, [expectedArchiveLocation()])
        XCTAssertEqual(pendingMutations, [expectedPendingMutation()])
    }

    func testRepositoryReplacesTranscriptByRecordingAndUpdatesRecordingAtomically() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)
        let replacementID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000015")
        )

        let updated = try await repository.upsertTranscript(
            LibraryTranscriptUpsertCommand(
                id: replacementID,
                recordingReference: LibraryRecordingReference(
                    storageID: "recording-storage"
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

        XCTAssertEqual(updated.storageID, "transcript-storage")
        XCTAssertEqual(updated.legacyID, "transcript-legacy")
        XCTAssertEqual(updated.createdAt, Date(timeIntervalSinceReferenceDate: 102))
        XCTAssertEqual(updated.lastModified, Date(timeIntervalSinceReferenceDate: 301))
        XCTAssertEqual(updated.engine, "replacement-engine")
        XCTAssertEqual(updated.processingTime, 4.5)
        XCTAssertEqual(updated.confidence, 0.91)
        XCTAssertEqual(updated.segments, "[{\"text\":\"replacement\"}]")
        XCTAssertEqual(updated.speakerMappings, "{\"Speaker 1\":\"A\"}")

        let recordings = try await repository.fetchRecordingSummaries()
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].lastModified, Date(timeIntervalSinceReferenceDate: 301))

        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(changes.map(\.entity), [.transcript, .recording])
        XCTAssertEqual(changes.map(\.operation), [.updated, .updated])
        XCTAssertEqual(changes.map(\.revision), [1, 2])
    }

    func testRepositoryUpdatesArchiveStateWithRevisionAndClearsItOnRestore() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)

        let archived = try await repository.setArchiveState(
            LibraryRecordingArchiveCommand(
                reference: LibraryRecordingReference(storageID: "recording-storage"),
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
                reference: LibraryRecordingReference(storageID: "recording-storage"),
                archived: false,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 301),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 302)
            )
        )
        XCTAssertEqual(restored.isArchived, false)
        XCTAssertNil(restored.archivedAt)
        XCTAssertNil(restored.archiveNote)
        XCTAssertEqual(restored.lastModified, Date(timeIntervalSinceReferenceDate: 302))

        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(changes.map(\.entity), [.recording, .recording])
        XCTAssertEqual(changes.map(\.revision), [1, 2])
    }

    func testRepositoryCreatesArchiveLocationWithStableIdentityAndRetryDoesNotDuplicate() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)
        let archiveID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000017")
        )
        let command = LibraryArchiveLocationUpsertCommand(
            id: archiveID,
            recordingReference: LibraryRecordingReference(
                storageID: "recording-storage"
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
        XCTAssertEqual(created.legacyID, archiveID.uuidString.lowercased())
        XCTAssertEqual(created.bookmarkData, Data([9, 8, 7]))
        XCTAssertEqual(created.destinationURLString, "archive://repository-retry")
        XCTAssertEqual(created.recordingLegacyID, "recording-legacy")
        XCTAssertEqual(locations.count, 2)
        XCTAssertEqual(locations.filter { $0.storageID == created.storageID }.count, 1)

        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(changes.map(\.entity), [.archiveLocation, .archiveLocation])
        XCTAssertEqual(changes.map(\.operation), [.inserted, .updated])
        XCTAssertEqual(changes.map(\.revision), [1, 2])
    }

    func testRepositoryCreatesTranscriptWithStableStorageIdentityAndRetryDoesNotDuplicate() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let recordingOnlySnapshot = SQLiteMigrationSourceSnapshot(
            sourceModel: sourceSnapshot.sourceModel,
            sourceFingerprint: "recording-only-fixture",
            migrationRunID: nil,
            rows: sourceSnapshot.rows.filter { $0.entity == .recordings }
        )
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            recordingOnlySnapshot,
            into: store,
            batchSize: 1,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)
        let transcriptID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000016")
        )
        let command = LibraryTranscriptUpsertCommand(
            id: transcriptID,
            recordingReference: LibraryRecordingReference(
                legacyID: "recording-legacy"
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 400),
            segments: "[]",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 401)
        )

        let created = try await repository.upsertTranscript(command)
        let retried = try await repository.upsertTranscript(command)
        let transcripts = try await repository.fetchTranscriptSnapshots()

        XCTAssertEqual(created.storageID, "sqlite-transcript-\(transcriptID.uuidString.lowercased())")
        XCTAssertEqual(created.legacyID, transcriptID.uuidString.lowercased())
        XCTAssertEqual(created.recordingStorageID, "recording-storage")
        XCTAssertEqual(created.createdAt, Date(timeIntervalSinceReferenceDate: 400))
        XCTAssertEqual(retried.storageID, created.storageID)
        XCTAssertEqual(retried.legacyID, created.legacyID)
        XCTAssertEqual(transcripts.count, 1)

        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(changes.map(\.entity), [
            .transcript, .recording, .transcript, .recording
        ])
    }

    func testRepositoryReplacesSummaryByRecordingAndUpdatesRecordingAtomically() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)
        let replacementID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000017")
        )

        let updated = try await repository.upsertSummary(
            LibrarySummaryUpsertCommand(
                id: replacementID,
                recordingReference: LibraryRecordingReference(
                    storageID: "recording-storage"
                ),
                transcriptID: nil,
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

        XCTAssertEqual(updated.storageID, "summary-storage")
        XCTAssertEqual(updated.legacyID, "summary-legacy")
        XCTAssertEqual(updated.generatedAt, Date(timeIntervalSinceReferenceDate: 301))
        XCTAssertEqual(updated.aiMethod, "{\"engine\":\"replacement-engine\",\"model\":\"replacement-model\"}")
        XCTAssertEqual(updated.contentType, "meeting")
        XCTAssertEqual(updated.summary, "This replacement summary is long enough to be persisted safely.")
        XCTAssertEqual(updated.tasks, "[{\"text\":\"replacement task\"}]")
        XCTAssertEqual(updated.reminders, "[{\"text\":\"replacement reminder\"}]")
        XCTAssertEqual(updated.titles, "[{\"text\":\"Replacement title\"}]")
        XCTAssertEqual(updated.transcriptStorageID, "transcript-storage")
        XCTAssertEqual(updated.transcriptLegacyID, "transcript-legacy")
        XCTAssertEqual(updated.version, 2)
        XCTAssertEqual(updated.wordCount, 9)

        let recordings = try await repository.fetchRecordingSummaries()
        XCTAssertEqual(recordings.first?.lastModified, Date(timeIntervalSinceReferenceDate: 301))

        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(changes.map(\.entity), [.summary, .recording])
        XCTAssertEqual(changes.map(\.operation), [.updated, .updated])
        XCTAssertEqual(changes.map(\.revision), [1, 2])
    }

    func testRepositoryCreatesSummaryWithStableStorageIdentityAndRetryDoesNotDuplicate() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let recordingOnlySnapshot = SQLiteMigrationSourceSnapshot(
            sourceModel: sourceSnapshot.sourceModel,
            sourceFingerprint: "recording-only-fixture",
            migrationRunID: nil,
            rows: sourceSnapshot.rows.filter { $0.entity == .recordings }
        )
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            recordingOnlySnapshot,
            into: store,
            batchSize: 1,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)
        let summaryID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000018")
        )
        let command = LibrarySummaryUpsertCommand(
            id: summaryID,
            recordingReference: LibraryRecordingReference(
                legacyID: "recording-legacy"
            ),
            summary: "This newly created summary is long enough to survive a retry.",
            aiMethod: "fixture-model",
            generatedAt: Date(timeIntervalSinceReferenceDate: 401),
            wordCount: 10,
            originalLength: 50
        )

        let created = try await repository.upsertSummary(command)
        let retried = try await repository.upsertSummary(command)
        let summaries = try await repository.fetchSummarySnapshots()

        XCTAssertEqual(created.storageID, "sqlite-summary-\(summaryID.uuidString.lowercased())")
        XCTAssertEqual(created.legacyID, summaryID.uuidString.lowercased())
        XCTAssertEqual(created.recordingStorageID, "recording-storage")
        XCTAssertNil(created.transcriptStorageID)
        XCTAssertEqual(retried.storageID, created.storageID)
        XCTAssertEqual(retried.legacyID, created.legacyID)
        XCTAssertEqual(summaries.count, 1)

        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(changes.map(\.entity), [
            .summary, .recording, .summary, .recording
        ])
    }

    func testRepositoryRenamesRecordingWithExpectedRevision() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )

        let repository = SQLiteLibraryRepository(store: store)
        let updated = try await repository.renameRecording(
            LibraryRecordingRenameCommand(
                reference: LibraryRecordingReference(storageID: "recording-storage"),
                name: "Renamed [Watch]",
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 101),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 300)
            )
        )

        XCTAssertEqual(updated.name, "Renamed")
        XCTAssertEqual(updated.lastModified, Date(timeIntervalSinceReferenceDate: 300))
        let persistedRecordings = try await repository.fetchRecordingSummaries()
        XCTAssertEqual(persistedRecordings.first?.name, "Renamed")
    }

    func testRepositoryCloudSyncToggleCommitsRecordingAndPendingMutationTogether() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)

        let disabled = try await repository.setCloudSyncDisabled(
            LibraryRecordingCloudSyncCommand(
                reference: LibraryRecordingReference(storageID: "recording-storage"),
                disabled: true,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 101),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 300),
                requestedAt: Date(timeIntervalSinceReferenceDate: 250)
            )
        )

        XCTAssertEqual(disabled.isCloudSyncDisabled, true)
        XCTAssertEqual(disabled.lastModified, Date(timeIntervalSinceReferenceDate: 300))
        let pendingAfterDisable = try await repository.fetchPendingCloudMutationSnapshots()
            .filter { $0.kind == "localOnlyRemoval" }
        XCTAssertEqual(pendingAfterDisable.count, 1)
        XCTAssertEqual(pendingAfterDisable[0].storageID, "local-only-removal-recording-storage")
        XCTAssertEqual(pendingAfterDisable[0].targetID, "recording-legacy")
        XCTAssertNil(pendingAfterDisable[0].recordingLegacyID)
        XCTAssertEqual(
            pendingAfterDisable[0].requestedAt,
            Date(timeIntervalSinceReferenceDate: 250)
        )

        let changesAfterDisable = try await repository.changes(since: 0)
        XCTAssertEqual(changesAfterDisable.map(\.revision), [1, 2])
        XCTAssertEqual(changesAfterDisable.map(\.entity), [.recording, .pendingCloudMutation])
        XCTAssertEqual(changesAfterDisable.map(\.operation), [.updated, .inserted])

        let enabled = try await repository.setCloudSyncDisabled(
            LibraryRecordingCloudSyncCommand(
                reference: LibraryRecordingReference(storageID: "recording-storage"),
                disabled: false,
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 300),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        XCTAssertEqual(enabled.isCloudSyncDisabled, false)
        XCTAssertEqual(enabled.lastModified, Date(timeIntervalSinceReferenceDate: 301))
        let pendingAfterEnable = try await repository.fetchPendingCloudMutationSnapshots()
            .filter { $0.kind == "localOnlyRemoval" }
        XCTAssertTrue(pendingAfterEnable.isEmpty)

        let changesAfterEnable = try await repository.changes(since: 2)
        XCTAssertEqual(changesAfterEnable.map(\.revision), [3, 4])
        XCTAssertEqual(changesAfterEnable.map(\.entity), [.recording, .pendingCloudMutation])
        XCTAssertEqual(changesAfterEnable.map(\.operation), [.updated, .deleted])
    }

    func testRepositoryUpdatesProcessingJobWithExplicitPreserveAndClearSemantics() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)
        let jobReference = LibraryProcessingJobReference(storageID: "job-storage")

        let failed = try await repository.updateProcessingJob(
            LibraryProcessingJobUpdateCommand(
                reference: jobReference,
                status: "failed",
                progress: 0.75,
                error: .set("Processing failed"),
                completionTime: .set(Date(timeIntervalSinceReferenceDate: 300)),
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 105),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        XCTAssertEqual(failed.status, "failed")
        XCTAssertEqual(failed.progress, 0.75)
        XCTAssertEqual(failed.error, "Processing failed")
        XCTAssertEqual(
            failed.completionTime,
            Date(timeIntervalSinceReferenceDate: 300)
        )
        XCTAssertEqual(failed.lastModified, Date(timeIntervalSinceReferenceDate: 301))

        let preserved = try await repository.updateProcessingJob(
            LibraryProcessingJobUpdateCommand(
                reference: jobReference,
                status: "processing",
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

        let cleared = try await repository.updateProcessingJob(
            LibraryProcessingJobUpdateCommand(
                reference: jobReference,
                status: "queued",
                progress: 0,
                error: .set(nil),
                completionTime: .set(nil),
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 302),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 303)
            )
        )

        XCTAssertNil(cleared.error)
        XCTAssertNil(cleared.completionTime)
        let changes = try await repository.changes(since: 0)
        let revision = try await repository.currentRevision()
        XCTAssertEqual(revision, 3)
        XCTAssertEqual(
            changes.map(\.entity),
            [.processingJob, .processingJob, .processingJob]
        )
        XCTAssertEqual(
            changes.map(\.operation),
            [.updated, .updated, .updated]
        )

        do {
            _ = try await repository.updateProcessingJob(
                LibraryProcessingJobUpdateCommand(
                    reference: jobReference,
                    status: "processing",
                    progress: 0.1,
                    expectedLastModified: Date(timeIntervalSinceReferenceDate: 105),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 304)
                )
            )
            XCTFail("Expected stale processing-job revision to be rejected")
        } catch let error as LibraryRepositoryError {
            XCTAssertEqual(
                error,
                .staleProcessingJob(
                    reference: "job-storage",
                    expected: Date(timeIntervalSinceReferenceDate: 105),
                    actual: Date(timeIntervalSinceReferenceDate: 303)
                )
            )
        }
        let revisionAfterRejectedUpdate = try await repository.currentRevision()
        XCTAssertEqual(revisionAfterRejectedUpdate, 3)
    }

    func testRepositoryCreatesProcessingJobWithRecordingLinkAndDurableInsertChange() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)
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
                status: "queued",
                progress: 0,
                startTime: Date(timeIntervalSinceReferenceDate: 300),
                recordingReference: LibraryRecordingReference(
                    storageID: "recording-storage"
                ),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 301)
            )
        )

        XCTAssertEqual(
            created.storageID,
            "sqlite-processingjob-10000000-0000-0000-0000-000000000006"
        )
        XCTAssertEqual(created.legacyID, jobID.uuidString.lowercased())
        XCTAssertEqual(created.recordingStorageID, "recording-storage")
        XCTAssertEqual(created.status, "queued")
        XCTAssertEqual(created.progress, 0)
        XCTAssertEqual(created.startTime, Date(timeIntervalSinceReferenceDate: 300))
        XCTAssertEqual(created.lastModified, Date(timeIntervalSinceReferenceDate: 301))

        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(changes.map(\.revision), [1])
        XCTAssertEqual(changes.map(\.entity), [.processingJob])
        XCTAssertEqual(changes.map(\.operation), [.inserted])
        XCTAssertEqual(
            changes[0].committedAt,
            Date(timeIntervalSinceReferenceDate: 301)
        )

        do {
            _ = try await repository.createProcessingJob(
                LibraryProcessingJobCreateCommand(
                    id: jobID,
                    jobType: "Summarization (mlxSwift)",
                    engine: "mlxSwift",
                    recordingURL: "recording.m4a",
                    recordingName: "Fixture recording",
                    status: "queued",
                    progress: 0,
                    startTime: Date(timeIntervalSinceReferenceDate: 302),
                    recordingReference: LibraryRecordingReference(
                        storageID: "recording-storage"
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
        let revisionAfterDuplicate = try await repository.currentRevision()
        XCTAssertEqual(revisionAfterDuplicate, 1)
    }

    func testRepositoryDeletesProcessingJobAndLeavesDurableDeleteChange() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count,
            at: Date(timeIntervalSinceReferenceDate: 200)
        )
        let repository = SQLiteLibraryRepository(store: store)

        let deleted = try await repository.deleteProcessingJob(
            LibraryProcessingJobDeleteCommand(
                reference: LibraryProcessingJobReference(legacyID: "job-legacy"),
                expectedLastModified: Date(timeIntervalSinceReferenceDate: 105),
                deletedAt: Date(timeIntervalSinceReferenceDate: 305)
            )
        )

        XCTAssertEqual(deleted.storageID, "job-storage")
        let jobsAfterDelete = try await repository.fetchProcessingJobSnapshots()
        XCTAssertTrue(jobsAfterDelete.isEmpty)
        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(changes.map(\.revision), [1])
        XCTAssertEqual(changes.map(\.entity), [.processingJob])
        XCTAssertEqual(changes.map(\.operation), [.deleted])
        XCTAssertEqual(
            changes[0].committedAt,
            Date(timeIntervalSinceReferenceDate: 305)
        )

        do {
            _ = try await repository.deleteProcessingJob(
                LibraryProcessingJobDeleteCommand(
                    reference: LibraryProcessingJobReference(storageID: "job-storage"),
                    deletedAt: Date(timeIntervalSinceReferenceDate: 306)
                )
            )
            XCTFail("Expected deleting a missing processing job to fail")
        } catch let error as LibraryRepositoryError {
            XCTAssertEqual(
                error,
                .processingJobNotFound(reference: "job-storage")
            )
        }
        let revisionAfterMissingDelete = try await repository.currentRevision()
        XCTAssertEqual(revisionAfterMissingDelete, 1)
    }

    func testRepositoryDeletesTerminalProcessingJobsCaseInsensitively() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let repository = SQLiteLibraryRepository(store: store)
        let jobIDs = try [
            XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000011")),
            XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000012")),
            XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000013")),
            XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000014"))
        ]
        let statuses = ["Completed", "failed", " CANCELLED ", "Processing"]

        for (index, values) in zip(jobIDs, statuses).enumerated() {
            _ = try await repository.createProcessingJob(
                LibraryProcessingJobCreateCommand(
                    id: values.0,
                    jobType: "Test job",
                    engine: "fixture-engine",
                    recordingURL: "recording-\(index).m4a",
                    recordingName: "Fixture recording",
                    status: values.1,
                    progress: values.1.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == "processing" ? 0.5 : 1,
                    startTime: Date(timeIntervalSinceReferenceDate: 100 + Double(index)),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 110 + Double(index))
                )
            )
        }

        let deleted = try await repository.deleteTerminalProcessingJobs(
            LibraryProcessingJobTerminalCleanupCommand(
                deletedAt: Date(timeIntervalSinceReferenceDate: 200)
            )
        )

        XCTAssertEqual(deleted.count, 3)
        XCTAssertEqual(
            Set(
                deleted.compactMap(\.status).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            ),
            Set(["completed", "failed", "cancelled"])
        )
        let remaining = try await repository.fetchProcessingJobSnapshots()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].status, "Processing")

        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(changes.count, 7)
        XCTAssertEqual(
            changes.prefix(4).map(\.operation),
            Array(repeating: .inserted, count: 4)
        )
        XCTAssertEqual(
            changes.suffix(3).map(\.operation),
            Array(repeating: .deleted, count: 3)
        )
        XCTAssertEqual(
            Set(changes.suffix(3).map(\.committedAt)),
            Set([Date(timeIntervalSinceReferenceDate: 200)])
        )

        let secondPass = try await repository.deleteTerminalProcessingJobs(
            LibraryProcessingJobTerminalCleanupCommand(
                deletedAt: Date(timeIntervalSinceReferenceDate: 201)
            )
        )
        XCTAssertTrue(secondPass.isEmpty)
        let revisionAfterSecondPass = try await repository.currentRevision()
        XCTAssertEqual(revisionAfterSecondPass, 7)
    }

    func testRepositoryRecoversKnownUnfinishedJobsAfterCrashInOneTransaction() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let repository = SQLiteLibraryRepository(store: store)
        let processingID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000021")
        )
        let completedID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000022")
        )
        let queuedID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000023")
        )
        let jobs = [
            (processingID, "Processing", 0.4),
            (completedID, "Completed", 1.0),
            (queuedID, "queued", 0.0)
        ]

        for (index, job) in jobs.enumerated() {
            _ = try await repository.createProcessingJob(
                LibraryProcessingJobCreateCommand(
                    id: job.0,
                    jobType: "Test job",
                    engine: "fixture-engine",
                    recordingURL: "recording-\(index).m4a",
                    recordingName: "Fixture recording",
                    status: job.1,
                    progress: job.2,
                    startTime: Date(timeIntervalSinceReferenceDate: 100 + Double(index)),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 110 + Double(index))
                )
            )
        }

        let failureMessage = "Not restarted because the previous app session crashed."
        let recovered = try await repository.recoverProcessingJobsAfterCrash(
            LibraryProcessingJobCrashRecoveryCommand(
                references: [
                    processingID,
                    completedID,
                    queuedID
                ].map {
                    LibraryProcessingJobReference(legacyID: $0.uuidString)
                } + [
                    LibraryProcessingJobReference(legacyID: "missing-job")
                ],
                failureMessage: failureMessage,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 200)
            )
        )

        XCTAssertEqual(recovered.count, 2)
        let recoveredByID = Dictionary(
            uniqueKeysWithValues: recovered.compactMap { snapshot in
                snapshot.legacyID.map { ($0, snapshot) }
            }
        )
        for job in [processingID, queuedID] {
            let snapshot = try XCTUnwrap(recoveredByID[job.uuidString.lowercased()])
            XCTAssertEqual(snapshot.status, "Failed")
            XCTAssertEqual(snapshot.error, failureMessage)
            XCTAssertEqual(snapshot.completionTime, Date(timeIntervalSinceReferenceDate: 200))
            XCTAssertEqual(snapshot.lastModified, Date(timeIntervalSinceReferenceDate: 200))
        }
        let persisted = try await repository.fetchProcessingJobSnapshots()
        let completed = try XCTUnwrap(
            persisted.first { $0.legacyID == completedID.uuidString.lowercased() }
        )
        XCTAssertEqual(completed.status, "Completed")
        XCTAssertNil(completed.error)

        let changes = try await repository.changes(since: 0)
        XCTAssertEqual(changes.count, 5)
        XCTAssertEqual(
            changes.suffix(2).map(\.operation),
            Array(repeating: .updated, count: 2)
        )
        XCTAssertEqual(
            Set(changes.suffix(2).map(\.committedAt)),
            Set([Date(timeIntervalSinceReferenceDate: 200)])
        )

        let secondPass = try await repository.recoverProcessingJobsAfterCrash(
            LibraryProcessingJobCrashRecoveryCommand(
                references: [processingID, completedID, queuedID].map {
                    LibraryProcessingJobReference(legacyID: $0.uuidString)
                },
                failureMessage: failureMessage,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 201)
            )
        )
        XCTAssertTrue(secondPass.isEmpty)
        let revisionAfterSecondPass = try await repository.currentRevision()
        XCTAssertEqual(revisionAfterSecondPass, 5)
    }

    func testRepositoryRenameRejectsStaleRevisionWithoutChangingTheRow() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceSnapshot = makeVerifierSnapshot(migrationRunID: nil)
        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await SQLiteMigrationMetadataImporter.importSnapshot(
            sourceSnapshot,
            into: store,
            batchSize: sourceSnapshot.rows.count
        )
        let repository = SQLiteLibraryRepository(store: store)

        do {
            _ = try await repository.renameRecording(
                LibraryRecordingRenameCommand(
                    reference: LibraryRecordingReference(storageID: "recording-storage"),
                    name: "Should not persist",
                    expectedLastModified: Date(timeIntervalSinceReferenceDate: 999),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 300)
                )
            )
            XCTFail("Expected the stale revision to be rejected")
        } catch let error as LibraryRepositoryError {
            XCTAssertEqual(
                error,
                .staleRecording(
                    reference: "recording-storage",
                    expected: Date(timeIntervalSinceReferenceDate: 999),
                    actual: Date(timeIntervalSinceReferenceDate: 101)
                )
            )
        }

        let persistedRecordings = try await repository.fetchRecordingSummaries()
        XCTAssertEqual(persistedRecordings.first?.name, "Fixture recording")
        let revisionAfterRejectedRename = try await repository.currentRevision()
        XCTAssertEqual(revisionAfterRejectedRename, 0)
    }

    private func createRecordingGraph(
        using repository: SQLiteLibraryRepository
    ) async throws -> (
        recording: LibraryRecordingSnapshot,
        transcriptID: UUID,
        summaryID: UUID,
        jobID: UUID,
        archiveLocationID: UUID
    ) {
        let recordingID = try XCTUnwrap(
            UUID(uuidString: "20000000-0000-0000-0000-000000000001")
        )
        let transcriptID = try XCTUnwrap(
            UUID(uuidString: "20000000-0000-0000-0000-000000000002")
        )
        let summaryID = try XCTUnwrap(
            UUID(uuidString: "20000000-0000-0000-0000-000000000003")
        )
        let jobID = try XCTUnwrap(
            UUID(uuidString: "20000000-0000-0000-0000-000000000004")
        )
        let archiveLocationID = try XCTUnwrap(
            UUID(uuidString: "20000000-0000-0000-0000-000000000005")
        )

        let recording = try await repository.createRecording(
            LibraryRecordingCreateCommand(
                id: recordingID,
                recordingURL: "recording.m4a",
                name: "Delete graph",
                recordingDate: Date(timeIntervalSinceReferenceDate: 100),
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                duration: 12,
                fileSize: 512,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 101)
            )
        )
        _ = try await repository.upsertTranscript(
            LibraryTranscriptUpsertCommand(
                id: transcriptID,
                recordingReference: LibraryRecordingReference(
                    storageID: recording.storageID
                ),
                createdAt: Date(timeIntervalSinceReferenceDate: 102),
                segments: "[{\"text\":\"delete me\"}]",
                engine: "fixture-engine",
                modifiedAt: Date(timeIntervalSinceReferenceDate: 103)
            )
        )
        _ = try await repository.upsertSummary(
            LibrarySummaryUpsertCommand(
                id: summaryID,
                recordingReference: LibraryRecordingReference(
                    storageID: recording.storageID
                ),
                transcriptID: transcriptID,
                summary: "This is a sufficiently long summary for deletion testing.",
                aiMethod: "fixture-model",
                generatedAt: Date(timeIntervalSinceReferenceDate: 104),
                wordCount: 8,
                originalLength: 20
            )
        )
        _ = try await repository.createProcessingJob(
            LibraryProcessingJobCreateCommand(
                id: jobID,
                jobType: "transcription",
                engine: "fixture-engine",
                recordingURL: "recording.m4a",
                recordingName: "Delete graph",
                modelName: "fixture-model",
                status: "complete",
                progress: 1,
                startTime: Date(timeIntervalSinceReferenceDate: 106),
                recordingReference: LibraryRecordingReference(
                    storageID: recording.storageID
                ),
                modifiedAt: Date(timeIntervalSinceReferenceDate: 107)
            )
        )
        _ = try await repository.upsertArchiveLocation(
            LibraryArchiveLocationUpsertCommand(
                id: archiveLocationID,
                recordingReference: LibraryRecordingReference(
                    storageID: recording.storageID
                ),
                bookmarkData: Data([1]),
                destinationURLString: "file:///tmp/delete-graph.m4a",
                displayName: "Delete graph archive",
                exportedAt: Date(timeIntervalSinceReferenceDate: 108),
                exportedFilename: "delete-graph.m4a",
                fileSize: 512,
                lastVerifiedAt: Date(timeIntervalSinceReferenceDate: 109),
                providerDisplayName: "fixture-provider",
                status: "verified",
                modifiedAt: Date(timeIntervalSinceReferenceDate: 110)
            )
        )

        return (recording, transcriptID, summaryID, jobID, archiveLocationID)
    }

    private func expectedTranscript() -> LibraryTranscriptSnapshot {
        LibraryTranscriptSnapshot(
            storageID: "transcript-storage",
            legacyID: "transcript-legacy",
            confidence: 0.98,
            createdAt: Date(timeIntervalSinceReferenceDate: 102),
            engine: "fixture-engine",
            lastModified: Date(timeIntervalSinceReferenceDate: 103),
            processingTime: 1.5,
            recordingStorageID: "recording-storage",
            recordingLegacyID: "recording-legacy",
            segments: "{\"segments\":[]}",
            speakerMappings: "{}"
        )
    }

    private func expectedSummary() -> LibrarySummarySnapshot {
        LibrarySummarySnapshot(
            storageID: "summary-storage",
            aiMethod: "fixture-model",
            compressionRatio: nil,
            confidence: 0.9,
            contentType: "summary",
            generatedAt: Date(timeIntervalSinceReferenceDate: 104),
            legacyID: "summary-legacy",
            originalLength: 12,
            processingTime: 2,
            recordingStorageID: "recording-storage",
            recordingLegacyID: "recording-legacy",
            reminders: nil,
            summary: "Fixture summary",
            tasks: nil,
            titles: nil,
            transcriptStorageID: "transcript-storage",
            transcriptLegacyID: "transcript-legacy",
            version: 1,
            wordCount: 2
        )
    }

    private func expectedProcessingJob() -> LibraryProcessingJobSnapshot {
        LibraryProcessingJobSnapshot(
            storageID: "job-storage",
            completionTime: nil,
            engine: "fixture-engine",
            error: nil,
            legacyID: "job-legacy",
            jobType: "transcription",
            lastModified: Date(timeIntervalSinceReferenceDate: 105),
            modelName: "fixture-model",
            progress: 1,
            recordingName: "Fixture recording",
            recordingURL: "recording.m4a",
            recordingStorageID: "recording-storage",
            startTime: Date(timeIntervalSinceReferenceDate: 104),
            status: "complete"
        )
    }

    private func expectedArchiveLocation() -> LibraryArchiveLocationSnapshot {
        LibraryArchiveLocationSnapshot(
            storageID: "archive-storage",
            bookmarkData: Data([1, 2, 3]),
            destinationURLString: "archive://fixture",
            displayName: "Fixture archive",
            exportedAt: Date(timeIntervalSinceReferenceDate: 106),
            exportedFilename: "fixture.m4a",
            fileSize: 42,
            legacyID: "archive-legacy",
            lastVerifiedAt: Date(timeIntervalSinceReferenceDate: 107),
            providerDisplayName: "Fixture provider",
            recordingLegacyID: "recording-legacy",
            status: "verified"
        )
    }

    private func expectedPendingMutation() -> LibraryPendingCloudMutationSnapshot {
        LibraryPendingCloudMutationSnapshot(
            storageID: "mutation-storage",
            kind: "update",
            payload: Data([4, 5, 6]),
            recordingLegacyID: "recording-legacy",
            requestedAt: Date(timeIntervalSinceReferenceDate: 108),
            targetID: "recording-legacy",
            version: 1
        )
    }
}
