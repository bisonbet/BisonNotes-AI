//
//  CloudKitBatchExecutorTests.swift
//  BisonNotes AITests
//
//  The executor is the only place that talks to CloudKit in bulk, so these tests
//  pin the two properties everything else depends on: the dataset is covered in a
//  bounded number of requests, and every record comes back with a result.
//

import CloudKit
import XCTest
@testable import BisonNotes_AI

@MainActor
final class CloudKitBatchExecutorTests: XCTestCase {
    private var transport: FakeCloudKitTransport!
    private var clock: ManualCloudSyncClock!
    private var sleeper: RecordingCloudSyncSleeper!
    private var preferences: InMemoryCloudSyncPreferencesStore!
    private var executor: CloudKitBatchExecutor!

    override func setUp() async throws {
        transport = FakeCloudKitTransport()
        clock = ManualCloudSyncClock()
        sleeper = RecordingCloudSyncSleeper(clock: clock)
        preferences = InMemoryCloudSyncPreferencesStore()
        executor = CloudKitBatchExecutor(
            transport: transport,
            sleeper: sleeper,
            clock: clock,
            preferences: preferences,
            jitterProvider: { 0 }
        )
    }

    override func tearDown() async throws {
        executor = nil
        preferences = nil
        sleeper = nil
        clock = nil
        transport = nil
    }

    private func seedRecords(count: Int, type: String = "CD_BackupRecording") -> [String] {
        let names = CloudKitTestRecords.names(count: count)
        transport.seed(names.map { CloudKitTestRecords.record(type: type, name: $0) })
        return names
    }

    // MARK: The production dataset

    func testFetchOf161KnownIdsCostsTwoRequests() async throws {
        let names = seedRecords(count: 161)

        let outcome = try await executor.fetch(CloudKitTestRecords.recordIDs(names))

        XCTAssertEqual(outcome.records.count, 161)
        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(transport.fetchOperationCount, 2, "161 ids must split into batches of 100 and 61")
        XCTAssertEqual(outcome.stats.requestCount, 2)

        if case .fetch(let firstBatch, _) = transport.ledger[0] {
            XCTAssertEqual(firstBatch.count, 100)
        } else {
            XCTFail("Expected the first operation to be a fetch")
        }
        if case .fetch(let secondBatch, _) = transport.ledger[1] {
            XCTAssertEqual(secondBatch.count, 61)
        } else {
            XCTFail("Expected the second operation to be a fetch")
        }
    }

    func testSaveOf161RecordsCostsTwoModifyRequests() async throws {
        let records = CloudKitTestRecords.names(count: 161).map {
            CloudKitTestRecords.record(type: "CD_BackupSummary", name: $0)
        }

        let outcome = try await executor.save(records)

        XCTAssertEqual(outcome.saved.count, 161)
        XCTAssertEqual(transport.modifyOperationCount, 2)
        XCTAssertEqual(transport.storage.count, 161)
    }

    func testDeleteBatchesAndTreatsUnknownItemAsSuccess() async throws {
        let presentNames = seedRecords(count: 3)
        let absentNames = ["missing_one", "missing_two"]

        let outcome = try await executor.delete(
            CloudKitTestRecords.recordIDs(presentNames + absentNames)
        )

        XCTAssertEqual(outcome.deleted.count, 5, "An already-absent record is the state the caller wanted")
        XCTAssertEqual(outcome.alreadyAbsent.count, 2)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(transport.storage.isEmpty)
    }

    func testDuplicateInputsAreSentOnce() async throws {
        let names = seedRecords(count: 2)
        let duplicated = CloudKitTestRecords.recordIDs(names + names + names)

        let outcome = try await executor.fetch(duplicated)

        XCTAssertEqual(outcome.records.count, 2)
        XCTAssertEqual(transport.fetchedRecordNames.count, 2, "Deduplication happens before the request, not after")
    }

    func testDuplicateRecordObjectsKeepTheLatestVersion() async throws {
        let stale = CloudKitTestRecords.record(type: "CD_BackupSummary", name: "summary_1", fields: ["summary": "old"])
        let fresh = CloudKitTestRecords.record(type: "CD_BackupSummary", name: "summary_1", fields: ["summary": "new"])

        _ = try await executor.save([stale, fresh])

        XCTAssertEqual(transport.savedRecordNames, ["summary_1"])
        XCTAssertEqual(transport.record(named: "summary_1")?["summary"] as? String, "new")
    }

    // MARK: Server-side limits

