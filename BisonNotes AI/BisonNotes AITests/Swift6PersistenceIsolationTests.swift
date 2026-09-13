import XCTest
import CoreData
import AVFoundation
@testable import BisonNotes_AI

@MainActor
final class Swift6PersistenceIsolationTests: XCTestCase {
    func testPersistenceControllerUsesTheExpectedModelAndViewContext() {
        let persistence = PersistenceController(inMemory: true)
        let manager = CoreDataManager(persistenceController: persistence)

        XCTAssertEqual(persistence.container.name, "BisonNotes_AI")
        XCTAssertEqual(persistence.storeState, .explicitlyEphemeral)
        XCTAssertEqual(persistence.container.persistentStoreCoordinator.persistentStores.count, 1)
        XCTAssertEqual(
            persistence.container.persistentStoreCoordinator.persistentStores.first?.type,
            NSInMemoryStoreType
        )
        XCTAssertTrue(manager.contextForTesting === persistence.container.viewContext)
        XCTAssertThrowsError(try persistence.requireDurableStore()) { error in
            let failure = error as? PersistenceStoreFailure
            XCTAssertEqual(failure?.code, 2)
        }
    }

    func testDurablePersistenceUsesOneSQLiteStoreAndPassesReadinessGate() throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(directory) }

        let storeURL = directory.appendingPathComponent("library.sqlite")
        let persistence = PersistenceController(storeURL: storeURL)
        defer { closePersistentStores(of: persistence) }

        XCTAssertEqual(persistence.storeState, .ready)
        XCTAssertTrue(persistence.storeState.isDurable)
        XCTAssertEqual(persistence.container.persistentStoreCoordinator.persistentStores.count, 1)
        XCTAssertEqual(
            persistence.container.persistentStoreCoordinator.persistentStores.first?.type,
            NSSQLiteStoreType
        )
        XCTAssertNoThrow(try persistence.requireDurableStore())
    }

    func testUnavailablePersistenceHasNoInMemoryFallback() throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(directory) }

        let invalidStoreURL = directory.appendingPathComponent("not-a-store.sqlite")
        try FileManager.default.createDirectory(
            at: invalidStoreURL,
            withIntermediateDirectories: false,
            attributes: nil
        )

        let persistence = PersistenceController(storeURL: invalidStoreURL)

        guard case .unavailable(let failure) = persistence.storeState else {
            return XCTFail("An unreadable store URL must produce an unavailable state")
        }
        XCTAssertEqual(persistence.container.persistentStoreCoordinator.persistentStores.count, 0)
        XCTAssertFalse(persistence.storeState.isOperational)
        XCTAssertThrowsError(try persistence.requireDurableStore()) { error in
            XCTAssertEqual(error as? PersistenceStoreFailure, failure)
        }

        let retry = PersistenceController(storeURL: invalidStoreURL)
        XCTAssertEqual(retry.storeState.isOperational, false)
        XCTAssertTrue(retry.container.persistentStoreCoordinator.persistentStores.isEmpty)
    }

    #if DEBUG
    func testInjectedStoreFailureIsDeterministicAndSanitized() throws {
        let previousFailure = PersistenceController.injectedStoreLoadFailure
        defer { PersistenceController.injectedStoreLoadFailure = previousFailure }

        PersistenceController.injectedStoreLoadFailure = PersistenceStoreFailure(
            domain: "/private/tmp/library-with-user-content",
            code: 507,
            underlying: PersistenceStoreFailure(domain: "SQLite /secret", code: 14)
        )

        let directory = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(directory) }
        let persistence = PersistenceController(storeURL: directory.appendingPathComponent("library.sqlite"))

        guard case .unavailable(let failure) = persistence.storeState else {
            return XCTFail("The injected store failure must be surfaced as unavailable")
        }
        XCTAssertEqual(failure.domain, "unknown")
        XCTAssertEqual(failure.code, 507)
        XCTAssertEqual(failure.underlying.first?.domain, "unknown")
        XCTAssertFalse(failure.diagnosticDescription.contains("/"))
        XCTAssertEqual(persistence.container.persistentStoreCoordinator.persistentStores.count, 0)
    }

    func testCollectionReadsThrowInsteadOfReturningEmpty() throws {
        let previousFailure = CoreDataManager.injectedCollectionReadFailure
        defer { CoreDataManager.injectedCollectionReadFailure = previousFailure }

        let persistence = PersistenceController(inMemory: true)
        let manager = CoreDataManager(persistenceController: persistence)
        CoreDataManager.injectedCollectionReadFailure = PersistenceStoreFailure(
            domain: "BisonNotes.ReadTest",
            code: 901
        )

        XCTAssertThrowsError(try manager.getAllRecordings())
        XCTAssertThrowsError(try manager.getAllTranscripts())
        XCTAssertThrowsError(try manager.getAllSummaries())
        XCTAssertThrowsError(try manager.getAllProcessingJobs())
        XCTAssertThrowsError(try manager.getAllRecordingsWithData())
        XCTAssertThrowsError(try manager.getAllSummaryData())

        CoreDataManager.injectedCollectionReadFailure = nil
        XCTAssertTrue(try manager.getAllRecordings().isEmpty)
        XCTAssertTrue(try manager.getAllTranscripts().isEmpty)
        XCTAssertTrue(try manager.getAllSummaries().isEmpty)
        XCTAssertTrue(try manager.getAllProcessingJobs().isEmpty)
    }

    func testCollectionReadFailureCannotAuthorizeCleanupOrCloudSelection() throws {
        let previousFailure = CoreDataManager.injectedCollectionReadFailure
        defer { CoreDataManager.injectedCollectionReadFailure = previousFailure }

        let persistence = PersistenceController(inMemory: true)
        let manager = CoreDataManager(persistenceController: persistence)
        let recording = RecordingEntry(context: manager.contextForTesting)
        recording.id = UUID()
        recording.recordingName = "Read failure fixture"
        recording.recordingDate = Date()
        try manager.contextForTesting.save()

        CoreDataManager.injectedCollectionReadFailure = PersistenceStoreFailure(
            domain: "BisonNotes.ReadTest",
            code: 902
        )

        XCTAssertThrowsError(try manager.cleanupOrphanedRecordings())
        XCTAssertThrowsError(try manager.cleanupDuplicates())
        XCTAssertThrowsError(try iCloudStorageManager.backupSourceSelection(from: manager))

        CoreDataManager.injectedCollectionReadFailure = nil
        XCTAssertEqual(try manager.fetchRecordingsForDiagnostics().count, 1)
    }

    func testProcessingJobReadFailurePreventsStartupAndExecution() async throws {
        let previousFailure = CoreDataManager.injectedCollectionReadFailure
        defer { CoreDataManager.injectedCollectionReadFailure = previousFailure }

        let persistence = PersistenceController(inMemory: true)
        let manager = CoreDataManager(persistenceController: persistence)
        CoreDataManager.injectedCollectionReadFailure = PersistenceStoreFailure(
            domain: "BisonNotes.ReadTest",
            code: 903
        )

        let processingManager = BackgroundProcessingManager.makeForTesting(coreDataManager: manager)
        XCTAssertNotNil(processingManager.jobLoadError)
        XCTAssertTrue(processingManager.activeJobs.isEmpty)

        CoreDataManager.injectedCollectionReadFailure = nil
        do {
            _ = try await processingManager.startSummarizationJob(
                recordingURL: URL(fileURLWithPath: "/tmp/read-failure.m4a"),
                recordingName: "Read failure fixture",
                engine: AIEngineType.mlxSwift.rawValue
            )
            XCTFail("A manager that could not load persisted jobs must not execute a new job")
        } catch {
            XCTAssertTrue(error is BackgroundProcessingError)
        }
        XCTAssertTrue(processingManager.activeJobs.isEmpty)
    }
    #endif

    func testFailedStoreLoadLeavesExistingFixtureReopenable() throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(directory) }

        let storeURL = directory.appendingPathComponent("fixture.sqlite")
        let recordingID = UUID()
        let initial = PersistenceController(storeURL: storeURL)
        XCTAssertEqual(initial.storeState, .ready)
        let recording = RecordingEntry(context: initial.container.viewContext)
        recording.id = recordingID
        recording.recordingName = "Fixture recording"
        recording.recordingURL = "fixture.m4a"
        recording.recordingDate = Date(timeIntervalSince1970: 1_700_000_000)
        recording.createdAt = recording.recordingDate
        recording.lastModified = recording.recordingDate
        recording.duration = 12.5
        recording.fileSize = 4_096
        try initial.container.viewContext.save()
        closePersistentStores(of: initial)

        #if DEBUG
        let previousFailure = PersistenceController.injectedStoreLoadFailure
        defer { PersistenceController.injectedStoreLoadFailure = previousFailure }
        PersistenceController.injectedStoreLoadFailure = PersistenceStoreFailure(
            domain: NSCocoaErrorDomain, code: NSPersistentStoreOpenError
        )
        let failed = PersistenceController(storeURL: storeURL)
        XCTAssertEqual(failed.storeState.isOperational, false)
        XCTAssertTrue(failed.container.persistentStoreCoordinator.persistentStores.isEmpty)
        PersistenceController.injectedStoreLoadFailure = previousFailure
        #else
        throw XCTSkip("Deterministic store failure injection requires a Debug build")
        #endif

        let reopened = PersistenceController(storeURL: storeURL)
        defer { closePersistentStores(of: reopened) }
        let request: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", recordingID as CVarArg)
        let restored = try XCTUnwrap(try reopened.container.viewContext.fetch(request).first)

        XCTAssertEqual(restored.recordingName, "Fixture recording")
        XCTAssertEqual(restored.recordingURL, "fixture.m4a")
        XCTAssertEqual(restored.fileSize, 4_096)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testUnavailableCoordinatorWithholdsPersistenceDependentStartup() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(directory) }

        let invalidStoreURL = directory.appendingPathComponent("failed-store.sqlite")
        try FileManager.default.createDirectory(
            at: invalidStoreURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        let persistence = PersistenceController(storeURL: invalidStoreURL)
        let managerBefore = BackgroundProcessingManager.existingInstance
        let coordinator = AppDataCoordinator(persistenceController: persistence)

        XCTAssertEqual(coordinator.storageState, persistence.storeState)
        XCTAssertFalse(coordinator.storageState.isOperational)
        XCTAssertFalse(coordinator.isInitialized)
        XCTAssertTrue(persistence.container.persistentStoreCoordinator.persistentStores.isEmpty)
        XCTAssertThrowsError(try coordinator.requireDurableStore())

        switch (managerBefore, BackgroundProcessingManager.existingInstance) {
        case let (before?, after?):
            XCTAssertTrue(before === after, "Unavailable startup must not initialize a processing manager")
        case (nil, nil):
            break
        default:
            XCTFail("Unavailable startup initialized or replaced a processing manager")
        }

        let sourceURL = directory.appendingPathComponent("retained.m4a")
        try Data("not imported".utf8).write(to: sourceURL)
        let fileImporter = FileImportManager(persistenceController: persistence)
        await fileImporter.importAudioFiles(from: [sourceURL])
        XCTAssertFalse(fileImporter.isImporting)
        XCTAssertNil(fileImporter.importResults)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))

        let migrationManager = DataMigrationManager(persistenceController: persistence)
        await migrationManager.performDataMigration()
        XCTAssertFalse(migrationManager.isCompleted)
        XCTAssertEqual(migrationManager.migrationProgress, 0)

        coordinator.observeNetworkRestorationForiCloud()
    }

    func testAttachmentStoreRoundTripPreservesNotesAndAttachments() throws {
        let summaryID = UUID()
        let store = SummaryAttachmentStore.shared
        defer { try? store.deleteAll(for: summaryID) }

        try store.saveUserNotes("  Keep this note.  ", summaryId: summaryID)

        let supplemental = store.load(for: summaryID)
        XCTAssertEqual(supplemental.userNotes, "Keep this note.")
        XCTAssertTrue(supplemental.attachments.isEmpty)
    }

    func testAttachmentMigrationPreservesStoredFiles() throws {
        let oldSummaryID = UUID()
        let newSummaryID = UUID()
        let store = SummaryAttachmentStore.shared
        defer {
            try? store.deleteAll(for: oldSummaryID)
            try? store.deleteAll(for: newSummaryID)
        }

        try store.saveUserNotes("Migrated note", summaryId: oldSummaryID)
        try store.migrate(from: oldSummaryID, to: newSummaryID)

        XCTAssertEqual(store.load(for: newSummaryID).userNotes, "Migrated note")
        XCTAssertNil(store.load(for: oldSummaryID).userNotes)
    }

    private func closePersistentStores(of controller: PersistenceController) {
        let coordinator = controller.container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }
}

