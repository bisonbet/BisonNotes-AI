import XCTest
import AVFoundation
@testable import BisonNotes_AI

@MainActor
final class MediaOperationRecoveryTests: XCTestCase {
    func testPublicationRefusesToOverwriteAnExistingDestination() throws {
        let root = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(root) }

        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        let documentsDirectory = root.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        let store = MediaOperationRecoveryStore(
            recoveryDirectory: recoveryDirectory,
            documentsDirectory: documentsDirectory
        )
        let source = root.appendingPathComponent("source.m4a")
        let destination = documentsDirectory.appendingPathComponent("recording.m4a")
        try Data("new bytes".utf8).write(to: source)
        try Data("existing bytes".utf8).write(to: destination)

        let operation = try store.begin(
            kind: .audioImport,
            sourceName: source.lastPathComponent,
            destinationURL: destination,
            fileExtension: "m4a"
        )
        let staged = try store.stageCopy(from: source, for: operation)

        XCTAssertThrowsError(try store.publish(staged)) { error in
            guard case .destinationConflict(let conflictURL) = error as? MediaOperationRecoveryError else {
                return XCTFail("Expected a destination conflict, got \(error)")
            }
            XCTAssertEqual(conflictURL.standardizedFileURL, destination.standardizedFileURL)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagingURL.path))

        try store.abortBeforePublish(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: recoveryDirectory
                .appendingPathComponent("\(MediaOperationRecoveryStore.receiptFilePrefix)\(operation.receipt.operationID.uuidString).json")
                .path
        ))
    }

    func testOwnedPathRejectsSymlinkEscape() throws {
        let root = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(root) }

        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        let documentsDirectory = root.appendingPathComponent("documents", isDirectory: true)
        let outsideDirectory = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let escapedDirectory = documentsDirectory.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escapedDirectory, withDestinationURL: outsideDirectory)

        let store = MediaOperationRecoveryStore(
            recoveryDirectory: recoveryDirectory,
            documentsDirectory: documentsDirectory
        )

        XCTAssertThrowsError(try store.begin(
            kind: .audioImport,
            sourceName: "source.m4a",
            destinationURL: escapedDirectory.appendingPathComponent("recording.m4a"),
            fileExtension: "m4a"
        )) { error in
            guard case .invalidPath = error as? MediaOperationRecoveryError else {
                return XCTFail("Expected an escaped-path rejection, got \(error)")
            }
        }
    }

    func testStagedConflictCannotBeReconciledAsACommittedPublication() throws {
        let root = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(root) }

        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        let documentsDirectory = root.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        let store = MediaOperationRecoveryStore(
            recoveryDirectory: recoveryDirectory,
            documentsDirectory: documentsDirectory
        )
        let source = root.appendingPathComponent("source.m4a")
        let destination = documentsDirectory.appendingPathComponent("recording.m4a")
        try Data("new bytes".utf8).write(to: source)
        try Data("unrelated bytes".utf8).write(to: destination)

        let prepared = try store.begin(
            kind: .audioImport,
            sourceName: source.lastPathComponent,
            destinationURL: destination,
            fileExtension: "m4a"
        )
        _ = try store.stageCopy(from: source, for: prepared)

        var referenceCheckCalled = false
        let result = store.reconcile(isPublishedArtifactReferenced: { _ in
            referenceCheckCalled = true
            return true
        })

        XCTAssertEqual(result.retainedCount, 1)
        XCTAssertEqual(result.committedCount, 0)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertFalse(referenceCheckCalled)
        XCTAssertEqual(try Data(contentsOf: destination), Data("unrelated bytes".utf8))
    }

    func testReopenedStoreRetainsPublishedArtifactUntilReferenceIsVerified() throws {
        let root = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(root) }

        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        let documentsDirectory = root.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        let store = MediaOperationRecoveryStore(
            recoveryDirectory: recoveryDirectory,
            documentsDirectory: documentsDirectory
        )
        let source = root.appendingPathComponent("source.m4a")
        let destination = documentsDirectory.appendingPathComponent("recording.m4a")
        try Data("published bytes".utf8).write(to: source)

        var operation = try store.begin(
            kind: .audioImport,
            sourceName: source.lastPathComponent,
            destinationURL: destination,
            fileExtension: "m4a"
        )
        operation = try store.stageCopy(from: source, for: operation)
        operation = try store.publish(operation)
        operation = try store.markMetadataPending(operation)

        let reopened = MediaOperationRecoveryStore(
            recoveryDirectory: recoveryDirectory,
            documentsDirectory: documentsDirectory
        )
        let pending = reopened.reconcile(isPublishedArtifactReferenced: { _ in false })
        XCTAssertEqual(pending.retainedCount, 1)
        XCTAssertEqual(pending.committedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        let committed = reopened.reconcile(isPublishedArtifactReferenced: { _ in true })
        XCTAssertEqual(committed.committedCount, 1)
        XCTAssertEqual(committed.failedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: recoveryDirectory
                .appendingPathComponent("\(MediaOperationRecoveryStore.receiptFilePrefix)\(operation.receipt.operationID.uuidString).json")
                .path
        ))
    }

    func testChangedPublishedArtifactCannotBeReconciledAsCommitted() throws {
        let root = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(root) }

        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        let documentsDirectory = root.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        let store = MediaOperationRecoveryStore(
            recoveryDirectory: recoveryDirectory,
            documentsDirectory: documentsDirectory
        )
        let source = root.appendingPathComponent("source.m4a")
        let destination = documentsDirectory.appendingPathComponent("recording.m4a")
        try Data("original bytes".utf8).write(to: source)

        var operation = try store.begin(
            kind: .audioImport,
            sourceName: source.lastPathComponent,
            destinationURL: destination,
            fileExtension: "m4a"
        )
        operation = try store.stageCopy(from: source, for: operation)
        operation = try store.publish(operation)
        operation = try store.markMetadataPending(operation)
        try Data("changed bytes".utf8).write(to: destination)

        let result = store.reconcile(isPublishedArtifactReferenced: { _ in true })

        XCTAssertEqual(result.committedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryDirectory
                .appendingPathComponent("\(MediaOperationRecoveryStore.receiptFilePrefix)\(operation.receipt.operationID.uuidString).json")
                .path
        ))
        XCTAssertEqual(try Data(contentsOf: destination), Data("changed bytes".utf8))
    }

    func testCorruptReceiptRemainsUnresolvedAcrossReconciliation() throws {
        let root = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(root) }

        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        let documentsDirectory = root.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        let receiptURL = recoveryDirectory.appendingPathComponent(
            "\(MediaOperationRecoveryStore.receiptFilePrefix)\(UUID().uuidString).json"
        )
        try Data("{ not valid json".utf8).write(to: receiptURL)

        var referenceCheckCalled = false
        let result = MediaOperationRecoveryStore(
            recoveryDirectory: recoveryDirectory,
            documentsDirectory: documentsDirectory
        ).reconcile(isPublishedArtifactReferenced: { _ in
            referenceCheckCalled = true
            return true
        })

        XCTAssertEqual(result.failedCount, 1)
        XCTAssertFalse(referenceCheckCalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
    }

    func testShareTokenValidationDoesNotConsumeAuthorization() throws {
        let root = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(root) }

        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let token = UUID().uuidString
        try Data(token.utf8).write(
            to: ShareImportAuthorization.tokenFileURL(in: inbox),
            options: .atomic
        )
        let url = URL(string: "bisonnotes://share-import?token=\(token)")!

        XCTAssertTrue(ShareImportAuthorization.hasValidURLToken(from: url, in: inbox))
        XCTAssertTrue(ShareImportAuthorization.hasValidURLToken(from: url, in: inbox))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ShareImportAuthorization.tokenFileURL(in: inbox).path
        ))

        ShareImportAuthorization.removeToken(in: inbox)
        XCTAssertFalse(ShareImportAuthorization.hasPendingToken(in: inbox))
    }

    #if DEBUG
    func testAudioSaveFailureRetainsArtifactAndExplicitRetryReusesOperation() async throws {
        let root = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(root) }

        let prefix = "D-audio-\(UUID().uuidString)"
        let source = root.appendingPathComponent("\(prefix).wav")
        try makeAudioFixture(at: source)
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        defer { removeDocumentFiles(withPrefix: prefix, from: documents) }

        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        let store = MediaOperationRecoveryStore(
            recoveryDirectory: recoveryDirectory,
            documentsDirectory: documents
        )
        let persistence = PersistenceController(inMemory: true)
        let importer = FileImportManager(
            persistenceController: persistence,
            mediaRecoveryStore: store
        )

        let previousFailure = CoreDataManager.injectedSaveFailure
        let previousOperation = CoreDataManager.injectedSaveOperation
        defer {
            CoreDataManager.injectedSaveFailure = previousFailure
            CoreDataManager.injectedSaveOperation = previousOperation
        }
        CoreDataManager.injectedSaveFailure = PersistenceStoreFailure(domain: "DTest", code: 1)
        CoreDataManager.injectedSaveOperation = "imported recording creation"

        let failed = await importer.importAudioFiles(from: [source])
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(importer.importResults?.successful, 0)
        XCTAssertEqual(importer.importResults?.failed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let published = try FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(prefix) }
        XCTAssertEqual(published.count, 1)
        let receipts = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == MediaOperationRecoveryStore.receiptFileExtension }
        XCTAssertEqual(receipts.count, 1)

        CoreDataManager.injectedSaveFailure = nil
        CoreDataManager.injectedSaveOperation = nil
        let relaunchedImporter = FileImportManager(
            persistenceController: persistence,
            mediaRecoveryStore: store
        )
        let acknowledged = await relaunchedImporter.importAudioFiles(from: [source])

        XCTAssertEqual(acknowledged, [source])
        ImportSourceCleanup.removeAcknowledged(acknowledged, from: [source])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == MediaOperationRecoveryStore.receiptFileExtension }.isEmpty)
        XCTAssertEqual(
            try CoreDataManager(persistenceController: persistence).getAllRecordings().count,
            1
        )
    }

    func testTranscriptSaveFailureRetainsDummyAudioAcrossReconciliation() async throws {
        let root = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(root) }

        let prefix = "D-transcript-\(UUID().uuidString)"
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        defer { removeDocumentFiles(withPrefix: prefix, from: documents) }

        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        let store = MediaOperationRecoveryStore(
            recoveryDirectory: recoveryDirectory,
            documentsDirectory: documents
        )
        let persistence = PersistenceController(inMemory: true)
        let importer = TranscriptImportManager(
            persistenceController: persistence,
            mediaRecoveryStore: store
        )

        let previousFailure = CoreDataManager.injectedSaveFailure
        let previousOperation = CoreDataManager.injectedSaveOperation
        let text = "Retain this transcript"
        defer {
            CoreDataManager.injectedSaveFailure = previousFailure
            CoreDataManager.injectedSaveOperation = previousOperation
        }
        CoreDataManager.injectedSaveFailure = PersistenceStoreFailure(domain: "DTest", code: 2)
        CoreDataManager.injectedSaveOperation = "imported transcript creation"

        do {
            _ = try await importer.importTranscript(text: text, name: prefix)
            XCTFail("A failed transcript metadata save must throw")
        } catch {
            XCTAssertTrue(error is TranscriptImportError)
        }

        let dummyAudio = try FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(prefix) }
        XCTAssertEqual(dummyAudio.count, 1)
        let receipts = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == MediaOperationRecoveryStore.receiptFileExtension }
        XCTAssertEqual(receipts.count, 1)

        var receiptJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipts[0])) as? [String: Any])
        XCTAssertEqual(receiptJSON["recordingID"] as? String,
            try CoreDataManager(persistenceController: persistence).getAllRecordings().first?.id?.uuidString)
        // Simulate an older receipt interrupted after the recording save but
        // before its identity update. Retry must discover the existing row.
        receiptJSON.removeValue(forKey: "recordingID")
        try JSONSerialization.data(withJSONObject: receiptJSON).write(to: receipts[0], options: .atomic)

        let result = store.reconcile(isPublishedArtifactReferenced: { _ in false })
        XCTAssertEqual(result.retainedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dummyAudio[0].path))
        XCTAssertFalse(try CoreDataManager(persistenceController: persistence)
            .getAllRecordings().isEmpty)

        // Reopening the importer and explicitly retrying the same text must
        // reuse the retained recording/operation rather than create "(2)".
        CoreDataManager.injectedSaveFailure = nil
        CoreDataManager.injectedSaveOperation = nil
        let relaunchedImporter = TranscriptImportManager(
            persistenceController: persistence,
            mediaRecoveryStore: store
        )
        let recoveredID = try await relaunchedImporter.importTranscript(text: text, name: prefix)
        let reopenedManager = CoreDataManager(persistenceController: persistence)
        XCTAssertEqual(try reopenedManager.getAllRecordings().count, 1)
        XCTAssertNotNil(try reopenedManager.fetchTranscript(for: recoveredID))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == MediaOperationRecoveryStore.receiptFileExtension }.count, 1)
        // Termination before source acknowledgement must not lose deduplication,
        // even if startup reconciliation has already verified the metadata.
        _ = store.reconcile(isPublishedArtifactReferenced: { _ in true })
        let afterRelaunch = TranscriptImportManager(persistenceController: persistence, mediaRecoveryStore: store)
        let duplicateID = try await afterRelaunch.importTranscript(text: text, name: prefix)
        XCTAssertEqual(duplicateID, recoveredID)
        XCTAssertEqual(try reopenedManager.getAllRecordings().count, 1)
    }

    #if os(iOS)
    func testWatchFailureCanRetryAfterReceiverRecreationWithoutAutomaticReplay() throws {
        let root = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(root) }

        let source = root.appendingPathComponent("watch.wav")
        try makeAudioFixture(at: source)
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64
        )
        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let store = MediaOperationRecoveryStore(
            recoveryDirectory: recoveryDirectory,
            documentsDirectory: documents
        )

        let recordingID = UUID()
        let metadata: [String: Any] = [
            "recordingId": recordingID.uuidString,
            "filename": source.lastPathComponent,
            "duration": TimeInterval(1),
            "fileSize": size,
            "createdAt": Date().timeIntervalSince1970
        ]
        let previousProcessed = UserDefaults.standard.stringArray(
            forKey: "processedWatchRecordingIds"
        )
        defer {
            if let previousProcessed {
                UserDefaults.standard.set(previousProcessed, forKey: "processedWatchRecordingIds")
            } else {
                UserDefaults.standard.removeObject(forKey: "processedWatchRecordingIds")
            }
        }
        UserDefaults.standard.removeObject(forKey: "processedWatchRecordingIds")

        var artifactCount = 0
        var latestOperation: MediaOperation?
        let firstReceiver = WatchConnectivityManager(
            testing: true,
            mediaRecoveryStore: store
        )
        firstReceiver.onWatchSyncRecordingArtifactReceived = { operation, _ in
            artifactCount += 1
            latestOperation = operation
        }
        firstReceiver.receiveForTesting(fileURL: source, metadata: metadata)
        XCTAssertEqual(artifactCount, 1)
        let firstOperation = try XCTUnwrap(latestOperation)
        var published = try store.publish(firstOperation)
        published = try store.markMetadataPending(published)
        firstReceiver.confirmSyncComplete(recordingId: recordingID, success: false)

        var retryMetadata = metadata
        retryMetadata["filename"] = "renamed-after-retry.m4a"
        let secondReceiver = WatchConnectivityManager(
            testing: true,
            mediaRecoveryStore: store
        )
        secondReceiver.onWatchSyncRecordingArtifactReceived = { operation, _ in
            artifactCount += 1
            latestOperation = operation
        }
        secondReceiver.receiveForTesting(fileURL: source, metadata: retryMetadata)
        XCTAssertEqual(artifactCount, 2)
        XCTAssertNotNil(latestOperation)
        XCTAssertEqual(latestOperation?.receipt.operationID, published.receipt.operationID)

        if let latestOperation {
            let committed = try store.markMetadataCommitted(latestOperation, recordingID: recordingID)
            try store.finish(committed)
        }
        secondReceiver.confirmSyncComplete(recordingId: recordingID, success: true)

        let afterAcknowledgement = WatchConnectivityManager(
            testing: true,
            mediaRecoveryStore: store
        )
        afterAcknowledgement.onWatchSyncRecordingArtifactReceived = { _, _ in
            artifactCount += 1
        }
        afterAcknowledgement.receiveForTesting(fileURL: source, metadata: metadata)
        XCTAssertEqual(artifactCount, 2)
    }
    #endif
    #endif

    func testStagedAudioAndVideoRetryWithUnrelatedCorruptReceipt() async throws {
        for kind in [MediaOperationKind.audioImport, .videoImport] {
            let root = try TestHelpers.createTemporaryDirectory()
            defer { try? TestHelpers.cleanupTemporaryDirectory(root) }
            let prefix = "D-staged-\(UUID().uuidString)"
            let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            defer { removeDocumentFiles(withPrefix: prefix, from: documents) }
            let source = root.appendingPathComponent(prefix + (kind == .videoImport ? ".mov" : ".wav"))
            let fixture = root.appendingPathComponent("fixture.wav")
            try makeAudioFixture(at: fixture)
            try FileManager.default.copyItem(at: fixture, to: source)
            let store = MediaOperationRecoveryStore(
                recoveryDirectory: root.appendingPathComponent("recovery"), documentsDirectory: documents
            )
            let identity = try store.artifactIdentity(for: source)
            let operation = try store.begin(kind: kind, sourceName: source.lastPathComponent,
                destinationURL: documents.appendingPathComponent(prefix + ".wav"),
                sourceFileSize: identity.fileSize, sourceFingerprint: identity.fingerprint)
            _ = try store.stageCopy(from: source, for: operation)
            let corrupt = store.recoveryDirectory.appendingPathComponent("media-operation-\(UUID().uuidString).json")
            try Data("invalid receipt".utf8).write(to: corrupt)
            let persistence = PersistenceController(inMemory: true)
            let importer = FileImportManager(persistenceController: persistence, mediaRecoveryStore: store)
            let acknowledged = await importer.importAudioFiles(from: [source])
            XCTAssertEqual(acknowledged, [source])
            XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: operation.stagingURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: operation.publishedURL.path))
            XCTAssertEqual(try CoreDataManager(persistenceController: persistence).getAllRecordings().count, 1)
            if kind == .videoImport {
                let retry = await importer.importAudioFiles(from: [source])
                XCTAssertEqual(retry, [source])
                XCTAssertEqual(try CoreDataManager(persistenceController: persistence).getAllRecordings().count, 1)
            }
        }
    }

    private func makeAudioFixture(at url: URL) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)
        )
        buffer.frameLength = 16_000
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        try audio.write(from: buffer)
    }

    private func removeDocumentFiles(withPrefix prefix: String, from documents: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