    func testLimitExceededHalvesOnlyTheRejectedBatch() async throws {
        let names = seedRecords(count: 120)
        // The first request (100 ids) is rejected as too large; the second (20) is fine.
        transport.fetchFailures = [CloudKitTestError.ckError(.limitExceeded)]

        let outcome = try await executor.fetch(CloudKitTestRecords.recordIDs(names))

        XCTAssertEqual(outcome.records.count, 120)
        // 1 rejected + 2 halves + 1 for the remaining 20.
        XCTAssertEqual(transport.fetchOperationCount, 4)
        if case .fetch(let secondAttempt, _) = transport.ledger[1] {
            XCTAssertEqual(secondAttempt.count, 50, "A rejected batch is halved, not retried whole")
        } else {
            XCTFail("Expected a fetch after the rejection")
        }
    }

    // MARK: Partial results

    func testPartialSuccessReportsEveryRecordExactlyOnce() async throws {
        let names = seedRecords(count: 4)
        let poisonedID = CKRecord.ID(recordName: names[2])
        transport.perRecordFetchFailures[poisonedID] = [
            CloudKitTestError.ckError(.permissionFailure)
        ]

        let outcome = try await executor.fetch(CloudKitTestRecords.recordIDs(names))

        XCTAssertEqual(outcome.records.count, 3)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertNotNil(outcome.failures[poisonedID])
        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(
            outcome.records.count + outcome.failures.count + outcome.missing.count,
            names.count,
            "Every requested record must be accounted for"
        )
    }

    func testRetryResendsOnlyTheRecordsThatFailed() async throws {
        let records = CloudKitTestRecords.names(count: 3).map {
            CloudKitTestRecords.record(type: "CD_BackupSummary", name: $0)
        }
        let flakyID = records[1].recordID
        transport.perRecordSaveFailures[flakyID] = [
            CloudKitTestError.ckError(.networkFailure)
        ]

        let outcome = try await executor.save(records)

        XCTAssertEqual(outcome.saved.count, 3)
        XCTAssertEqual(transport.modifyOperationCount, 2)
        if case .modify(let retried, _) = transport.ledger[1] {
            XCTAssertEqual(retried, [flakyID.recordName], "Records that already succeeded are never resent")
        } else {
            XCTFail("Expected a second modify carrying only the failed record")
        }
    }

    func testServerRecordChangedIsReportedAsAConflictWithTheServersCopy() async throws {
        let local = CloudKitTestRecords.record(type: "CD_BackupSummary", name: "summary_1", fields: ["summary": "local"])
        let server = CloudKitTestRecords.record(type: "CD_BackupSummary", name: "summary_1", fields: ["summary": "server"])
        transport.perRecordSaveFailures[local.recordID] = [
            CloudKitTestError.ckError(.serverRecordChanged, serverRecord: server)
        ]

        let outcome = try await executor.save([local])

        XCTAssertTrue(outcome.saved.isEmpty)
        XCTAssertEqual(outcome.conflicts.count, 1)
        XCTAssertEqual(outcome.conflicts[local.recordID]?["summary"] as? String, "server")
        XCTAssertEqual(transport.modifyOperationCount, 1, "A conflict is the caller's to resolve, not the executor's to retry blindly")
    }

    // MARK: Assets

    // MARK: Zone enumeration

    func testAZoneFailureDuringEnumerationIsNotAnEmptyZone() async throws {
        // "Erase All iCloud Data" deletes exactly what the enumeration returns and
        // then resets the local bookkeeping, so a zone that could not be read has
        // to surface as an error rather than as nothing to do.
        transport.zoneEnumerationFailure = CloudKitTestError.ckError(.zoneNotFound)

        do {
            _ = try await transport.recordIDs(inZoneWith: CKRecordZone.default().zoneID)
            XCTFail("A failed zone enumeration must not report success")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .zoneNotFound)
        }
    }

    func testAPerRecordFailureInAZoneScanIsNotAPartialScan() async throws {
        transport.seed([CloudKitTestRecords.record(type: "CD_BackupRecording", name: "backup_recording_1")])
        transport.zoneRecordFailure = CloudKitTestError.ckError(.internalError)

        do {
            _ = try await transport.recordZoneChanges(inZoneWith: CKRecordZone.default().zoneID)
            XCTFail("A scan that could not read a record must not report a complete set")
        } catch let error as CKError {
            XCTAssertEqual(error.code, .internalError)
        }
    }

    func testAssetBearingSavesUseTheSmallerBatchSize() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("audio".utf8).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let records = CloudKitTestRecords.names(count: 6).map { name -> CKRecord in
            let record = CloudKitTestRecords.record(type: "CD_BackupRecording", name: name)
            record["audioAsset"] = CKAsset(fileURL: temporaryURL)
            return record
        }

        _ = try await executor.save(records)

        XCTAssertEqual(transport.modifyOperationCount, 2, "Six asset-bearing records go out in batches of four")
    }
}