#if DEBUG
extension Swift6PersistenceIsolationTests {
    func testTranscriptDeletionReadFailureLeavesLinksAndPendingEditsIntact() throws {
        let persistence = PersistenceController(inMemory: true)
        let manager = CoreDataManager(persistenceController: persistence)
        let context = manager.contextForTesting
        let recording = RecordingEntry(context: context)
        recording.id = UUID()
        let transcript = TranscriptEntry(context: context)
        transcript.id = UUID()
        transcript.recording = recording
        transcript.recordingId = recording.id
        recording.transcript = transcript
        recording.transcriptId = transcript.id
        try context.save()
        recording.recordingName = "Unrelated pending edit"

        let previousFailure = CoreDataManager.injectedCollectionReadFailure
        let previousOperation = CoreDataManager.injectedCollectionReadOperation
        defer {
            CoreDataManager.injectedCollectionReadFailure = previousFailure
            CoreDataManager.injectedCollectionReadOperation = previousOperation
        }
        CoreDataManager.injectedCollectionReadFailure = PersistenceStoreFailure(domain: "ReadTest", code: 904)
        CoreDataManager.injectedCollectionReadOperation = "summaries"
        XCTAssertThrowsError(try manager.deleteTranscript(id: transcript.id))
        XCTAssertTrue(recording.transcript === transcript)
        XCTAssertEqual(recording.transcriptId, transcript.id)
        XCTAssertFalse(transcript.isDeleted)
        XCTAssertEqual(recording.recordingName, "Unrelated pending edit")
        XCTAssertTrue(context.hasChanges)
        CoreDataManager.injectedCollectionReadFailure = nil
        try context.save()
        context.refreshAllObjects()
        XCTAssertEqual(recording.transcriptId, transcript.id)
        XCTAssertEqual(recording.recordingName, "Unrelated pending edit")
    }

