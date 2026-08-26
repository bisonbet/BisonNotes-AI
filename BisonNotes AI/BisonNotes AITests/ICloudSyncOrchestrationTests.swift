//
//  ICloudSyncOrchestrationTests.swift
//  BisonNotes AITests
//
//  End-to-end shape of a sync run: which phases happen, in what order, how many
//  times, and what a burst of triggers costs. The device log that motivated this
//  work showed a three-minute backup followed by a twenty-eight-second restore
//  enumeration, most of it the same records read over and over.
//

import CloudKit
import XCTest
@testable import BisonNotes_AI

@MainActor
final class ICloudSyncOrchestrationTests: XCTestCase {
    private var persistenceController: PersistenceController!
    private var appCoordinator: AppDataCoordinator!
    private var tempDirectory: URL!

    private var transport: FakeCloudKitTransport!
    private var clock: ManualCloudSyncClock!
    private var sleeper: RecordingCloudSyncSleeper!
    private var preferences: InMemoryCloudSyncPreferencesStore!
    private var metrics: RecordingCloudSyncMetricsSink!
    private var manager: iCloudStorageManager!

    private static let defaultsKeysToReset = [
        "iCloudBackupStateSignatureV1",
        "iCloudActiveManifestMigrationCompletedV2",
        "iCloudLastSuccessfulRoutineSyncV1",
        "iCloudQuarantinedBackupRecordNamesV2",
        "iCloudQuarantinedLegacySummaryRecordNamesV2",
        "lastSyncDate"
    ]

