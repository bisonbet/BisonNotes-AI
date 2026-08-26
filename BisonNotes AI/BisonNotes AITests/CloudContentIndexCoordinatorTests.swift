//
//  CloudContentIndexCoordinatorTests.swift
//  BisonNotes AITests
//
//  `content_index` is the one record every device writes, and the oplock conflicts
//  in the field logs all came from rewriting it wholesale. These tests pin the
//  delta rules that replaced that: another device's entries survive, a removal
//  always beats a concurrent add, and only one write is ever in flight.
//

import CloudKit
import XCTest
@testable import BisonNotes_AI

@MainActor
final class CloudContentIndexCoordinatorTests: XCTestCase {
    private var transport: FakeCloudKitTransport!
    private var clock: ManualCloudSyncClock!
    private var executor: CloudKitBatchExecutor!
    private var coordinator: CloudContentIndexCoordinator!

    private let indexRecordName = "content_index"
    private let recordingsField = "recordingRecordNames"
    private let transcriptsField = "transcriptRecordNames"
    private let summariesField = "summaryRecordNames"

    override func setUp() async throws {
        transport = FakeCloudKitTransport()
        clock = ManualCloudSyncClock()
        executor = CloudKitBatchExecutor(
            transport: transport,
            sleeper: RecordingCloudSyncSleeper(clock: clock),
            clock: clock,
            preferences: InMemoryCloudSyncPreferencesStore(),
            jitterProvider: { 0 }
        )
        coordinator = CloudContentIndexCoordinator(
            executor: executor,
            configuration: iCloudStorageManager.contentIndexConfiguration,
            deviceIdentifier: "test-device",
            clock: clock
        )
    }

    override func tearDown() async throws {
        coordinator = nil
        executor = nil
        clock = nil
        transport = nil
    }

    private func seedIndex(
        recordings: [String] = [],
        transcripts: [String] = [],
        summaries: [String] = [],
        manifestSchemaVersion: Int = 2
    ) {
        let record = CloudKitTestRecords.record(
            type: "CD_BackupContentIndex",
            name: indexRecordName,
            fields: [
                recordingsField: recordings as NSArray,
                transcriptsField: transcripts as NSArray,
                summariesField: summaries as NSArray,
                "manifestSchemaVersion": manifestSchemaVersion
            ]
        )
        transport.seed([record])
    }

    private func storedManifest() -> CloudActiveManifest {
        guard let record = transport.record(named: indexRecordName) else { return CloudActiveManifest() }
        return CloudActiveManifest(
            recordings: Set(record[recordingsField] as? [String] ?? []),
            transcripts: Set(record[transcriptsField] as? [String] ?? []),
            summaries: Set(record[summariesField] as? [String] ?? [])
        )
    }

    // MARK: Delta arithmetic

    func testRemovalBeatsAConcurrentAddOfTheSameId() {
        let addition = ManifestDelta.adding(recordings: ["backup_recording_a"])
        let removal = ManifestDelta.removing(recordings: ["backup_recording_a"])

        let merged = addition.merged(with: removal)

        XCTAssertTrue(merged.addRecordings.isEmpty, "A tombstoned id must never be re-added")
        XCTAssertEqual(merged.removeRecordings, ["backup_recording_a"])
        XCTAssertEqual(merged.applied(to: CloudActiveManifest(recordings: ["backup_recording_a"])).recordings, [])
    }

    func testMergeKeepsUnrelatedEntriesFromBothDeltas() {
        let first = ManifestDelta.adding(recordings: ["a"], summaries: ["s1"])
        let second = ManifestDelta.removing(transcripts: ["t1"])

        let merged = first.merged(with: second)

        XCTAssertEqual(merged.addRecordings, ["a"])
        XCTAssertEqual(merged.addSummaries, ["s1"])
        XCTAssertEqual(merged.removeTranscripts, ["t1"])
    }

    // MARK: Writing

    func testApplyAddsWithoutDisturbingExistingEntries() async throws {
        seedIndex(recordings: ["backup_recording_other"], summaries: ["backup_summary_other"])

        try await coordinator.apply(.adding(recordings: ["backup_recording_mine"]))

        let manifest = storedManifest()
        XCTAssertEqual(manifest.recordings, ["backup_recording_other", "backup_recording_mine"])
        XCTAssertEqual(manifest.summaries, ["backup_summary_other"])
    }

    func testConcurrentAddAndRemoveLeaveTheIdOut() async throws {
        seedIndex(recordings: ["backup_recording_a"])

        let addition = Task { @MainActor in
            try await self.coordinator.apply(.adding(recordings: ["backup_recording_a"]))
        }
        let removal = Task { @MainActor in
            try await self.coordinator.apply(.removing(recordings: ["backup_recording_a"]))
        }
        _ = try await addition.value
        _ = try await removal.value

        XCTAssertFalse(
            storedManifest().recordings.contains("backup_recording_a"),
            "A removal reflects content that is already gone; an add must not resurrect it"
        )
    }