    func testDuplicateRecordingIdentityPreventsPruningAmbiguousContent() throws {
        let persistence = PersistenceController(inMemory: true)
        let manager = CoreDataManager(persistenceController: persistence)
        let context = manager.contextForTesting
        let sharedID = UUID()
        let first = RecordingEntry(context: context)
        first.id = sharedID
        let second = RecordingEntry(context: context)
        second.id = sharedID
        let transcript = TranscriptEntry(context: context)
        transcript.id = UUID()
        transcript.recordingId = sharedID
        let summary = SummaryEntry(context: context)
        summary.id = UUID()
        summary.recordingId = sharedID
        // No inverse link: ownership has to be resolved using the duplicate ID.
        try context.save()
        let result = try manager.deleteSupersededDuplicates(
            transcriptIds: [try XCTUnwrap(transcript.id)], summaryIds: [try XCTUnwrap(summary.id)]
        )
        XCTAssertEqual(result.transcripts, 0)
        XCTAssertEqual(result.summaries, 0)
        XCTAssertEqual(try manager.getAllRecordings().count, 2)
        XCTAssertEqual(try manager.getAllTranscripts().count, 1)
        XCTAssertEqual(try manager.getAllSummaries().count, 1)
        XCTAssertFalse(context.hasChanges)
    }

