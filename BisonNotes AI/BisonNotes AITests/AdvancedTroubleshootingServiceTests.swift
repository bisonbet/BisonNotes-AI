import CoreData
import XCTest
@testable import BisonNotes_AI

// These focused cases stay together so the complete review-to-delete contract
// is covered against the same in-memory store and temporary file boundary.
// swiftlint:disable file_length

@MainActor
// swiftlint:disable:next type_body_length
final class AdvancedTroubleshootingServiceTests: XCTestCase {
    private var persistenceController: PersistenceController!
    private var coreDataManager: CoreDataManager!
    private var documentsURL: URL!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        coreDataManager = CoreDataManager(persistenceController: persistenceController)
        documentsURL = try TestHelpers.createTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let documentsURL {
            try? TestHelpers.cleanupTemporaryDirectory(documentsURL)
        }
        documentsURL = nil
        coreDataManager = nil
        persistenceController = nil
    }

    func testReportIsCompleteAndDoesNotMutateLocalRowsOrOutbox() async throws {
        let context = coreDataManager.managedObjectContext
        let retained = insertRecording(name: "Retained metadata")
        let retainedID = try XCTUnwrap(retained.id)
        try PendingCloudMutationStore.enqueue(
            PendingCloudMutation(
                kind: .recordingDeletion,
                targetId: retainedID,
                recordingId: retainedID,
                requestedAt: Date()
            ),
            in: context
        )
        try context.save()
        let beforeOutbox = try PendingCloudMutationStore.fetchAll(in: context)

        let report = try await makeService().makeLocalDataReport()

        XCTAssertEqual(report.status, .complete)
        XCTAssertEqual(report.recordingCount, 1)
        XCTAssertEqual(report.transcriptCount, 0)
        XCTAssertEqual(report.summaryCount, 0)
        XCTAssertEqual(report.processingJobCount, 0)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(try PendingCloudMutationStore.fetchAll(in: context), beforeOutbox)
    }

    func testReportClassifiesArchivedImportedSummaryOnlyAndMetadataOnlyRows() async throws {
        let archived = insertRecording(
            name: "Archived",
            url: documentsURL.appendingPathComponent("missing-archive.m4a"),
            archived: true
        )
        _ = archived

        let imported = insertRecording(
            name: "Imported",
            url: documentsURL.appendingPathComponent("missing-import.m4a"),
            audioQuality: "imported"
        )
        _ = imported

        let summaryOnlyID = UUID()
        let summaryOnly = insertRecording(
            name: "Summary only",
            summaryID: summaryOnlyID
        )
        insertSummary(id: summaryOnlyID, recording: summaryOnly)

        _ = insertRecording(name: "Metadata only")
        try coreDataManager.managedObjectContext.save()

        let report = try await makeService().makeLocalDataReport()

        XCTAssertEqual(report.count(for: .archived), 1)
        XCTAssertEqual(report.count(for: .imported), 1)
        XCTAssertEqual(report.count(for: .summaryOnly), 1)
        XCTAssertEqual(report.count(for: .metadataOnly), 1)
        XCTAssertTrue(report.issues.isEmpty, report.issues.map(\.message).joined(separator: "\n"))
    }

    func testSameNameRecordingsWithDifferentIDsAreNotDeclaredDuplicates() async throws {
        _ = insertRecording(name: "Same display name")
        _ = insertRecording(name: "Same display name")
        try coreDataManager.managedObjectContext.save()

        let report = try await makeService().makeLocalDataReport()

        XCTAssertFalse(report.issues.contains { $0.category == .duplicateIdentity })
    }

    func testReportFlagsARealRelationshipMismatchWithoutChangingRows() async throws {
        let recording = insertRecording(name: "Relationship mismatch")
        let transcript = TranscriptEntry(context: coreDataManager.managedObjectContext)
        transcript.id = UUID()
        transcript.recordingId = recording.id
        try coreDataManager.managedObjectContext.save()

        let report = try await makeService().makeLocalDataReport()

        XCTAssertTrue(report.issues.contains { issue in
            issue.category == .relationship && issue.message.contains("has no recording relationship")
        })
        XCTAssertNil(recording.transcript)
        XCTAssertEqual(recording.transcriptId, nil)
        XCTAssertEqual(coreDataManager.getAllTranscripts().count, 1)
    }

    func testReportSurfacesDirectoryFailureInsteadOfReportingAnEmptyFolder() async throws {
        let fileSystem = ControlledFileSystem(directoryFails: true)

        let report = try await makeService(fileSystem: fileSystem).makeLocalDataReport()

        XCTAssertEqual(report.status, .failed)
        XCTAssertTrue(report.hasIssues)
        XCTAssertTrue(report.warnings.contains { $0.localizedCaseInsensitiveContains("scan failed") })
    }

    func testDatabaseReadFailureSurfacesAnErrorInsteadOfAnEmptyReport() async throws {
        let failingReader = FailingDatabaseReader()

        do {
            _ = try await makeService(databaseReader: failingReader).makeLocalDataReport()
            XCTFail("A database read failure must not produce an empty report.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No local data was changed"))
        }

        let orphan = try writeFile(named: "database-failure.m4a", byteCount: 16)
        let fingerprint = try LocalAdvancedTroubleshootingFileSystem().metadata(for: orphan)
        do {
            _ = try await makeService(databaseReader: failingReader).deleteSelectedAudio(
                candidates: [
                    UnreferencedAudioCandidate(
                        id: fingerprint.path,
                        path: fingerprint.path,
                        fileName: orphan.lastPathComponent,
                        byteCount: fingerprint.byteCount,
                        fingerprint: fingerprint
                    )
                ],
                selectedIDs: [fingerprint.path]
            )
            XCTFail("A database read failure must prevent audio deletion.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No local data was changed"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testAudioScanOnlyReturnsUnreferencedSupportedTopLevelFiles() async throws {
        let orphan = try writeFile(named: "orphan.m4a", byteCount: 10)
        let referenced = try writeFile(named: "referenced.wav", byteCount: 20)
        let unsupported = try writeFile(named: "not-audio.caf", byteCount: 30)
        let nestedDirectory = documentsURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let nested = nestedDirectory.appendingPathComponent("nested.m4a")
        try Data(repeating: 0x01, count: 40).write(to: nested)

        _ = insertRecording(name: "Referenced", url: referenced)
        try coreDataManager.managedObjectContext.save()

        let result = try await makeService().scanUnreferencedAudio()

        XCTAssertEqual(result.candidates.map(\.fileName), ["orphan.m4a"])
        XCTAssertEqual(result.protectedFileCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unsupported.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testLegacyAbsoluteReferenceFallbackProtectsCurrentFilename() async throws {
        _ = try writeFile(named: "legacy.m4a", byteCount: 10)
        _ = insertRecording(
            name: "Legacy path",
            url: URL(fileURLWithPath: "/old-container/legacy.m4a")
        )
        try coreDataManager.managedObjectContext.save()

        let scan = try await makeService().scanUnreferencedAudio()
        let report = try await makeService().makeLocalDataReport()

        XCTAssertTrue(scan.candidates.isEmpty)
        XCTAssertEqual(scan.protectedFileCount, 1)
        XCTAssertFalse(report.issues.contains { $0.category == .missingAudio })
    }

    func testEmptyAudioScanIsSuccessfulAndDoesNotDeleteAnything() async throws {
        let result = try await makeService().scanUnreferencedAudio()

        XCTAssertEqual(result.candidates, [])
        XCTAssertEqual(result.protectedFileCount, 0)
        XCTAssertNil(result.deletionUnavailableReason)
    }

    func testRepeatedScanDoesNotDeleteOrChangeTheReviewSet() async throws {
        _ = try writeFile(named: "repeat.m4a", byteCount: 12)

        let first = try await makeService().scanUnreferencedAudio()
        let second = try await makeService().scanUnreferencedAudio()

        XCTAssertEqual(first.candidates.map(\.path), second.candidates.map(\.path))
        XCTAssertEqual(first.candidates.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.candidates[0].path))
    }

    func testDeletionRemovesOnlyExplicitlySelectedAudioAndPermittedSidecars() async throws {
        let selected = try writeFile(named: "selected.m4a", byteCount: 11)
        let selectedSidecar = documentsURL.appendingPathComponent("selected.location")
        try Data(repeating: 0x02, count: 5).write(to: selectedSidecar)
        let unselected = try writeFile(named: "unselected.m4a", byteCount: 13)
        let referenced = try writeFile(named: "referenced.m4a", byteCount: 17)
        _ = insertRecording(name: "Referenced", url: referenced)
        try coreDataManager.managedObjectContext.save()

        let service = makeService()
        let scan = try await service.scanUnreferencedAudio()
        let selectedCandidate = try XCTUnwrap(scan.candidates.first { $0.path == canonicalPath(selected) })

        let result = try await service.deleteSelectedAudio(
            candidates: scan.candidates,
            selectedIDs: [selectedCandidate.id]
        )

        XCTAssertEqual(result.requestedCount, 1)
        XCTAssertEqual(result.deletedAudioCount, 1)
        XCTAssertEqual(result.deletedSidecarCount, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: selectedSidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unselected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertEqual(coreDataManager.getAllRecordings().count, 1)
    }

    func testDeletionSkipsAFileThatBecomesReferencedAfterScan() async throws {
        let orphan = try writeFile(named: "becomes-referenced.m4a", byteCount: 14)
        let service = makeService()
        let scan = try await service.scanUnreferencedAudio()
        let candidate = try XCTUnwrap(scan.candidates.first)

        _ = insertRecording(name: "New reference", url: orphan)
        try coreDataManager.managedObjectContext.save()

        let result = try await service.deleteSelectedAudio(
            candidates: scan.candidates,
            selectedIDs: [candidate.id]
        )

        XCTAssertEqual(result.deletedAudioCount, 0)
        XCTAssertEqual(result.skipped.first?.reason, .becameReferenced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testDeletionSkipsAFileThatChangesAfterScan() async throws {
        let orphan = try writeFile(named: "changed.m4a", byteCount: 15)
        let service = makeService()
        let scan = try await service.scanUnreferencedAudio()
        let candidate = try XCTUnwrap(scan.candidates.first)
        try Data(repeating: 0x07, count: 99).write(to: orphan)

        let result = try await service.deleteSelectedAudio(
            candidates: scan.candidates,
            selectedIDs: [candidate.id]
        )

        XCTAssertEqual(result.deletedAudioCount, 0)
        XCTAssertEqual(result.skipped.first?.reason, .changedOrReplaced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testDeletionSkipsAReviewedFileWithoutStableIdentity() async throws {
        let path = canonicalPath(documentsURL.appendingPathComponent("ambiguous.m4a"))
        let fingerprint = AudioFileFingerprint(
            path: path,
            byteCount: 16,
            modificationDate: Date(timeIntervalSince1970: 1),
            fileIdentifier: nil
        )
        let fileSystem = ControlledFileSystem(
            listedFiles: [fingerprint],
            metadataByPath: [path: fingerprint]
        )

        let result = try await makeService(fileSystem: fileSystem).deleteSelectedAudio(
            candidates: [
                UnreferencedAudioCandidate(
                    id: path,
                    path: path,
                    fileName: "ambiguous.m4a",
                    byteCount: fingerprint.byteCount,
                    fingerprint: fingerprint
                )
            ],
            selectedIDs: [path]
        )

        XCTAssertEqual(result.deletedAudioCount, 0)
        XCTAssertEqual(result.skipped.first?.reason, .changedOrReplaced)
    }

    func testDeletionRejectsASelectedUnsupportedExtension() async throws {
        let path = canonicalPath(documentsURL.appendingPathComponent("not-audio.caf"))
        let fingerprint = AudioFileFingerprint(
            path: path,
            byteCount: 17,
            modificationDate: Date(timeIntervalSince1970: 1),
            fileIdentifier: 17
        )
        let fileSystem = ControlledFileSystem(
            listedFiles: [fingerprint],
            metadataByPath: [path: fingerprint]
        )

        let result = try await makeService(fileSystem: fileSystem).deleteSelectedAudio(
            candidates: [
                UnreferencedAudioCandidate(
                    id: path,
                    path: path,
                    fileName: "not-audio.caf",
                    byteCount: fingerprint.byteCount,
                    fingerprint: fingerprint
                )
            ],
            selectedIDs: [path]
        )

        XCTAssertEqual(result.deletedAudioCount, 0)
        XCTAssertEqual(result.skipped.first?.reason, .outsideScope)
    }

    func testDeletionSkipsASelectedSupportedFileNotInTheCurrentScanSnapshot() async throws {
        let fingerprint = fixtureFingerprint(named: "new-after-scan.m4a", byteCount: 17, identifier: 17)
        let fileSystem = ControlledFileSystem(
            listedFiles: [],
            metadataByPath: [fingerprint.path: fingerprint]
        )

        let result = try await makeService(fileSystem: fileSystem).deleteSelectedAudio(
            candidates: [
                UnreferencedAudioCandidate(
                    id: fingerprint.path,
                    path: fingerprint.path,
                    fileName: "new-after-scan.m4a",
                    byteCount: fingerprint.byteCount,
                    fingerprint: fingerprint
                )
            ],
            selectedIDs: [fingerprint.path]
        )

        XCTAssertEqual(result.deletedAudioCount, 0)
        XCTAssertEqual(result.skipped.first?.reason, .changedOrReplaced)
    }

    func testDeletionSkipsAPathOutsideDocumentsEvenWhenExplicitlySelected() async throws {
        let outsideURL = documentsURL.deletingLastPathComponent().appendingPathComponent("outside.m4a")
        let fingerprint = fixtureFingerprint(named: "outside.m4a", byteCount: 18, identifier: 18)
        let outsideFingerprint = AudioFileFingerprint(
            path: canonicalPath(outsideURL),
            byteCount: fingerprint.byteCount,
            modificationDate: fingerprint.modificationDate,
            fileIdentifier: fingerprint.fileIdentifier
        )
        let fileSystem = ControlledFileSystem(
            listedFiles: [outsideFingerprint],
            metadataByPath: [outsideFingerprint.path: outsideFingerprint]
        )

        let result = try await makeService(fileSystem: fileSystem).deleteSelectedAudio(
            candidates: [
                UnreferencedAudioCandidate(
                    id: outsideFingerprint.path,
                    path: outsideFingerprint.path,
                    fileName: outsideURL.lastPathComponent,
                    byteCount: outsideFingerprint.byteCount,
                    fingerprint: outsideFingerprint
                )
            ],
            selectedIDs: [outsideFingerprint.path]
        )

        XCTAssertEqual(result.deletedAudioCount, 0)
        XCTAssertEqual(result.skipped.first?.reason, .outsideScope)
    }

    func testActiveProcessingJobProtectsItsAudioFromScanAndDeletion() async throws {
        let audio = try writeFile(named: "queued.m4a", byteCount: 16)
        let job = ProcessingJobEntry(context: coreDataManager.managedObjectContext)
        job.id = UUID()
        job.recordingURL = audio.path
        job.status = "Queued"
        job.recordingName = "Queued"
        job.jobType = "Transcription"
        try coreDataManager.managedObjectContext.save()

        let result = try await makeService().scanUnreferencedAudio()

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.protectedFileCount, 1)
        XCTAssertNil(result.deletionUnavailableReason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testActiveImportBlocksDeletionBeforeAnyDirectoryMutation() async throws {
        let orphan = try writeFile(named: "active-import.m4a", byteCount: 18)
        let service = makeService()
        let scan = try await service.scanUnreferencedAudio()
        let candidate = try XCTUnwrap(scan.candidates.first)
        let orphanPath = canonicalPath(orphan)

        let result = try await service.deleteSelectedAudio(
            candidates: scan.candidates,
            selectedIDs: [candidate.id],
            activityProvider: {
                AdvancedTroubleshootingActivitySnapshot(
                    blockAllDeletion: true,
                    reason: "An import is active.",
                    ownedPaths: [orphanPath],
                    kind: .importing
                )
            }
        )

        XCTAssertEqual(result.deletedAudioCount, 0)
        XCTAssertEqual(result.skipped.first?.reason, .activeImport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testDeletionSkipsAFileWhenProcessingBecomesActiveAfterScan() async throws {
        let orphan = try writeFile(named: "processing-started.m4a", byteCount: 18)
        let service = makeService()
        let scan = try await service.scanUnreferencedAudio()
        let candidate = try XCTUnwrap(scan.candidates.first)
        var activityCalls = 0

        let result = try await service.deleteSelectedAudio(
            candidates: scan.candidates,
            selectedIDs: [candidate.id],
            activityProvider: {
                activityCalls += 1
                guard activityCalls >= 2 else { return .idle }
                return AdvancedTroubleshootingActivitySnapshot(
                    blockAllDeletion: true,
                    reason: "Background audio processing is active.",
                    ownedPaths: [candidate.path],
                    kind: .processing
                )
            }
        )

        XCTAssertEqual(result.deletedAudioCount, 0)
        XCTAssertEqual(result.skipped.first?.reason, .activeProcessingJob)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testDirectoryFailurePreventsDeletion() async throws {
        let orphan = try writeFile(named: "directory-failure.m4a", byteCount: 19)
        let fingerprint = AudioFileFingerprint(
            path: canonicalPath(orphan),
            byteCount: 19,
            modificationDate: Date(timeIntervalSince1970: 1),
            fileIdentifier: 1
        )
        let fileSystem = ControlledFileSystem(
            listedFiles: [],
            metadataByPath: [:],
            directoryFails: true
        )

        do {
            _ = try await makeService(fileSystem: fileSystem).deleteSelectedAudio(
                candidates: [
                    UnreferencedAudioCandidate(
                        id: fingerprint.path,
                        path: fingerprint.path,
                        fileName: orphan.lastPathComponent,
                        byteCount: fingerprint.byteCount,
                        fingerprint: fingerprint
                    )
                ],
                selectedIDs: [fingerprint.path]
            )
            XCTFail("A directory read failure must stop deletion.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No audio was deleted"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testPartialDeleteFailureReportsBothSuccessAndFailure() async throws {
        let first = fixtureFingerprint(named: "first.m4a", byteCount: 21, identifier: 21)
        let second = fixtureFingerprint(named: "second.m4a", byteCount: 22, identifier: 22)
        let fileSystem = ControlledFileSystem(
            listedFiles: [first, second],
            metadataByPath: [first.path: first, second.path: second],
            deletionFailures: [first.path]
        )

        let service = makeService(fileSystem: fileSystem)
        let scan = try await service.scanUnreferencedAudio()
        let result = try await service.deleteSelectedAudio(
            candidates: scan.candidates,
            selectedIDs: Set(scan.candidates.map(\.id))
        )

        XCTAssertEqual(result.requestedCount, 2)
        XCTAssertEqual(result.deletedAudioCount, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.path, first.path)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testReportFlagsARecordingWhoseColumnAndRelationshipNameDifferentRows() async throws {
        let context = coreDataManager.managedObjectContext
        let columnSummaryID = UUID()
        let recording = insertRecording(name: "Conflicting summary", summaryID: columnSummaryID)

        // Both summaries exist, so each side looks individually valid: only
        // comparing the column against the relationship reveals the conflict.
        insertSummary(id: columnSummaryID, recording: recording)
        let relationshipSummary = insertSummary(id: UUID(), recording: recording)
        recording.summary = relationshipSummary
        try context.save()

        let report = try await makeService().makeLocalDataReport()

        XCTAssertTrue(
            report.issues.contains { issue in
                issue.category == .relationship
                    && issue.message.contains("conflicting summary identities")
            },
            report.issues.map(\.message).joined(separator: "\n")
        )
    }

    func testSidecarsSharedWithAnotherAudioFileSurviveTheDelete() async throws {
        let orphan = try writeFile(named: "interview_2026-09-07_14-30-00.m4a", byteCount: 23)
        let sibling = try writeFile(named: "interview_2026-09-07_14-30-00.wav", byteCount: 24)
        let sharedLocation = documentsURL.appendingPathComponent("interview_2026-09-07_14-30-00.location")
        let sharedMeta = documentsURL.appendingPathComponent("interview_2026-09-07_14-30-00.recordingmeta")
        try Data(repeating: 0x03, count: 5).write(to: sharedLocation)
        try Data(repeating: 0x04, count: 6).write(to: sharedMeta)

        _ = insertRecording(name: "Kept sibling", url: sibling)
        try coreDataManager.managedObjectContext.save()

        let service = makeService()
        let scan = try await service.scanUnreferencedAudio()
        let candidate = try XCTUnwrap(scan.candidates.first { $0.path == canonicalPath(orphan) })

        let result = try await service.deleteSelectedAudio(
            candidates: scan.candidates,
            selectedIDs: [candidate.id]
        )

        XCTAssertEqual(result.deletedAudioCount, 1)
        XCTAssertEqual(result.deletedSidecarCount, 0)
        XCTAssertEqual(result.skipped.first?.reason, .sidecarShared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedLocation.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedMeta.path))
    }

    func testCancellingTheReportStopsTheDetachedWork() async throws {
        _ = insertRecording(
            name: "Any recording",
            url: documentsURL.appendingPathComponent("any.m4a")
        )
        try coreDataManager.managedObjectContext.save()

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let service = makeService(
            fileSystem: ControlledFileSystem(onDirectoryRead: {
                started.signal()
                release.wait()
            })
        )

        let task = Task { try await service.makeLocalDataReport() }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                started.wait()
                continuation.resume()
            }
        }
        task.cancel()
        release.signal()

        do {
            _ = try await task.value
            XCTFail("Cancelling the report must stop the work instead of returning a result.")
        } catch is CancellationError {
            // Expected: the detached work observes the caller's cancellation.
        }
    }

    private func makeService(
        fileSystem: any AdvancedTroubleshootingFileSystem = LocalAdvancedTroubleshootingFileSystem(),
        databaseReader: (any AdvancedTroubleshootingDatabaseReader)? = nil
    ) -> AdvancedTroubleshootingService {
        AdvancedTroubleshootingService(
            coreDataManager: coreDataManager,
            fileSystem: fileSystem,
            documentsURL: documentsURL,
            databaseReader: databaseReader
        )
    }

    @discardableResult
    private func insertRecording(
        name: String,
        url: URL? = nil,
        audioQuality: String? = nil,
        archived: Bool = false,
        transcriptID: UUID? = nil,
        summaryID: UUID? = nil
    ) -> RecordingEntry {
        let recording = RecordingEntry(context: coreDataManager.managedObjectContext)
        recording.id = UUID()
        recording.recordingName = name
        recording.recordingURL = url?.path
        recording.audioQuality = audioQuality
        recording.isArchived = archived
        recording.transcriptId = transcriptID
        recording.summaryId = summaryID
        recording.recordingDate = Date()
        recording.createdAt = Date()
        return recording
    }

    @discardableResult
    private func insertSummary(id: UUID, recording: RecordingEntry) -> SummaryEntry {
        let summary = SummaryEntry(context: coreDataManager.managedObjectContext)
        summary.id = id
        summary.recording = recording
        summary.recordingId = recording.id
        summary.summary = "Fixture summary"
        summary.generatedAt = Date()
        return summary
    }

    private func writeFile(named name: String, byteCount: Int) throws -> URL {
        let url = documentsURL.appendingPathComponent(name)
        try Data(repeating: 0x01, count: byteCount).write(to: url)
        return url
    }

    private func fixtureFingerprint(
        named name: String,
        byteCount: Int64,
        identifier: UInt64
    ) -> AudioFileFingerprint {
        AudioFileFingerprint(
            path: canonicalPath(documentsURL.appendingPathComponent(name)),
            byteCount: byteCount,
            modificationDate: Date(timeIntervalSince1970: 1),
            fileIdentifier: identifier
        )
    }

    private func canonicalPath(_ url: URL) -> String {
        AdvancedTroubleshootingService.canonicalPath(for: url)
    }
}

/// Records what the fake file system has removed so a deleted file stops being
/// reported as present, the way a real one would.
private final class DeletedPathStore: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func insert(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        paths.insert(path)
    }

    func contains(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(path)
    }
}

private struct ControlledFileSystem: AdvancedTroubleshootingFileSystem, Sendable {
    enum Failure: Error, Sendable {
        case directory
        case metadata
        case deletion
    }

    var listedFiles: [AudioFileFingerprint] = []
    var metadataByPath: [String: AudioFileFingerprint] = [:]
    var directoryFails = false
    var metadataFailures: Set<String> = []
    var deletionFailures: Set<String> = []
    /// Runs at the start of every directory read, so a test can hold the
    /// detached work open long enough to cancel it.
    var onDirectoryRead: (@Sendable () -> Void)?

    private let deleted = DeletedPathStore()

    func regularFiles(
        in directory: URL,
        allowedExtensions: Set<String>
    ) throws -> [AudioFileFingerprint] {
        onDirectoryRead?()
        if directoryFails {
            throw Failure.directory
        }
        return listedFiles.filter {
            allowedExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
                && !deleted.contains($0.path)
        }
    }

    func metadata(for url: URL) throws -> AudioFileFingerprint {
        let path = AdvancedTroubleshootingService.canonicalPath(for: url)
        if metadataFailures.contains(path) {
            throw Failure.metadata
        }
        guard let fingerprint = metadataByPath[path], !deleted.contains(path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return fingerprint
    }

    func deleteFile(at url: URL) throws {
        let path = AdvancedTroubleshootingService.canonicalPath(for: url)
        if deletionFailures.contains(path) {
            throw Failure.deletion
        }
        deleted.insert(path)
    }
}

@MainActor
private final class FailingDatabaseReader: AdvancedTroubleshootingDatabaseReader {
    enum Failure: Error {
        case read
    }

    func fetchRecordingsForDiagnostics() throws -> [RecordingEntry] {
        throw Failure.read
    }

    func fetchTranscriptsForDiagnostics() throws -> [TranscriptEntry] {
        throw Failure.read
    }

    func fetchSummariesForDiagnostics() throws -> [SummaryEntry] {
        throw Failure.read
    }

    func fetchProcessingJobsForDiagnostics() throws -> [ProcessingJobEntry] {
        throw Failure.read
    }
}

// swiftlint:enable file_length