    func testConflictRebasesOntoTheServerRecordAndKeepsItsEntries() async throws {
        seedIndex(recordings: ["backup_recording_local"])

        // Another device added its own entry and saved first.
        let serverRecord = CloudKitTestRecords.record(
            type: "CD_BackupContentIndex",
            name: indexRecordName,
            fields: [
                recordingsField: ["backup_recording_local", "backup_recording_other_device"] as NSArray,
                transcriptsField: [] as NSArray,
                summariesField: [] as NSArray,
                "manifestSchemaVersion": 2
            ]
        )
        transport.perRecordSaveFailures[CKRecord.ID(recordName: indexRecordName)] = [
            CloudKitTestError.ckError(.serverRecordChanged, serverRecord: serverRecord)
        ]

        try await coordinator.apply(.adding(recordings: ["backup_recording_mine"]))

        let manifest = storedManifest()
        XCTAssertEqual(
            manifest.recordings,
            ["backup_recording_local", "backup_recording_other_device", "backup_recording_mine"],
            "A conflict must keep what the other device wrote and reapply only our delta"
        )
    }

    func testConflictRebaseHonorsARemovalAgainstTheServersAdd() async throws {
        seedIndex(recordings: ["backup_recording_a"])
        let serverRecord = CloudKitTestRecords.record(
            type: "CD_BackupContentIndex",
            name: indexRecordName,
            fields: [
                recordingsField: ["backup_recording_a", "backup_recording_b"] as NSArray,
                transcriptsField: [] as NSArray,
                summariesField: [] as NSArray,
                "manifestSchemaVersion": 2
            ]
        )
        transport.perRecordSaveFailures[CKRecord.ID(recordName: indexRecordName)] = [
            CloudKitTestError.ckError(.serverRecordChanged, serverRecord: serverRecord)
        ]

        try await coordinator.apply(.removing(recordings: ["backup_recording_a"]))

        let manifest = storedManifest()
        XCTAssertEqual(manifest.recordings, ["backup_recording_b"])
    }

    func testOnlyOneIndexWriteIsEverInFlight() async throws {
        seedIndex()
        let gate = AsyncGate()
        transport.modifyGate = gate

        let first = Task { try await self.coordinator.apply(.adding(recordings: ["a"])) }
        // Let the first write reach the transport and block there.
        await Task.yield()
        await Task.yield()
        let second = Task { try await self.coordinator.apply(.adding(transcripts: ["t"])) }
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(
            transport.modifyOperationCount,
            1,
            "A second manifest write must wait for the first rather than race it"
        )

        gate.open()
        _ = try await first.value
        _ = try await second.value

        let manifest = storedManifest()
        XCTAssertEqual(manifest.recordings, ["a"])
        XCTAssertEqual(manifest.transcripts, ["t"], "The queued delta still has to be written")
    }

    func testARemovalInFlightStillBeatsAnAddThatArrivesDuringIt() async throws {
        seedIndex(recordings: ["backup_recording_a", "backup_recording_b"])
        let gate = AsyncGate()
        transport.modifyGate = gate

        // The removal reaches CloudKit and blocks there…
        let removal = Task { @MainActor in
            try await self.coordinator.apply(.removing(recordings: ["backup_recording_a"]))
        }
        while transport.modifyOperationCount == 0 {
            await Task.yield()
        }

        // …and an add of the same id arrives while it is saving, so it merges with
        // a queue the removal has already been taken out of.
        let addition = Task { @MainActor in
            try await self.coordinator.apply(.adding(recordings: ["backup_recording_a"]))
        }
        await Task.yield()
        await Task.yield()
        gate.open()

        _ = try await removal.value
        _ = try await addition.value

        XCTAssertFalse(
            storedManifest().recordings.contains("backup_recording_a"),
            "A removal means a tombstone exists; an add that raced it must not put the name back"
        )
        XCTAssertTrue(storedManifest().recordings.contains("backup_recording_b"), "…and unrelated entries survive")
    }

    func testAnUntrustedManifestIsNotUsedAsAKnownIdList() async throws {
        seedIndex(recordings: ["backup_recording_a"], manifestSchemaVersion: 1)

        let manifest = try await coordinator.fetchTrustedManifest()

        XCTAssertTrue(manifest.isEmpty, "An older-schema manifest cannot be trusted to name every live record")
    }

    func testReplaceIsAFullOverwriteForRepair() async throws {
        seedIndex(recordings: ["stale_a", "stale_b"])

        try await coordinator.replace(
            with: CloudActiveManifest(recordings: ["repaired"], transcripts: [], summaries: [])
        )

        XCTAssertEqual(storedManifest().recordings, ["repaired"])
    }
}