    func testURLLookupPreservesEncodedAndMovedPathsAndThrowsOnFailure() throws {
        let persistence = PersistenceController(inMemory: true)
        let manager = CoreDataManager(persistenceController: persistence)
        let context = manager.contextForTesting
        let recording = RecordingEntry(context: context)
        recording.id = UUID()
        recording.recordingURL = "Meeting%201.m4a"
        try context.save()
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let target = documents.appendingPathComponent("Meeting 1.m4a")
        XCTAssertTrue(try manager.fetchRecording(url: target) === recording)
        recording.recordingURL = "file:///old-container/Documents/Meeting%201.m4a"
        try context.save()
        XCTAssertTrue(try manager.fetchRecording(url: target) === recording)
        XCTAssertFalse(context.hasChanges, "A lookup must not rewrite legacy paths")

        let previousFailure = CoreDataManager.injectedCollectionReadFailure
        defer { CoreDataManager.injectedCollectionReadFailure = previousFailure }
        CoreDataManager.injectedCollectionReadFailure = PersistenceStoreFailure(domain: "ReadTest", code: 905)
        XCTAssertThrowsError(try manager.fetchRecording(url: target))
    }

    func testRelationshipRefreshRetainsSnapshotWhenSummaryReadFails() async throws {
        let persistence = PersistenceController(inMemory: true)
        let coordinator = AppDataCoordinator(persistenceController: persistence)
        let files = EnhancedFileManager.shared
        let previousCoordinator = files.getCoordinator()
        let previousRelationships = files.fileRelationships
        let previousFailure = CoreDataManager.injectedCollectionReadFailure
        let previousOperation = CoreDataManager.injectedCollectionReadOperation
        defer {
            files.fileRelationships = previousRelationships
            files.setCoordinator(previousCoordinator)
            CoreDataManager.injectedCollectionReadFailure = previousFailure
            CoreDataManager.injectedCollectionReadOperation = previousOperation
        }
        files.setCoordinator(coordinator)
        let url = URL(fileURLWithPath: "/private/tmp/missing-relationship-fixture.m4a")
        let relationship = FileRelationships(
            recordingURL: url, recordingName: "Retained", recordingDate: Date(), transcriptExists: true
        )
        files.fileRelationships = [url: relationship]
        CoreDataManager.injectedCollectionReadFailure = PersistenceStoreFailure(domain: "ReadTest", code: 906)
        CoreDataManager.injectedCollectionReadOperation = "summaries"
        XCTAssertThrowsError(try files.refreshAllRelationshipsFromStore())
        XCTAssertEqual(files.fileRelationships[url]?.id, relationship.id)
        do {
            try await files.refreshRelationships(for: url)
            XCTFail("A failed summary read must stop refresh")
        } catch {
            XCTAssertEqual(files.fileRelationships[url]?.id, relationship.id)
        }
    }