    override func setUp() async throws {
        for key in Self.defaultsKeysToReset {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // The one-time compatibility scan is covered by its own test; the rest of
        // these assert on the routine path.
        UserDefaults.standard.set(true, forKey: "iCloudActiveManifestMigrationCompletedV2")
        // Set before the manager is built: assigning `isEnabled` afterwards would
        // kick off the real CloudKit enable path.
        UserDefaults.standard.set(true, forKey: "iCloudSyncEnabled")

        persistenceController = PersistenceController(inMemory: true)
        appCoordinator = AppDataCoordinator(persistenceController: persistenceController)
        tempDirectory = try TestHelpers.createTemporaryDirectory()

        transport = FakeCloudKitTransport()
        clock = ManualCloudSyncClock()
        sleeper = RecordingCloudSyncSleeper(clock: clock)
        preferences = InMemoryCloudSyncPreferencesStore()
        metrics = RecordingCloudSyncMetricsSink()
        manager = iCloudStorageManager(
            transport: transport,
            clock: clock,
            sleeper: sleeper,
            preferences: preferences,
            metricsSink: metrics
        )
        manager.networkStatus = .available
        manager.clearPendingCloudMutationsForTesting()
    }

    override func tearDown() async throws {
        manager?.clearPendingCloudMutationsForTesting()
        // A retry armed by a deferred run holds the coordinator until it fires.
        manager?.cancelDeferredSyncRetry()
        manager = nil
        metrics = nil
        preferences = nil
        sleeper = nil
        clock = nil
        transport = nil
        if let tempDirectory {
            try? TestHelpers.cleanupTemporaryDirectory(tempDirectory)
        }
        tempDirectory = nil
        appCoordinator = nil
        persistenceController = nil
        for key in Self.defaultsKeysToReset {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: "iCloudSyncEnabled")
    }

    // MARK: - Fixtures

    @discardableResult
    private func createCompleteRecording(named name: String) throws -> UUID {
        let audioURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        let recordingId = appCoordinator.addRecording(
            url: audioURL,
            name: name,
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )
        let transcriptId = try XCTUnwrap(appCoordinator.addTranscript(
            for: recordingId,
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "Transcript for \(name)", startTime: 0, endTime: 2)]
        ))
        _ = appCoordinator.addSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: "Summary for \(name) with enough content to satisfy validation rules and exercise backup selection.",
            aiModel: "fixture",
            originalLength: 60
        )
        return recordingId
    }

    private func runReconcile(reason: CloudSyncReason = .appLaunch) async throws -> CloudReconcileResult {
        try await manager.reconcileAllDataWithiCloud(appCoordinator: appCoordinator, reason: reason)
    }

    private var contentModifyIndexes: [Int] {
        transport.ledger.indices.filter { index in
            guard case .modify(let saving, let deleting) = transport.ledger[index] else { return false }
            return (saving + deleting).contains { $0.hasPrefix("backup_") }
        }
    }

    /// Yields until `condition` holds, giving other main-actor tasks a chance to
    /// run. Bounded so a broken expectation fails the test instead of hanging it.
    @discardableResult
    private func waitUntil(
        _ description: String,
        iterations: Int = 500,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<iterations {
            if condition() { return true }
            await Task.yield()
        }
        XCTFail("Timed out waiting for: \(description)")
        return false
    }

    /// The coordinator's contract is that every request is *covered* — by its own
    /// run, or by one whose intent subsumes it. Which waiter happens to execute a
    /// queued closure is not part of it: either one may drain the queue.
    private func assertOutcomeCovers(
        _ outcome: CloudSyncRunOutcome,
        _ intent: CloudSyncIntent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch outcome {
        case .completed:
            break
        case .joinedRunningOperation(let covering), .coalescedIntoFollowUp(let covering):
            XCTAssertTrue(
                covering.subsumes(intent),
                "\(covering) does not cover \(intent), so this caller was told work happened that did not",
                file: file,
                line: line
            )
        case .deferred:
            XCTFail("Expected \(intent) to run, not to be deferred", file: file, line: line)
        }
    }

    // MARK: - Phase barrier

    /// Seeds a manifest this build trusts, so a run is the steady-state one rather
    /// than a first-contact run that legitimately adds a discovery scan.
    private func seedTrustedManifest() {
        transport.seed([
            CloudKitTestRecords.record(
                type: "CD_BackupContentIndex",
                name: "content_index",
                fields: [
                    "recordingRecordNames": [] as NSArray,
                    "transcriptRecordNames": [] as NSArray,
                    "summaryRecordNames": [] as NSArray,
                    "manifestSchemaVersion": 2
                ]
            )
        ])
    }

    func testReconcileRunsThePhaseBarrierInOrder() async throws {
        try createCompleteRecording(named: "Phase order")
        seedTrustedManifest()

        _ = try await runReconcile()

        let report = try XCTUnwrap(metrics.lastReport)
        XCTAssertEqual(
            report.phaseOrder,
            [
                .flushOutboundTombstones,
                .applyInboundTombstones,
                .fetchCloudSnapshot,
                .resolveWinners,
                .writeContent,
                .commitManifest,
                // The restore leg reuses the backup leg's snapshot, so it applies
                // cloud winners without reading the same records a second time.
                .applyCloudWinners,
                .pruneDuplicates
            ]
        )
        XCTAssertEqual(report.intent, .routineSnapshot)
        XCTAssertEqual(report.reason, .appLaunch)
    }

    func testDeletionMarkersAreAppliedExactlyOncePerRun() async throws {
        try createCompleteRecording(named: "Tombstones once")
        seedTrustedManifest()

        _ = try await runReconcile()

        let report = try XCTUnwrap(metrics.lastReport)
        XCTAssertEqual(
            report.phaseOrder.filter { $0 == .flushOutboundTombstones }.count,
            1,
            "Backup and restore share one tombstone pass; doing it per leg is what made a reconcile pay for it four times"
        )
        XCTAssertEqual(report.phaseOrder.filter { $0 == .applyInboundTombstones }.count, 1)

        // …and no leg goes looking for tombstones again once the run has started writing.
        let firstWrite = try XCTUnwrap(contentModifyIndexes.first)
        let laterDeletionQueries = transport.ledger[firstWrite...].filter {
            if case .query(let recordType) = $0 { return recordType == "CD_BackupDeletion" }
            return false
        }
        XCTAssertTrue(laterDeletionQueries.isEmpty)
    }

    func testTheDatasetIsReadInTwoBatchesAndWrittenOnce() async throws {
        for index in 0..<3 {
            try createCompleteRecording(named: "Recording \(index)")
        }
        seedTrustedManifest()

        _ = try await runReconcile()

        // One batch for recordings (without their audio assets) and one for
        // transcripts and summaries together.
        let contentFetches = transport.ledger.filter { operation in
            guard case .fetch(let names, _) = operation else { return false }
            return names.contains { $0.hasPrefix("backup_") }
        }
        XCTAssertEqual(contentFetches.count, 2, "Known ids are read in batches, never one record at a time")
        XCTAssertEqual(contentModifyIndexes.count, 1, "Nine records go out in a single modify")
    }

    func testRecordingsAreReadWithoutTheirAudioAssets() async throws {
        try createCompleteRecording(named: "No asset download")

        _ = try await runReconcile()

        let recordingFetch = transport.ledger.first { operation in
            guard case .fetch(let names, _) = operation else { return false }
            return names.contains { $0.hasPrefix("backup_recording_") }
        }
        guard case .fetch(_, let desiredKeys) = try XCTUnwrap(recordingFetch) else {
            return XCTFail("Expected a recording fetch")
        }
        let keys = try XCTUnwrap(desiredKeys)
        XCTAssertFalse(keys.contains("audioAsset"), "Metadata sync must not download every backed-up audio file")
        XCTAssertTrue(keys.contains("audioSignature"), "…but it still needs to know whether the audio changed")
    }

    func testNothingIsReadBackAfterTheContentWrite() async throws {
        try createCompleteRecording(named: "No post-write reread")

        _ = try await runReconcile()

        let lastContentWrite = try XCTUnwrap(contentModifyIndexes.last)
        let contentReadsAfterWrite = transport.ledger[lastContentWrite...].filter { operation in
            guard case .fetch(let names, _) = operation else { return false }
            return names.contains { $0.hasPrefix("backup_") }
        }
        XCTAssertTrue(
            contentReadsAfterWrite.isEmpty,
            "Counts for the log come from the snapshot and the operation results, not from re-reading the cloud"
        )
    }

    func testASecondRunWithNoChangesWritesNothing() async throws {
        try createCompleteRecording(named: "Idempotent")
        _ = try await runReconcile()
        transport.clearLedger()

        let result = try await runReconcile(reason: .appBecameActive)

        XCTAssertTrue(result.backupResult.wasSkippedNoChanges)
        XCTAssertTrue(contentModifyIndexes.isEmpty, "An unchanged device must not write a single record")
    }

    func testTouchingARecordDoesNotMakeItDirtyForTheOtherDevice() async throws {
        try createCompleteRecording(named: "Not dirty")
        _ = try await runReconcile()
        let recordingName = transport.storage.keys.first { $0.recordName.hasPrefix("backup_recording_") }
        let firstSyncStamp = transport.storage[try XCTUnwrap(recordingName)]?["syncUpdatedAt"] as? Date

        // Force the signature shortcut off so the leg really re-examines every record.
        UserDefaults.standard.removeObject(forKey: "iCloudBackupStateSignatureV1")
        clock.advance(60)
        _ = try await runReconcile(reason: .appBecameActive)

        let secondSyncStamp = transport.storage[try XCTUnwrap(recordingName)]?["syncUpdatedAt"] as? Date
        XCTAssertEqual(
            firstSyncStamp,
            secondSyncStamp,
            "Rewriting syncUpdatedAt on an unchanged record is what made two devices trade the same records forever"
        )
    }

    /// A manifest the backup leg wrote in this same run lists only what this
    /// device already knew about. Trusting it for the restore leg's discovery
    /// decision hides every active cloud-only record, permanently: they are not in
    /// the new manifest, and the review scan ignores active records by design.
    func testAManifestCreatedThisRunDoesNotSuppressDiscovery() async throws {
        try createCompleteRecording(named: "Local content")

        // Another device's record, in the cloud but named by no manifest.
        let cloudOnlyId = UUID()
        let now = Date()
        transport.seed([
            CloudKitTestRecords.record(
                type: "CD_BackupRecording",
                name: "backup_recording_\(cloudOnlyId.uuidString)",
                fields: [
                    "recordingName": "From another device",
                    "recordingDate": now,
                    "createdAt": now,
                    "lastModified": now,
                    "recordingURL": "elsewhere.m4a",
                    "duration": 30.0,
                    "syncLifecycle": "active",
                    "syncSchemaVersion": 2
                ]
            )
        ])

        _ = try await runReconcile()

        XCTAssertTrue(
            appCoordinator.coreDataManager.getAllRecordings().contains { $0.id == cloudOnlyId },
            "The run must discover this before trusting the manifest it just wrote"
        )
    }

    // MARK: - Trigger gate

    func testColdLaunchForcesARunAndTheFollowingActivationJoinsIt() async throws {
        try createCompleteRecording(named: "Cold launch")
        let gate = AsyncGate()
        transport.fetchGate = gate

        let launch = Task { @MainActor in
            try await self.manager.reconcileAllDataWithiCloud(
                appCoordinator: self.appCoordinator,
                reason: .appLaunch
            )
        }
        // Let the launch run reach CloudKit and block there.
        await waitUntil("the launch run to reach CloudKit") { self.transport.fetchOperationCount > 0 }

        let activation = Task { @MainActor in
            try await self.manager.reconcileAllDataWithiCloud(
                appCoordinator: self.appCoordinator,
                reason: .appBecameActive
            )
        }
        await Task.yield()
        gate.open()

        _ = try await launch.value
        let activationResult = try await activation.value

        XCTAssertTrue(
            activationResult.wasCoalescedIntoRunningSync,
            "The activation must report that it joined a run, not that it found nothing to do"
        )
        XCTAssertEqual(manager.operationCoordinator.completedRunCount, 1)
        XCTAssertEqual(metrics.reports.count, 1, "Launch plus activation is one sync, not two")
    }

    func testAnActivationWithNothingPendingDoesNotEarnARun() async throws {
        try createCompleteRecording(named: "Quiet activation")
        _ = try await runReconcile()

        XCTAssertFalse(
            manager.shouldStartRoutineSnapshot(force: false),
            "A quiet device that just synced has nothing to check"
        )
        XCTAssertTrue(manager.shouldStartRoutineSnapshot(force: true), "A cold launch still forces one pass")
    }

    func testAStaleCheckEarnsARunAgain() async throws {
        try createCompleteRecording(named: "Stale")
        _ = try await runReconcile()

        manager.lastSuccessfulRoutineSyncDate = Date().addingTimeInterval(-1_800)

        XCTAssertTrue(manager.shouldStartRoutineSnapshot(force: false))
    }

    func testAQueuedDeletionBypassesTheMaintenanceThrottle() async throws {
        let recordingId = try createCompleteRecording(named: "Deleted")
        _ = try await runReconcile()
        XCTAssertFalse(manager.shouldStartRoutineSnapshot(force: false))

        manager.enqueueRecordingDeletionForiCloud(
            recordingId: recordingId,
            transcriptIds: [],
            summaryIds: [],
            requestedAt: Date()
        )

        XCTAssertTrue(
            manager.shouldStartRoutineSnapshot(force: false),
            "A deletion the user made must never wait out a maintenance window"
        )
        XCTAssertEqual(manager.pendingCloudDeletionCount, 1)
    }

    func testABackoffStopsRoutineTriggersFromStartingWork() async throws {
        try createCompleteRecording(named: "Throttled")
        transport.fetchFailures = [CloudKitTestError.ckError(.requestRateLimited, retryAfter: 600)]

        _ = try await runReconcile()
        transport.clearLedger()

        XCTAssertTrue(manager.cloudExecutor.isDeferred)
        XCTAssertFalse(manager.shouldStartRoutineSnapshot(force: false))

        let result = try await runReconcile(reason: .appBecameActive)
        XCTAssertNotNil(result.wasDeferredUntil, "A deferred sync must say so rather than look like a clean empty run")
        XCTAssertTrue(transport.ledger.isEmpty, "Not one request may be sent during a server-requested backoff")
    }

    /// A mid-run deferral is the dangerous case: the run has already started, so
    /// the entry-point backoff check cannot catch it. If deferred records fall
    /// through as "absent", the run looks like a successful sync of an empty cloud.
    func testADeferralPartWayThroughARunDoesNotLookLikeASuccessfulSync() async throws {
        try createCompleteRecording(named: "Deferred mid-run")
        // The manifest read succeeds; the content snapshot is thrown back at us.
        transport.fetchFailures = [
            nil,
            CloudKitTestError.ckError(.requestRateLimited, retryAfter: 900)
        ]

        let result = try await runReconcile()

        XCTAssertNotNil(result.wasDeferredUntil, "A run that never reached CloudKit must report itself as deferred")
        XCTAssertNil(
            UserDefaults.standard.string(forKey: "iCloudBackupStateSignatureV1"),
            "Deferred work is not uploaded work; the signature must not claim otherwise"
        )
        XCTAssertNil(manager.lastSuccessfulRoutineSyncDate, "A deferred run must not buy itself a quiet maintenance window")
        XCTAssertEqual(metrics.lastReport?.result, .deferred)
        XCTAssertTrue(contentModifyIndexes.isEmpty)
    }

    /// A deferral is reported as work that resumes by itself. In the default
    /// `.changesOnly` mode nothing else makes that true: the periodic timer runs no
    /// routine reconcile, so a foregrounded app with no further edit, activation or
    /// network transition would never come back for the work.
    func testADeferredRunArmsItsOwnRetry() async throws {
        try createCompleteRecording(named: "Deferred, then owed")
        transport.fetchFailures = [CloudKitTestError.ckError(.requestRateLimited, retryAfter: 600)]

        let result = try await runReconcile()
        let deferredUntil = try XCTUnwrap(result.wasDeferredUntil)
        let armed = try XCTUnwrap(
            manager.deferredSyncRetryTarget,
            "A deferred run must schedule its own return; nothing else will"
        )
        XCTAssertEqual(armed.timeIntervalSince1970, deferredUntil.timeIntervalSince1970, accuracy: 1)

        // A second deferral must not keep pushing the retry further out.
        transport.fetchFailures = [CloudKitTestError.ckError(.requestRateLimited, retryAfter: 3600)]
        _ = try await runReconcile(reason: .appBecameActive)
        let stillArmed = try XCTUnwrap(manager.deferredSyncRetryTarget)
        XCTAssertEqual(
            stillArmed.timeIntervalSince1970,
            armed.timeIntervalSince1970,
            accuracy: 1,
            "The earliest outstanding retry stands"
        )
    }

    /// The temporary directory can be full or momentarily unwritable. The metadata
    /// still goes, but the run has not done what it set out to do — and its
    /// signature already covers this file's unchanged contents, so stamping it
    /// would mean no later run ever came back for the audio.
    func testAudioThatCouldNotBeStagedLeavesTheBackupSignaturePending() async throws {
        let recordingId = try createCompleteRecording(named: "Unstageable audio")
        // A recording created outside the Documents directory is stored by filename
        // alone, so the audio has to be where the app would really look for it —
        // otherwise the run decides there is nothing to upload and proves nothing.
        let recording = try XCTUnwrap(appCoordinator.coreDataManager.getRecording(id: recordingId))
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let audioURL = documents.appendingPathComponent(try XCTUnwrap(recording.recordingURL))
        try TestHelpers.createMockAudioFile(at: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let staging = UnwritableAssetStaging()
        manager.setAssetStagingFactoryForTesting { _ in staging }

        _ = try await manager.backupAllDataToiCloud(
            appCoordinator: appCoordinator,
            options: CloudBackupOptions(
                includeAudioFiles: true,
                includeSettings: false,
                includeSensitiveSettings: false
            )
        )

        XCTAssertFalse(staging.attemptedSources.isEmpty, "The run has to have tried to upload the audio")
        XCTAssertNil(
            UserDefaults.standard.string(forKey: "iCloudBackupStateSignatureV1"),
            "Audio that never left the device must not be recorded as a complete backup"
        )
        XCTAssertNotNil(
            transport.record(named: "backup_recording_\(recordingId.uuidString)"),
            "…while the metadata still uploads: audio never blocks it"
        )
    }

    func testADeferredSaveLeavesTheUploadOutstanding() async throws {
        try createCompleteRecording(named: "Deferred save")
        transport.modifyFailures = [CloudKitTestError.ckError(.requestRateLimited, retryAfter: 900)]

        let result = try await runReconcile()

        XCTAssertNotNil(result.wasDeferredUntil)
        XCTAssertNil(
            UserDefaults.standard.string(forKey: "iCloudBackupStateSignatureV1"),
            "Records that never left the device must still look like pending work on the next activation"
        )
        XCTAssertFalse(manager.shouldStartRoutineSnapshot(force: false), "…but not until the backoff window has passed")

        clock.advance(901)
        XCTAssertTrue(
            manager.shouldStartRoutineSnapshot(force: false),
            "Once CloudKit is willing to talk again the outstanding upload must be retried"
        )
    }

    /// A conflict this device correctly loses still has to reach Core Data on the
    /// same pass — otherwise the winning remote edit waits for the next sync.
    func testAConflictLostToANewerServerRecordIsAppliedInTheSameRun() async throws {
        let recordingId = try createRecordingOnlyForConflict(named: "Local name")
        let recordName = "backup_recording_\(recordingId.uuidString)"
        let recordID = CKRecord.ID(recordName: recordName)

        // The cloud copy this run fetches looks older, so the backup leg decides to
        // upload…
        transport.seed([
            CloudKitTestRecords.record(
                type: "CD_BackupRecording",
                name: recordName,
                fields: [
                    "recordingName": "Stale cloud name",
                    "recordingDate": Date(),
                    "createdAt": Date(),
                    "lastModified": Date().addingTimeInterval(-3_600),
                    "syncLifecycle": "active",
                    "syncSchemaVersion": 2
                ]
            )
        ])

        // …but another device wrote a newer edit in between, and the save conflicts.
        let serverWinner = CloudKitTestRecords.record(
            type: "CD_BackupRecording",
            name: recordName,
            fields: [
                "recordingName": "Renamed on another device",
                "recordingDate": Date(),
                "createdAt": Date(),
                "lastModified": Date().addingTimeInterval(3_600),
                "syncLifecycle": "active",
                "syncSchemaVersion": 2
            ]
        )
        transport.perRecordSaveFailures[recordID] = [
            CloudKitTestError.ckError(.serverRecordChanged, serverRecord: serverWinner)
        ]

        _ = try await runReconcile()

        let recording = try XCTUnwrap(appCoordinator.coreDataManager.getRecording(id: recordingId))
        XCTAssertEqual(
            recording.recordingName,
            "Renamed on another device",
            "The server's winning edit must be applied on this pass, not carried as our stale local copy"
        )
    }

    @discardableResult
    private func createRecordingOnlyForConflict(named name: String) throws -> UUID {
        let audioURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        return appCoordinator.addRecording(
            url: audioURL,
            name: name,
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )
    }

    /// The refetch that pulls a recording's full record also pulls a fresh change
    /// tag. An edit that landed in between would therefore save cleanly over the
    /// top — no conflict to catch it — so the winner has to be decided again.
    func testANewerRemoteEditArrivingMidRunIsNotOverwritten() async throws {
        let recordingId = try createRecordingOnlyForConflict(named: "Local name")
        let recordName = "backup_recording_\(recordingId.uuidString)"
        let recordID = CKRecord.ID(recordName: recordName)

        // The snapshot sees an older cloud copy, so the local row wins…
        transport.seed([
            CloudKitTestRecords.record(
                type: "CD_BackupRecording",
                name: recordName,
                fields: [
                    "recordingName": "Stale cloud name",
                    "recordingDate": Date(),
                    "createdAt": Date(),
                    "lastModified": Date().addingTimeInterval(-3_600),
                    "syncLifecycle": "active",
                    "syncSchemaVersion": 2
                ]
            )
        ])

        // …and another device writes a newer edit before the full refetch.
        var fetchCount = 0
        transport.beforeFetch = { transport in
            fetchCount += 1
            guard fetchCount == 1 else { return }
            transport.seed([
                CloudKitTestRecords.record(
                    type: "CD_BackupRecording",
                    name: recordName,
                    fields: [
                        "recordingName": "Renamed on another device",
                        "recordingDate": Date(),
                        "createdAt": Date(),
                        "lastModified": Date().addingTimeInterval(3_600),
                        "syncLifecycle": "active",
                        "syncSchemaVersion": 2
                    ]
                )
            ])
        }

        _ = try await runReconcile()

        XCTAssertEqual(
            transport.record(named: recordName)?["recordingName"] as? String,
            "Renamed on another device",
            "A newer remote edit must survive a run that had already decided to upload"
        )
        let recording = try XCTUnwrap(appCoordinator.coreDataManager.getRecording(id: recordingId))
        XCTAssertEqual(recording.recordingName, "Renamed on another device", "…and it must reach this device on the same pass")
    }

    func testRecordsThatNeverSettleFailTheRunRatherThanBeingForgotten() async throws {
        let recordingId = try createRecordingOnlyForConflict(named: "Contended")
        let recordName = "backup_recording_\(recordingId.uuidString)"
        let recordID = CKRecord.ID(recordName: recordName)

        // Another device wins every rebase, always with a newer-looking record so
        // this device keeps trying rather than conceding.
        transport.perRecordSaveFailures[recordID] = (0..<5).map { _ in
            CloudKitTestError.ckError(
                .serverRecordChanged,
                serverRecord: CloudKitTestRecords.record(
                    type: "CD_BackupRecording",
                    name: recordName,
                    fields: ["lastModified": Date().addingTimeInterval(-3_600)]
                )
            )
        }

        do {
            _ = try await runReconcile()
            XCTFail("A record that never reached CloudKit must fail the run")
        } catch is CloudSyncUnsettledRecordsError {
            // Expected.
        }

        XCTAssertNil(
            UserDefaults.standard.string(forKey: "iCloudBackupStateSignatureV1"),
            "A matching signature would skip this unsent edit on every later run"
        )
        XCTAssertNil(manager.lastSuccessfulRoutineSyncDate)
    }

    func testAWaiterOnASharedRunSeesThatRunsFailure() async throws {
        let coordinator = CloudSyncOperationCoordinator()
        let gate = AsyncGate()
        struct SharedRunFailure: Error {}

        let first = Task { @MainActor in
            try await coordinator.submit(intent: .reviewScan) {
                await gate.wait()
            }
        }
        await waitUntil("the first run to start") { coordinator.isRunning }

        // Two equivalent manual backups queue together; one drains the shared entry.
        var outcomes: [Result<CloudSyncRunOutcome, any Error>] = []
        var waiters: [Task<Void, Never>] = []
        for _ in 0..<2 {
            waiters.append(
                Task { @MainActor in
                    do {
                        let outcome = try await coordinator.submit(
                            intent: .seedFromThisDevice,
                            allowJoiningRunningOperation: false
                        ) {
                            throw SharedRunFailure()
                        }
                        outcomes.append(.success(outcome))
                    } catch {
                        outcomes.append(.failure(error))
                    }
                }
            )
        }
        await waitUntil("both backups to queue as one job") { coordinator.pendingFollowUpCount == 1 }
        gate.open()

        _ = try await first.value
        for waiter in waiters {
            await waiter.value
        }

        XCTAssertEqual(outcomes.count, 2)
        for outcome in outcomes {
            if case .success(let value) = outcome {
                XCTFail("A waiter on a failed run must not report \(value)")
            }
        }
    }

    func testAThrottledQueryDoesNotEscalateIntoAZoneScan() async throws {
        try createCompleteRecording(named: "Throttled query")
        // The deletion-marker scan is the first query a run makes.
        transport.queryFailures = [CloudKitTestError.ckError(.requestRateLimited, retryAfter: 600)]

        let result = try await runReconcile()

        XCTAssertNotNil(result.wasDeferredUntil, "A throttled scan is deferred work, not an empty cloud")
        let zoneScans = transport.ledger.filter {
            if case .zoneChanges = $0 { return true }
            return false
        }
        XCTAssertTrue(
            zoneScans.isEmpty,
            "Escalating a throttled query into a zone scan is more traffic inside the window CloudKit asked us to sit out"
        )
        XCTAssertTrue(manager.cloudExecutor.isDeferred, "…and the gate has to close so nothing else goes out either")
    }

    func testTwoManualBackupsEachRunTheirOwnPass() async throws {
        // Both callers read a result out of their own closure, so neither may be
        // handed the other's run — a zero-valued result reads as a clean transfer.
        let coordinator = CloudSyncOperationCoordinator()
        let gate = AsyncGate()
        var runCount = 0

        let first = Task { @MainActor in
            try await coordinator.submit(intent: .reviewScan) { await gate.wait() }
        }
        await waitUntil("the first run to start") { coordinator.isRunning }

        var backups: [Task<CloudSyncRunOutcome, any Error>] = []
        for _ in 0..<2 {
            backups.append(
                Task { @MainActor in
                    try await coordinator.submit(
                        intent: .seedFromThisDevice,
                        allowJoiningRunningOperation: false,
                        coalescesWithEquivalentRequests: false
                    ) {
                        runCount += 1
                    }
                }
            )
        }
        await waitUntil("both backups to queue separately") { coordinator.pendingFollowUpCount == 2 }
        gate.open()

        _ = try await first.value
        for backup in backups {
            let outcome = try await backup.value
            assertOutcomeCovers(outcome, .seedFromThisDevice)
        }
        // The point of the fix: neither closure was discarded, so neither caller is
        // left holding the zero-valued result its own closure never filled in.
        XCTAssertEqual(runCount, 2, "Each result-bearing request runs its own closure")
    }

    func testOneQueuedJobFailingDoesNotStrandAnother() async throws {
        let coordinator = CloudSyncOperationCoordinator()
        let gate = AsyncGate()
        struct BackupFailure: Error {}
        var routineRan = false

        let first = Task { @MainActor in
            try await coordinator.submit(intent: .reviewScan) { await gate.wait() }
        }
        await waitUntil("the first run to start") { coordinator.isRunning }

        // A manual backup (higher priority) and a routine snapshot queue together.
        let backup = Task { @MainActor in
            try await coordinator.submit(
                intent: .seedFromThisDevice,
                allowJoiningRunningOperation: false,
                coalescesWithEquivalentRequests: false
            ) {
                throw BackupFailure()
            }
        }
        await waitUntil("the backup to queue") { coordinator.pendingFollowUpCount == 1 }
        let routine = Task { @MainActor in
            try await coordinator.submit(
                intent: .routineSnapshot,
                allowJoiningRunningOperation: false
            ) {
                routineRan = true
            }
        }
        await waitUntil("the routine snapshot to queue too") { coordinator.pendingFollowUpCount == 2 }
        gate.open()

        _ = try await first.value
        do {
            _ = try await backup.value
            XCTFail("The backup's own caller must see its failure")
        } catch is BackupFailure {
            // Expected.
        }
        _ = try await routine.value

        XCTAssertTrue(
            routineRan,
            "A failure in someone else's queued job must not leave this one with nobody to run it"
        )
    }

    /// A scan is the only way a cloud-only record is ever found; the
    /// manifest-driven path only looks up ids it already knows. So a page that
    /// dropped one record must not read as a complete dataset.
    func testAPartialQueryPageFailsTheScanRatherThanLookingComplete() async throws {
        let goodId = UUID()
        let badId = UUID()
        let now = Date()
        for (recordingId, name) in [(goodId, "Readable"), (badId, "Unreadable")] {
            transport.seed([
                CloudKitTestRecords.record(
                    type: "CD_BackupRecording",
                    name: "backup_recording_\(recordingId.uuidString)",
                    fields: [
                        "recordingName": name,
                        "recordingDate": now,
                        "createdAt": now,
                        "lastModified": now,
                        "recordingURL": "\(name).m4a",
                        "duration": 12.0,
                        "syncLifecycle": "active",
                        "syncSchemaVersion": 2
                    ]
                )
            ])
        }
        // CloudKit hands back one record and one failure in the same page.
        transport.queryRecordFailures["backup_recording_\(badId.uuidString)"] =
            CloudKitTestError.ckError(.internalError)

        do {
            _ = try await manager.restoreAllDataFromiCloud(
                appCoordinator: appCoordinator,
                includeAudioFiles: false,
                restoreSettings: false
            )
            XCTFail("A scan that could not read every record must not report success")
        } catch {
            // Expected.
        }

        XCTAssertFalse(
            appCoordinator.coreDataManager.getAllRecordings().contains { $0.id == goodId },
            "Half a dataset must not be committed as a finished restore"
        )
    }

    func testAReviewItemRestoreTakesItsTurnInTheCoordinator() async throws {
        let item = CloudReviewItem(
            id: UUID().uuidString,
            recordingId: UUID(),
            title: "Held for review",
            date: Date(),
            backupRecordNames: ["backup_recording_\(UUID().uuidString)"],
            legacySummaryRecordNames: [],
            hasRecording: true,
            hasAudio: false,
            hasTranscript: false,
            hasSummary: false,
            sourceDeviceIdentifier: nil
        )

        let gate = AsyncGate()
        let blocking = Task { @MainActor in
            try await self.manager.operationCoordinator.submit(intent: .erase) {
                await gate.wait()
            }
        }
        await waitUntil("the erase to take the coordinator") { self.manager.operationCoordinator.isRunning }
        transport.clearLedger()

        let restore = Task { @MainActor in
            try await self.manager.restoreCloudReviewItem(
                item,
                appCoordinator: self.appCoordinator,
                includeAudioFiles: false
            )
        }
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(
            transport.ledger.allSatisfy { if case .accountStatus = $0 { return true } else { return false } },
            "A review restore must not read or write while another operation holds the coordinator"
        )

        gate.open()
        _ = try await blocking.value
        _ = try? await restore.value
        XCTAssertFalse(manager.operationCoordinator.isRunning)
    }

    /// An upload queued before the user erased iCloud would put everything back
    /// the moment the erase finished.
    func testWorkQueuedBeforeAnEraseDoesNotRepopulateTheCloud() async throws {
        let coordinator = CloudSyncOperationCoordinator()
        let gate = AsyncGate()
        var uploadRan = false

        let erase = Task { @MainActor in
            try await coordinator.submit(
                intent: .erase,
                allowJoiningRunningOperation: false,
                coalescesWithEquivalentRequests: false
            ) {
                await gate.wait()
            }
        }
        await waitUntil("the erase to start") { coordinator.isRunning }

        let upload = Task { @MainActor in
            try await coordinator.submit(
                intent: .routineSnapshot,
                allowJoiningRunningOperation: false
            ) {
                uploadRan = true
            }
        }
        await waitUntil("the upload to queue behind it") { coordinator.hasPendingFollowUp }
        gate.open()

        _ = try await erase.value
        do {
            _ = try await upload.value
            XCTFail("A queued upload must not silently succeed after an erase")
        } catch is CloudSyncSupersededByEraseError {
            // Expected.
        }

        XCTAssertFalse(uploadRan, "Erasing iCloud and then immediately re-uploading is the one thing the user did not ask for")
    }

    func testAReadQueuedBeforeAnEraseStillRuns() async throws {
        let coordinator = CloudSyncOperationCoordinator()
        let gate = AsyncGate()
        var scanRan = false

        let erase = Task { @MainActor in
            try await coordinator.submit(
                intent: .erase,
                allowJoiningRunningOperation: false,
                coalescesWithEquivalentRequests: false
            ) {
                await gate.wait()
            }
        }
        await waitUntil("the erase to start") { coordinator.isRunning }

        let scan = Task { @MainActor in
            try await coordinator.submit(
                intent: .reviewScan,
                allowJoiningRunningOperation: false,
                coalescesWithEquivalentRequests: false
            ) {
                scanRan = true
            }
        }
        await waitUntil("the scan to queue behind it") { coordinator.hasPendingFollowUp }
        gate.open()

        _ = try await erase.value
        _ = try await scan.value

        XCTAssertTrue(scanRan, "Only work that writes to the cloud is cancelled by an erase")
    }

    /// A restore reads the cloud, but it does not only read it: a review restore
    /// reactivates its records and adds them to the manifest, and a full restore
    /// flushes queued deletion markers first. Queued behind an erase, either one
    /// repopulates the container the user has just emptied — after the erase has
    /// already told them it finished.
    func testARestoreQueuedBeforeAnEraseIsCancelledWithIt() async throws {
        let coordinator = CloudSyncOperationCoordinator()
        let gate = AsyncGate()
        var restoreRan = false

        let erase = Task { @MainActor in
            try await coordinator.submit(
                intent: .erase,
                allowJoiningRunningOperation: false,
                coalescesWithEquivalentRequests: false
            ) {
                await gate.wait()
            }
        }
        await waitUntil("the erase to start") { coordinator.isRunning }

        let restore = Task { @MainActor in
            try await coordinator.submit(
                intent: .restoreToThisDevice,
                allowJoiningRunningOperation: false,
                coalescesWithEquivalentRequests: false
            ) {
                restoreRan = true
            }
        }
        await waitUntil("the restore to queue behind it") { coordinator.hasPendingFollowUp }
        gate.open()

        _ = try await erase.value
        do {
            _ = try await restore.value
            XCTFail("A restore queued before an erase must not quietly repopulate the cloud")
        } catch is CloudSyncSupersededByEraseError {
            // Expected: the caller is told why, rather than left believing it ran.
        }

        XCTAssertFalse(restoreRan)
    }

    /// Without a trusted manifest the snapshot is only what this device already
    /// knew to ask for, so a device with local data of its own must still scan.
    func testAnUntrustedManifestStillDiscoversCloudOnlyRecords() async throws {
        try createCompleteRecording(named: "Local only here")

        let cloudOnlyId = UUID()
        let now = Date()
        transport.seed([
            CloudKitTestRecords.record(
                type: "CD_BackupRecording",
                name: "backup_recording_\(cloudOnlyId.uuidString)",
                fields: [
                    "recordingName": "From another device",
                    "recordingDate": now,
                    "createdAt": now,
                    "lastModified": now,
                    "recordingURL": "elsewhere.m4a",
                    "duration": 30.0,
                    "syncLifecycle": "active",
                    "syncSchemaVersion": 2
                ]
            ),
            // A manifest written by an older schema: present, but not to be trusted
            // as the list of everything that is up there.
            CloudKitTestRecords.record(
                type: "CD_BackupContentIndex",
                name: "content_index",
                fields: [
                    "recordingRecordNames": [] as NSArray,
                    "transcriptRecordNames": [] as NSArray,
                    "summaryRecordNames": [] as NSArray,
                    "manifestSchemaVersion": 1
                ]
            )
        ])

        _ = try await manager.restoreAllDataFromiCloud(
            appCoordinator: appCoordinator,
            includeAudioFiles: false,
            restoreSettings: false
        )

        XCTAssertTrue(
            appCoordinator.coreDataManager.getAllRecordings().contains { $0.id == cloudOnlyId },
            "An established device must keep discovering cloud-only records, not just a fresh install"
        )
    }

    /// The default zone does not implement `getChanges`, so the zone-change
    /// fallback can only ever fail there. An empty query result — a device with no
    /// deletion markers, say — must not be turned into a failed sync by it.
    func testTheDefaultZoneNotSupportingChangeEnumerationDoesNotFailTheSync() async throws {
        try createCompleteRecording(named: "No markers yet")
        transport.zoneEnumerationFailure = CloudKitTestError.defaultZoneGetChangesUnsupported()

        let result = try await runReconcile()

        XCTAssertFalse(result.backupResult.wasSkippedNoChanges)
        XCTAssertNil(result.wasDeferredUntil)
        XCTAssertGreaterThan(
            result.backupResult.recordingsBackedUp,
            0,
            "A zone that cannot enumerate changes means there is nothing more to look at, not that the backup failed"
        )
    }

    func testAnUnsupportedZoneChangeStillSurfacesTheQuerysOwnFailure() async throws {
        try createCompleteRecording(named: "Query broken")
        // The query itself fails for a real reason, and the fallback is unavailable.
        transport.queryFailures = [CloudKitTestError.ckError(.permissionFailure)]
        transport.zoneEnumerationFailure = CloudKitTestError.defaultZoneGetChangesUnsupported()

        do {
            _ = try await runReconcile()
            XCTFail("A genuine query failure must not be masked by the unavailable fallback")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .permissionFailure, "The original failure is the one worth reporting")
        }
    }

    /// A rename made straight through `CoreDataManager` sets no pending flag, so
    /// the flag cannot be the only signal that there is something to send.
    func testAnEditMadeOutsideTheAutoBackupPathStillEarnsASync() async throws {
        let recordingId = try createCompleteRecording(named: "Original name")
        _ = try await runReconcile()
        XCTAssertFalse(
            manager.shouldStartRoutineSnapshot(force: false, appCoordinator: appCoordinator),
            "nothing has changed yet"
        )

        try appCoordinator.coreDataManager.updateRecordingName(for: recordingId, newName: "Renamed")

        XCTAssertTrue(
            manager.shouldStartRoutineSnapshot(force: false, appCoordinator: appCoordinator),
            "A rename must not wait out the maintenance window just because it took a different code path"
        )
    }

    func testAnAudioFailureDoesNotStopTheMetadataUpload() async throws {
        try createCompleteRecording(named: "Bad audio")
        try createCompleteRecording(named: "Fine")

        // CloudKit refuses the audio for every recording in the batch.
        let recordingNames = appCoordinator.coreDataManager.getAllRecordings().compactMap { recording in
            recording.id.map { "backup_recording_\($0.uuidString)" }
        }
        for name in recordingNames {
            transport.perRecordSaveFailures[CKRecord.ID(recordName: name)] = [
                CloudKitTestError.ckError(.assetFileNotFound)
            ]
        }

        let result = try await runReconcile()

        XCTAssertEqual(
            result.backupResult.recordingsBackedUp,
            2,
            "Audio that CloudKit would not take must not fail the recordings' metadata"
        )
        for name in recordingNames {
            XCTAssertNotNil(transport.record(named: name), "the metadata still has to reach CloudKit")
        }
    }

    /// The audio retry the metadata fallback promises only happens if the run
    /// stops short of calling itself a complete backup.
    func testAnAudioFallbackLeavesTheBackupSignaturePending() async throws {
        try createCompleteRecording(named: "Audio refused")
        seedTrustedManifest()
        let recordingNames = appCoordinator.coreDataManager.getAllRecordings().compactMap { recording in
            recording.id.map { "backup_recording_\($0.uuidString)" }
        }
        for name in recordingNames {
            transport.perRecordSaveFailures[CKRecord.ID(recordName: name)] = [
                CloudKitTestError.ckError(.assetFileModified)
            ]
        }

        _ = try await runReconcile()

        XCTAssertNil(
            UserDefaults.standard.string(forKey: "iCloudBackupStateSignatureV1"),
            "Recording the signature here would let every later run skip the audio that never uploaded"
        )
        XCTAssertTrue(
            manager.shouldStartRoutineSnapshot(force: false, appCoordinator: appCoordinator),
            "…and the next activation has to pick the retry up"
        )
    }

    // MARK: - Failure handling

    func testAFailedRunAdvancesNeitherTheSignatureNorTheLastSuccessDate() async throws {
        try createCompleteRecording(named: "Doomed")
        transport.modifyFailures = [CloudKitTestError.ckError(.permissionFailure)]

        do {
            _ = try await runReconcile()
            XCTFail("A permission failure must surface, not be swallowed")
        } catch {
            // Expected.
        }

        XCTAssertNil(
            UserDefaults.standard.string(forKey: "iCloudBackupStateSignatureV1"),
            "A partial failure must not convince the next run that everything is already uploaded"
        )
        XCTAssertNil(manager.lastSuccessfulRoutineSyncDate)
        XCTAssertEqual(metrics.lastReport?.result, .failed)
    }

    // MARK: - Coordination primitives

    func testABurstOfTriggersProducesAtMostOneFollowUp() async throws {
        let coordinator = CloudSyncOperationCoordinator()
        let gate = AsyncGate()
        var runCount = 0

        let first = Task { @MainActor in
            try await coordinator.submit(intent: .routineSnapshot) {
                runCount += 1
                await gate.wait()
            }
        }
        await waitUntil("the first run to start") { coordinator.isRunning }

        var followers: [Task<CloudSyncRunOutcome, any Error>] = []
        for _ in 0..<5 {
            followers.append(
                Task { @MainActor in
                    try await coordinator.submit(
                        intent: .routineSnapshot,
                        allowJoiningRunningOperation: false
                    ) {
                        runCount += 1
                    }
                }
            )
        }
        await waitUntil("the burst to collapse into one follow-up") { coordinator.hasPendingFollowUp }
        gate.open()

        _ = try await first.value
        for follower in followers {
            _ = try await follower.value
        }

        XCTAssertEqual(runCount, 2, "Five triggers during one run collapse into a single follow-up")
        XCTAssertEqual(coordinator.completedRunCount, 2)
    }

    /// Priority decides which queued job goes first — never whether it happens.
    func testAQueuedJobIsNotDiscardedByAnEqualPriorityOne() async throws {
        let coordinator = CloudSyncOperationCoordinator()
        let gate = AsyncGate()
        var executedIntents: [CloudSyncIntent] = []

        let first = Task { @MainActor in
            try await coordinator.submit(intent: .reviewScan) {
                executedIntents.append(.reviewScan)
                await gate.wait()
            }
        }
        await waitUntil("the first run to start") { coordinator.isRunning }

        // A restore and an upload are both priority 3 but do entirely different
        // things; dropping either one loses work its caller believes was done.
        let restore = Task { @MainActor in
            try await coordinator.submit(
                intent: .restoreToThisDevice,
                allowJoiningRunningOperation: false
            ) {
                executedIntents.append(.restoreToThisDevice)
            }
        }
        await waitUntil("the restore to queue") { coordinator.pendingFollowUpCount == 1 }
        let seed = Task { @MainActor in
            try await coordinator.submit(
                intent: .seedFromThisDevice,
                allowJoiningRunningOperation: false
            ) {
                executedIntents.append(.seedFromThisDevice)
            }
        }
        await waitUntil("the upload to queue alongside it") { coordinator.pendingFollowUpCount == 2 }
        gate.open()

        _ = try await first.value
        let restoreOutcome = try await restore.value
        let seedOutcome = try await seed.value

        XCTAssertEqual(executedIntents.count, 3, "Neither queued job may be dropped")
        XCTAssertTrue(executedIntents.contains(.restoreToThisDevice))
        XCTAssertTrue(executedIntents.contains(.seedFromThisDevice))
        assertOutcomeCovers(restoreOutcome, .restoreToThisDevice)
        assertOutcomeCovers(seedOutcome, .seedFromThisDevice)
    }

    func testEquivalentQueuedRequestsStillCollapse() async throws {
        let coordinator = CloudSyncOperationCoordinator()
        let gate = AsyncGate()
        var runCount = 0

        let first = Task { @MainActor in
            try await coordinator.submit(intent: .seedFromThisDevice) {
                runCount += 1
                await gate.wait()
            }
        }
        await waitUntil("the first run to start") { coordinator.isRunning }

        var followers: [Task<CloudSyncRunOutcome, any Error>] = []
        for _ in 0..<4 {
            followers.append(
                Task { @MainActor in
                    try await coordinator.submit(
                        intent: .routineSnapshot,
                        allowJoiningRunningOperation: false
                    ) {
                        runCount += 1
                    }
                }
            )
        }
        await waitUntil("the burst to collapse into one job") { coordinator.pendingFollowUpCount == 1 }
        gate.open()

        _ = try await first.value
        for follower in followers {
            _ = try await follower.value
        }

        XCTAssertEqual(runCount, 2, "Four identical routine requests are still one follow-up")
    }

    /// A user's deletion is never dropped. It either gets its own run or is
    /// carried by one that flushes durable tombstones as its first phase.
    func testAnUrgentDeletionFlushIsAlwaysCarriedByARun() async throws {
        let coordinator = CloudSyncOperationCoordinator()
        let gate = AsyncGate()
        var executedIntents: [CloudSyncIntent] = []

        let first = Task { @MainActor in
            try await coordinator.submit(intent: .reviewScan) {
                executedIntents.append(.reviewScan)
                await gate.wait()
            }
        }
        await waitUntil("the review scan to start") { coordinator.isRunning }

        let routine = Task { @MainActor in
            try await coordinator.submit(
                intent: .routineSnapshot,
                allowJoiningRunningOperation: false
            ) {
                executedIntents.append(.routineSnapshot)
            }
        }
        await waitUntil("the routine snapshot to queue behind it") { coordinator.hasPendingFollowUp }
        let deletion = Task { @MainActor in
            try await coordinator.submit(
                intent: .deletionFlush,
                allowJoiningRunningOperation: false
            ) {
                executedIntents.append(.deletionFlush)
            }
        }
        await Task.yield()
        gate.open()

        _ = try await first.value
        _ = try await routine.value
        let deletionOutcome = try await deletion.value

        XCTAssertEqual(
            executedIntents,
            [.reviewScan, .routineSnapshot],
            "A routine pass flushes tombstones first, so it covers the queued deletion rather than displacing it"
        )
        assertOutcomeCovers(deletionOutcome, .deletionFlush)
    }

    /// A result-bearing request must not join a running operation either: joining
    /// skips its closure exactly as coalescing does, and it would return with its
    /// own result still empty.
    func testAResultBearingRequestDoesNotJoinARunningOperation() async throws {
        let coordinator = CloudSyncOperationCoordinator()
        let gate = AsyncGate()
        var runCount = 0

        let first = Task { @MainActor in
            try await coordinator.submit(
                intent: .reviewScan,
                coalescesWithEquivalentRequests: false
            ) {
                runCount += 1
                await gate.wait()
            }
        }
        await waitUntil("the first scan to start") { coordinator.isRunning }

        let second = Task { @MainActor in
            try await coordinator.submit(
                intent: .reviewScan,
                coalescesWithEquivalentRequests: false
            ) {
                runCount += 1
            }
        }
        await waitUntil("the second scan to queue rather than join") { coordinator.hasPendingFollowUp }
        gate.open()

        _ = try await first.value
        let outcome = try await second.value

        XCTAssertEqual(runCount, 2, "The second scan has to run its own closure to fill in its own results")
        XCTAssertNotEqual(outcome, .joinedRunningOperation(.reviewScan))
    }

    // MARK: - Inbound tombstones

    /// Markers for items this device has never seen — the state every device
    /// reached, because nothing ever removed an applied marker.
    @discardableResult
    private func seedDeletionMarkers(count: Int, deletedAt: Date?) -> [String] {
        let names = (0..<count).map { _ in "backup_deletion_\(UUID().uuidString)" }
        transport.seed(
            names.map { name in
                var fields: [String: any CKRecordValueProtocol] = [
                    "recordingId": String(name.dropFirst("backup_deletion_".count)),
                    "deviceIdentifier": "another-device"
                ]
                if let deletedAt {
                    fields["deletedAt"] = deletedAt
                }
                return CloudKitTestRecords.record(type: "CD_BackupDeletion", name: name, fields: fields)
            }
        )
        return names
    }

    func testTombstonesDoNotMakeARunReadTheDatasetAgainForEachOne() async throws {
        for index in 0..<3 {
            try createCompleteRecording(named: "Live \(index)")
        }
        seedTrustedManifest()
        // A first pass puts this device's content, and a manifest naming it, in the cloud.
        _ = try await runReconcile()

        seedDeletionMarkers(count: 12, deletedAt: clock.now.addingTimeInterval(-60))
        let namesReadBefore = transport.fetchedRecordNames.count
        let operationsBefore = transport.ledger.count

        _ = try await runReconcile(reason: .appBecameActive)

        let namesReadThisRun = Array(transport.fetchedRecordNames.dropFirst(namesReadBefore))
        let readsPerRecord = Dictionary(grouping: namesReadThisRun, by: { $0 }).mapValues(\.count)

        // Content records: the deletion workspace reads the dataset once, and the
        // backup leg's snapshot reads it once. Twelve markers must not mean twelve
        // more — that is what fetched ten thousand records for a hundred and fifty
        // live ones and put six minutes into one phase.
        let mostReadContentRecord = readsPerRecord
            .filter { $0.key.hasPrefix("backup_") }
            .max { $0.value < $1.value }
        XCTAssertLessThanOrEqual(
            mostReadContentRecord?.value ?? 0,
            3,
            mostReadContentRecord.map { "\($0.key) was read \($0.value) times" } ?? ""
        )

        // The manifest itself is read a handful of times — the workspace, the
        // snapshot, the delta commit — and none of them are per marker.
        XCTAssertLessThanOrEqual(
            readsPerRecord["content_index"] ?? 0,
            6,
            "Reading the manifest once per tombstone is what made this phase grow with every delete"
        )

        let markerQueries = transport.ledger.dropFirst(operationsBefore).filter {
            if case .query(let recordType) = $0 { return recordType == "CD_BackupDeletion" }
            return false
        }
        XCTAssertEqual(markerQueries.count, 1, "One marker scan covers the whole run")
    }

    func testATombstonePastItsRetentionWindowIsRetired() async throws {
        seedTrustedManifest()
        let stale = seedDeletionMarkers(
            count: 1,
            deletedAt: clock.now.addingTimeInterval(-(iCloudStorageManager.deletionMarkerRetentionInterval + 60))
        )[0]
        let fresh = seedDeletionMarkers(count: 1, deletedAt: clock.now.addingTimeInterval(-60))[0]

        _ = try await runReconcile()

        XCTAssertNil(
            transport.record(named: stale),
            "A marker whose delete has had the retention window to reach every device is replayed for nothing"
        )
        XCTAssertNotNil(
            transport.record(named: fresh),
            "A recent marker still has devices to tell"
        )
    }

    func testATombstoneWithNoUsableDeletionTimeIsNeverRetired() async throws {
        seedTrustedManifest()
        let undated = seedDeletionMarkers(count: 1, deletedAt: nil)[0]
        clock.advance(iCloudStorageManager.deletionMarkerRetentionInterval * 2)

        _ = try await runReconcile()

        XCTAssertNotNil(
            transport.record(named: undated),
            "A marker whose age cannot be established must not be aged out"
        )
    }

    func testAManualBackupQueuedBehindASyncSaysItIsWaiting() async throws {
        try createCompleteRecording(named: "Queued behind a sync")
        seedTrustedManifest()

        let gate = AsyncGate()
        transport.fetchGate = gate

        let reconcile = Task { @MainActor in try await self.runReconcile() }
        await waitUntil("the routine pass to be running") { self.manager.isAutomaticReconcileRunning }

        let backup = Task { @MainActor in
            try await self.manager.backupAllDataToiCloud(
                appCoordinator: self.appCoordinator,
                options: CloudBackupOptions(
                    includeAudioFiles: false,
                    includeSettings: false,
                    includeSensitiveSettings: false
                )
            )
        }
        let sawWaiting = await waitUntil("the backup to report that it is queued") {
            self.manager.isUserTransferWaitingForRunningSync
        }
        XCTAssertTrue(
            sawWaiting,
            "A backup held behind a running sync showed the same spinner as work in flight, so it read as stalled"
        )

        gate.open()
        _ = try await reconcile.value
        _ = try await backup.value

        XCTAssertFalse(
            manager.isUserTransferWaitingForRunningSync,
            "The flag has to clear once the transfer gets its turn"
        )
    }

    // MARK: - Bootstrap

    func testAMissingManifestFallsBackToAScanOnceAndThenUsesKnownIds() async throws {
        // A device restored from backup: content in the cloud, no manifest yet.
        let recordingId = UUID()
        transport.seed([
            CloudKitTestRecords.record(
                type: "CD_BackupRecording",
                name: "backup_recording_\(recordingId.uuidString)",
                fields: [
                    "recordingName": "From another device",
                    "recordingDate": Date(),
                    "createdAt": Date(),
                    "lastModified": Date(),
                    "recordingURL": "another.m4a",
                    "duration": 12.0,
                    // Written by a current build: a record without the active
                    // lifecycle marker is held for review instead of restored.
                    "syncLifecycle": "active",
                    "syncSchemaVersion": 2
                ]
            )
        ])

        _ = try await manager.restoreAllDataFromiCloud(
            appCoordinator: appCoordinator,
            includeAudioFiles: false,
            restoreSettings: false
        )

        XCTAssertGreaterThan(transport.queryOperationCount, 0, "Without a manifest a scan is the only way to find anything")
        XCTAssertTrue(
            appCoordinator.coreDataManager.getAllRecordings().contains { $0.id == recordingId },
            "The bootstrap scan must actually restore what it finds"
        )
    }
}
