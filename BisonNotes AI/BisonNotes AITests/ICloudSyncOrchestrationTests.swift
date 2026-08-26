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

    func testReconcileRunsThePhaseBarrierInOrder() async throws {
        try createCompleteRecording(named: "Phase order")

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
        _ = try await restore.value

        XCTAssertTrue(restoreRan, "Only work that writes to the cloud is cancelled by an erase")
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