    func testSummaryReadFailureStopsPreservingDeleteBeforeTranscriptRemoval() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(directory) }

        let persistence = PersistenceController(inMemory: true)
        let coordinator = AppDataCoordinator(persistenceController: persistence)
        let manager = coordinator.coreDataManager
        let context = manager.contextForTesting
        let recordingID = UUID()
        let transcriptID = UUID()
        let summaryID = UUID()
        let url = directory.appendingPathComponent("preserve-summary-read-failure.m4a")
        try Data("audio fixture".utf8).write(to: url)

        let recording = RecordingEntry(context: context)
        recording.id = recordingID
        recording.recordingURL = url.lastPathComponent
        recording.recordingName = "Preserved summary fixture"
        recording.recordingDate = Date()
        let transcript = TranscriptEntry(context: context)
        transcript.id = transcriptID
        transcript.recordingId = recordingID
        transcript.recording = recording
        recording.transcript = transcript
        recording.transcriptId = transcriptID
        let summary = SummaryEntry(context: context)
        summary.id = summaryID
        summary.recordingId = recordingID
        summary.recording = recording
        try context.save()

        let files = EnhancedFileManager.shared
        let previousCoordinator = files.getCoordinator()
        let previousRelationships = files.fileRelationships
        let previousFailure = CoreDataManager.injectedCollectionReadFailure
        let previousOperation = CoreDataManager.injectedCollectionReadOperation
        defer {
            files.fileRelationships = previousRelationships
            files.setCoordinator(previousCoordinator)
            CoreDataManager.injectedCollectionReadFailure = previousFailure
            CoreDataManager.injectedCollectionReadOperation = previousOperation
        }
        files.setCoordinator(coordinator)
        files.fileRelationships = [url: FileRelationships(
            recordingURL: url,
            recordingName: recording.recordingName ?? "",
            recordingDate: recording.recordingDate ?? Date(),
            transcriptExists: true,
            summaryExists: true
        )]
        CoreDataManager.injectedCollectionReadFailure = PersistenceStoreFailure(domain: "ReadTest", code: 915)
        CoreDataManager.injectedCollectionReadOperation = "summaries"

        do {
            try await files.deleteRecording(url, preserveSummary: true)
            XCTFail("A failed summary read must not authorize transcript or source deletion")
        } catch {
            XCTAssertNotNil(error)
        }

        CoreDataManager.injectedCollectionReadFailure = nil
        CoreDataManager.injectedCollectionReadOperation = nil
        XCTAssertNotNil(try manager.fetchTranscript(for: recordingID))
        XCTAssertNotNil(try manager.fetchSummary(for: recordingID))
        XCTAssertNotNil(try manager.fetchRecording(id: recordingID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testB2WorkflowSaveFailuresThrowAndDoNotLeakFailedRows() throws {
        let persistence = PersistenceController(inMemory: true)
        let coordinator = AppDataCoordinator(persistenceController: persistence)
        let manager = coordinator.coreDataManager
        let context = manager.contextForTesting
        let pendingRecording = RecordingEntry(context: context)
        let pendingRecordingID = UUID()
        pendingRecording.id = pendingRecordingID
        pendingRecording.recordingName = "Unrelated pending edit"

        let previousFailure = CoreDataManager.injectedSaveFailure
        let previousOperation = CoreDataManager.injectedSaveOperation
        defer {
            CoreDataManager.injectedSaveFailure = previousFailure
            CoreDataManager.injectedSaveOperation = previousOperation
        }

        let audioURL = URL(fileURLWithPath: "/private/tmp/b2-workflow-fixture.m4a")
        CoreDataManager.injectedSaveFailure = PersistenceStoreFailure(domain: "SaveTest", code: 907)
        CoreDataManager.injectedSaveOperation = "recording creation"
        XCTAssertThrowsError(try coordinator.addRecording(
            url: audioURL,
            name: "Failed recording",
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        ))

        CoreDataManager.injectedSaveFailure = nil
        CoreDataManager.injectedSaveOperation = nil
        try context.save()
        XCTAssertEqual(try manager.fetchRecording(id: pendingRecordingID)?.recordingName, "Unrelated pending edit")
        XCTAssertFalse(try manager.getAllRecordings().contains { $0.recordingName == "Failed recording" })

        let recordingID = try coordinator.addRecording(
            url: audioURL,
            name: "Durable recording",
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )
        let segments = [TranscriptSegment(speaker: "Speaker 1", text: "Durable transcript", startTime: 0, endTime: 1)]

        CoreDataManager.injectedSaveFailure = PersistenceStoreFailure(domain: "SaveTest", code: 908)
        CoreDataManager.injectedSaveOperation = "transcript creation"
        XCTAssertThrowsError(try coordinator.addTranscript(for: recordingID, segments: segments))
        CoreDataManager.injectedSaveFailure = nil
        CoreDataManager.injectedSaveOperation = nil
        try context.save()
        XCTAssertNil(try manager.fetchTranscript(for: recordingID))
        XCTAssertEqual(try manager.fetchRecording(id: recordingID)?.transcriptionStatus, ProcessingStatus.notStarted.rawValue)

        let transcriptID = try XCTUnwrap(try coordinator.addTranscript(for: recordingID, segments: segments))
        CoreDataManager.injectedSaveFailure = PersistenceStoreFailure(domain: "SaveTest", code: 909)
        CoreDataManager.injectedSaveOperation = "summary creation"
        XCTAssertThrowsError(try coordinator.addSummary(
            for: recordingID,
            transcriptId: transcriptID,
            summary: "This summary is long enough to exercise the failed durable save path.",
            aiModel: "fixture",
            originalLength: 32
        ))
        CoreDataManager.injectedSaveFailure = nil
        CoreDataManager.injectedSaveOperation = nil
        try context.save()
        XCTAssertEqual(try manager.fetchRecording(id: recordingID)?.summaryStatus, ProcessingStatus.notStarted.rawValue)
        XCTAssertTrue(try manager.fetchSummaries(forRecordingId: recordingID).isEmpty)
    }

    func testB2ProcessingJobSaveFailuresDoNotAuthorizeExecutionOrCleanup() throws {
        let persistence = PersistenceController(inMemory: true)
        let manager = CoreDataManager(persistenceController: persistence)
        let context = manager.contextForTesting
        let unrelated = RecordingEntry(context: context)
        let unrelatedID = UUID()
        unrelated.id = unrelatedID
        unrelated.recordingName = "Unrelated pending edit"

        let previousSaveFailure = CoreDataManager.injectedSaveFailure
        let previousSaveOperation = CoreDataManager.injectedSaveOperation
        let previousReadFailure = CoreDataManager.injectedCollectionReadFailure
        let previousReadOperation = CoreDataManager.injectedCollectionReadOperation
        defer {
            CoreDataManager.injectedSaveFailure = previousSaveFailure
            CoreDataManager.injectedSaveOperation = previousSaveOperation
            CoreDataManager.injectedCollectionReadFailure = previousReadFailure
            CoreDataManager.injectedCollectionReadOperation = previousReadOperation
        }

        let recordingURL = URL(fileURLWithPath: "/private/tmp/b2-job-fixture.m4a")
        let jobID = UUID()
        CoreDataManager.injectedSaveFailure = PersistenceStoreFailure(domain: "SaveTest", code: 910)
        CoreDataManager.injectedSaveOperation = "processing job creation"
        XCTAssertThrowsError(try manager.createProcessingJob(
            id: jobID,
            jobType: "Transcription",
            engine: "Fixture",
            recordingURL: recordingURL,
            recordingName: "Job fixture"
        ))

        CoreDataManager.injectedSaveFailure = nil
        CoreDataManager.injectedSaveOperation = nil
        try context.save()
        XCTAssertNil(try manager.fetchProcessingJob(id: jobID))
        XCTAssertEqual(try manager.fetchRecording(id: unrelatedID)?.recordingName, "Unrelated pending edit")

        let job = try manager.createProcessingJob(
            id: jobID,
            jobType: "Transcription",
            engine: "Fixture",
            recordingURL: recordingURL,
            recordingName: "Job fixture"
        )
        job.status = "completed"
        job.progress = 1
        CoreDataManager.injectedSaveFailure = PersistenceStoreFailure(domain: "SaveTest", code: 911)
        CoreDataManager.injectedSaveOperation = "processing job update"
        XCTAssertThrowsError(try manager.updateProcessingJob(job))
        CoreDataManager.injectedSaveFailure = nil
        CoreDataManager.injectedSaveOperation = nil
        XCTAssertEqual(try manager.fetchProcessingJob(id: jobID)?.status, "queued")

        CoreDataManager.injectedSaveFailure = PersistenceStoreFailure(domain: "SaveTest", code: 912)
        CoreDataManager.injectedSaveOperation = "processing job deletion"
        XCTAssertThrowsError(try manager.deleteProcessingJob(job))
        CoreDataManager.injectedSaveFailure = nil
        CoreDataManager.injectedSaveOperation = nil
        XCTAssertNotNil(try manager.fetchProcessingJob(id: jobID))
        try manager.deleteProcessingJob(job)
        XCTAssertNil(try manager.fetchProcessingJob(id: jobID))

        let completedJob = try manager.createProcessingJob(
            id: UUID(),
            jobType: "Summarization",
            engine: "Fixture",
            recordingURL: recordingURL,
            recordingName: "Completed fixture"
        )
        let completedJobID = try XCTUnwrap(completedJob.id)
        completedJob.status = "completed"
        completedJob.progress = 1
        try manager.updateProcessingJob(completedJob)
        CoreDataManager.injectedSaveFailure = PersistenceStoreFailure(domain: "SaveTest", code: 913)
        CoreDataManager.injectedSaveOperation = "completed processing job deletion"
        XCTAssertThrowsError(try manager.deleteCompletedProcessingJobs())
        CoreDataManager.injectedSaveFailure = nil
        CoreDataManager.injectedSaveOperation = nil
        XCTAssertNotNil(try manager.fetchProcessingJob(id: completedJobID))

        CoreDataManager.injectedCollectionReadFailure = PersistenceStoreFailure(domain: "ReadTest", code: 914)
        CoreDataManager.injectedCollectionReadOperation = "recordings"
        XCTAssertThrowsError(try manager.createProcessingJob(
            id: UUID(),
            jobType: "Transcription",
            engine: "Fixture",
            recordingURL: recordingURL,
            recordingName: "Read failure fixture"
        ))
        CoreDataManager.injectedCollectionReadFailure = nil
        CoreDataManager.injectedCollectionReadOperation = nil
        XCTAssertEqual(try manager.getAllProcessingJobs().count, 1)
    }

    func testWorkflowSuccessDoesNotCommitUnrelatedPendingEdits() throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(directory) }
        let persistence = PersistenceController(storeURL: directory.appendingPathComponent("isolation.sqlite"))
        defer { closePersistentStores(of: persistence) }
        let coordinator = AppDataCoordinator(persistenceController: persistence)
        let manager = coordinator.coreDataManager
        let context = manager.contextForTesting
        let recordingID = try coordinator.addRecording(
            url: directory.appendingPathComponent("recording.m4a"), name: "Stored name",
            date: Date(), fileSize: 100, duration: 1, quality: .whisperOptimized
        )
        let recording = try XCTUnwrap(try manager.fetchRecording(id: recordingID))
        recording.recordingName = "Pending rename"
        let pending = RecordingEntry(context: context)
        pending.id = UUID()
        pending.recordingName = "Pending insertion"
        _ = try coordinator.addRecording(
            url: directory.appendingPathComponent("second.m4a"), name: "Second durable row",
            date: Date(), fileSize: 100, duration: 1, quality: .whisperOptimized
        )
        let transcriptID = try XCTUnwrap(try coordinator.addTranscript(
            for: recordingID,
            segments: [TranscriptSegment(speaker: "Speaker", text: "First text", startTime: 0, endTime: 1)]
        ))
        _ = try coordinator.addTranscript(
            for: recordingID,
            segments: [TranscriptSegment(speaker: "Speaker", text: "Replacement text", startTime: 0, endTime: 1)]
        )
        _ = try coordinator.addSummary(
            for: recordingID, transcriptId: transcriptID,
            summary: "A sufficiently long summary for the isolated workflow save regression.",
            aiModel: "fixture", originalLength: 40
        )
        XCTAssertEqual(recording.recordingName, "Pending rename")
        XCTAssertTrue(pending.isInserted)
        XCTAssertTrue(context.hasChanges)
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = context.persistentStoreCoordinator
        let stored = try XCTUnwrap(try reader.existingObject(with: recording.objectID) as? RecordingEntry)
        XCTAssertEqual(stored.recordingName, "Stored name")
        let request = NSFetchRequest<RecordingEntry>(entityName: "RecordingEntry")
        XCTAssertEqual(try reader.count(for: request), 2)
        XCTAssertNotNil(stored.transcript)
        XCTAssertNotNil(stored.summary)
    }

    func testAudioImportSaveFailureDoesNotAcknowledgeOrConsumeSource() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(directory) }
        let prefix = "B2-import-" + UUID().uuidString
        let source = directory.appendingPathComponent(prefix + ".wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        do {
            let audio = try AVAudioFile(forWriting: source, settings: format.settings)
            try audio.write(from: buffer)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        defer {
            let owned = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
            for url in owned where url.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: url) }
        }
        let persistence = PersistenceController(inMemory: true)
        let importer = FileImportManager(persistenceController: persistence)
        let previousFailure = CoreDataManager.injectedSaveFailure
        let previousOperation = CoreDataManager.injectedSaveOperation
        defer {
            CoreDataManager.injectedSaveFailure = previousFailure
            CoreDataManager.injectedSaveOperation = previousOperation
        }
        CoreDataManager.injectedSaveFailure = PersistenceStoreFailure(domain: "SaveTest", code: 910)
        CoreDataManager.injectedSaveOperation = "imported recording creation"
        let failed = await importer.importAudioFiles(from: [source])
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(importer.importResults?.failed, 1)
        ImportSourceCleanup.removeAcknowledged(failed, from: [source])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        CoreDataManager.injectedSaveFailure = nil
        CoreDataManager.injectedSaveOperation = nil
        let successful = await importer.importAudioFiles(from: [source])
        XCTAssertEqual(successful, [source])
        ImportSourceCleanup.removeAcknowledged(successful, from: [source])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testImportCleanupRetainsFailedAndUnacknowledgedSources() throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(directory) }
        let files = ["saved.txt", "failed.txt", "unsupported.bin", "outside.txt"].map {
            directory.appendingPathComponent($0)
        }
        for file in files { try Data("source".utf8).write(to: file) }
        ImportSourceCleanup.removeAcknowledged([files[0], files[3]], from: Array(files.prefix(3)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
        for file in files.dropFirst() { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    }

    #if os(iOS)
    func testWatchFailedImportAllowsRetryWithSameRecordingID() throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(directory) }
        let url = directory.appendingPathComponent("watch.m4a")
        try Data("audio fixture".utf8).write(to: url)
        let receiver = WatchConnectivityManager(testing: true)
        let id = UUID()
        let metadata: [String: Any] = [
            "recordingId": id.uuidString, "filename": "watch.m4a",
            "duration": TimeInterval(1), "fileSize": Int64(13), "createdAt": Date().timeIntervalSince1970
        ]
        var received = 0
        receiver.onWatchSyncRecordingReceived = { _, _ in received += 1 }
        receiver.receiveForTesting(fileURL: url, metadata: metadata)
        receiver.receiveForTesting(fileURL: url, metadata: metadata)
        XCTAssertEqual(received, 1)
        receiver.confirmSyncComplete(recordingId: id, success: false)
        receiver.receiveForTesting(fileURL: url, metadata: metadata)
        XCTAssertEqual(received, 2)
        receiver.confirmSyncComplete(recordingId: id, success: false)
    }
    #endif

    func testB2SuccessfulMutationsSurviveClosingAndReopeningStore() throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(directory) }
        let storeURL = directory.appendingPathComponent("b2-fixture.sqlite")
        let persistence = PersistenceController(storeURL: storeURL)
        let coordinator = AppDataCoordinator(persistenceController: persistence)
        let audioURL = directory.appendingPathComponent("durable.m4a")
        let recordingID = try coordinator.addRecording(
            url: audioURL,
            name: "Durable B2 fixture",
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )
        let transcriptID = try XCTUnwrap(try coordinator.addTranscript(
            for: recordingID,
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "Survives reopening", startTime: 0, endTime: 1)]
        ))
        let summaryID = try XCTUnwrap(try coordinator.addSummary(
            for: recordingID,
            transcriptId: transcriptID,
            summary: "A durable summary that should remain available after closing and reopening the store.",
            aiModel: "fixture",
            originalLength: 40
        ))
        let jobID = UUID()
        _ = try coordinator.coreDataManager.createProcessingJob(
            id: jobID,
            jobType: "Transcription",
            engine: "Fixture",
            recordingURL: audioURL,
            recordingName: "Durable B2 fixture"
        )
        closePersistentStores(of: persistence)

        let reopened = PersistenceController(storeURL: storeURL)
        defer { closePersistentStores(of: reopened) }
        let reopenedManager = CoreDataManager(persistenceController: reopened)
        XCTAssertEqual(try reopenedManager.fetchRecording(id: recordingID)?.recordingName, "Durable B2 fixture")
        XCTAssertEqual(try reopenedManager.fetchTranscript(id: transcriptID)?.recordingId, recordingID)
        XCTAssertEqual(try reopenedManager.fetchSummary(id: summaryID)?.recordingId, recordingID)
        XCTAssertEqual(try reopenedManager.fetchProcessingJob(id: jobID)?.status, "queued")
    }
}
#endif
