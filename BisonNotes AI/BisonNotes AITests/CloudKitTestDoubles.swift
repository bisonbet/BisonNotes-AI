//
//  CloudKitTestDoubles.swift
//  BisonNotes AITests
//
//  Scriptable stand-ins for everything the sync engine talks to. Together they let
//  the batching, retry, manifest, orchestration, and metrics rules be tested for
//  real — with an operation ledger to assert on — without a network, an Apple
//  account, or a deployed CloudKit schema.
//

import CloudKit
import Foundation
@testable import BisonNotes_AI

// MARK: - Errors

enum CloudKitTestError {
    /// What CloudKit actually returns for `CKFetchRecordZoneChangesOperation`
    /// against the default zone, wording included: change enumeration is a
    /// custom-zone feature and the server rejects the call outright.
    static func defaultZoneGetChangesUnsupported() -> CKError {
        CKError(
            _nsError: NSError(
                domain: CKErrorDomain,
                code: CKError.Code.invalidArguments.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Error fetching changes in zone <CKRecordZoneID: 0x0; zoneName=_defaultZone, " +
                        "ownerName=__defaultOwner__>: AppDefaultZone does not support getChanges call"
                ]
            )
        )
    }

    static func ckError(
        _ code: CKError.Code,
        retryAfter: Double? = nil,
        serverRecord: CKRecord? = nil
    ) -> CKError {
        var userInfo: [String: Any] = [:]
        if let retryAfter {
            userInfo[CKErrorRetryAfterKey] = NSNumber(value: retryAfter)
        }
        if let serverRecord {
            userInfo[CKRecordChangedErrorServerRecordKey] = serverRecord
        }
        return CKError(
            _nsError: NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo)
        )
    }
}

// MARK: - Transport

/// Records every call and answers from an in-memory record store. Failures are
/// scripted per call or per record so a test can describe exactly the CloudKit
/// behaviour it cares about.
@MainActor
final class FakeCloudKitTransport: CloudKitTransport {
    enum Operation: Equatable {
        case accountStatus
        case fetch(recordNames: [String], desiredKeys: [String]?)
        case modify(saving: [String], deleting: [String])
        case query(recordType: String)
        case queryContinuation
        case zoneChanges(zoneName: String)
        case zoneRecordIDs(zoneName: String)
        case allZones
        case deleteZones([String])
    }

    private(set) var ledger: [Operation] = []
    var storage: [CKRecord.ID: CKRecord] = [:]
    var accountStatusValue: CKAccountStatus = .available

    /// Consumed in order, one entry per whole-operation call. `nil` means success.
    var fetchFailures: [(any Error)?] = []
    var modifyFailures: [(any Error)?] = []
    /// Per-record failures mixed into a query page alongside the successes,
    /// keyed by the record name CloudKit reports them for.
    var queryRecordFailures: [String: any Error] = [:]
    /// Consumed in order, one entry per `CKQuery`. `nil` means success.
    var queryFailures: [(any Error)?] = []
    /// Consumed in order per record, whenever that record is fetched.
    var perRecordFetchFailures: [CKRecord.ID: [any Error]] = [:]
    /// Consumed in order per record, whenever that record is saved.
    var perRecordSaveFailures: [CKRecord.ID: [any Error]] = [:]
    /// Records whose delete should report a specific failure.
    var perRecordDeleteFailures: [CKRecord.ID: [any Error]] = [:]

    /// Fires just before a modify is applied, so a test can simulate another
    /// device writing between our read and our save.
    var beforeModify: (@MainActor (FakeCloudKitTransport) -> Void)?

    /// Awaited inside every modify. A test can hold one write open and start a
    /// second one to prove the second never reaches CloudKit concurrently.
    var modifyGate: AsyncGate?

    /// Awaited inside every fetch, for the same reason.
    var fetchGate: AsyncGate?

    /// Fires just before a fetch is answered, so a test can simulate another
    /// device writing between two reads in the same run.
    var beforeFetch: (@MainActor (FakeCloudKitTransport) -> Void)?

    /// Thrown by the zone enumeration, standing in for a per-zone failure that
    /// CloudKit reports while the operation as a whole succeeds.
    var zoneEnumerationFailure: (any Error)?

    /// A per-record failure delivered by a zone scan while the zone itself and the
    /// operation as a whole succeed.
    var zoneRecordFailure: (any Error)?

    // MARK: Convenience

    func seed(_ records: [CKRecord]) {
        for record in records {
            storage[record.recordID] = record
        }
    }

    func record(named recordName: String) -> CKRecord? {
        storage[CKRecord.ID(recordName: recordName)]
    }

    func clearLedger() {
        ledger.removeAll()
    }

    var fetchOperationCount: Int {
        ledger.filter { if case .fetch = $0 { return true } else { return false } }.count
    }

    var modifyOperationCount: Int {
        ledger.filter { if case .modify = $0 { return true } else { return false } }.count
    }

    var queryOperationCount: Int {
        ledger.filter {
            switch $0 {
            case .query, .queryContinuation: return true
            default: return false
            }
        }.count
    }

    var savedRecordNames: [String] {
        ledger.flatMap { operation -> [String] in
            if case .modify(let saving, _) = operation { return saving }
            return []
        }
    }

    var deletedRecordNames: [String] {
        ledger.flatMap { operation -> [String] in
            if case .modify(_, let deleting) = operation { return deleting }
            return []
        }
    }

    var fetchedRecordNames: [String] {
        ledger.flatMap { operation -> [String] in
            if case .fetch(let recordNames, _) = operation { return recordNames }
            return []
        }
    }

    // MARK: CloudKitTransport

    func accountStatus() async throws -> CKAccountStatus {
        ledger.append(.accountStatus)
        return accountStatusValue
    }

    func records(
        for recordIDs: [CKRecord.ID],
        desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        ledger.append(.fetch(recordNames: recordIDs.map(\.recordName), desiredKeys: desiredKeys))

        if !fetchFailures.isEmpty, let failure = fetchFailures.removeFirst() {
            throw failure
        }

        if let fetchGate {
            await fetchGate.wait()
        }

        beforeFetch?(self)

        var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for recordID in recordIDs {
            if var queued = perRecordFetchFailures[recordID], !queued.isEmpty {
                let failure = queued.removeFirst()
                perRecordFetchFailures[recordID] = queued
                results[recordID] = .failure(failure)
                continue
            }
            if let record = storage[recordID] {
                results[recordID] = .success(record)
            } else {
                results[recordID] = .failure(CloudKitTestError.ckError(.unknownItem))
            }
        }
        return results
    }

    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> CloudKitModifyResults {
        ledger.append(
            .modify(
                saving: recordsToSave.map(\.recordID.recordName),
                deleting: recordIDsToDelete.map(\.recordName)
            )
        )

        if !modifyFailures.isEmpty, let failure = modifyFailures.removeFirst() {
            throw failure
        }

        if let modifyGate {
            await modifyGate.wait()
        }

        beforeModify?(self)

        var results = CloudKitModifyResults()
        for record in recordsToSave {
            if var queued = perRecordSaveFailures[record.recordID], !queued.isEmpty {
                let failure = queued.removeFirst()
                perRecordSaveFailures[record.recordID] = queued
                results.saveResults[record.recordID] = .failure(failure)
                continue
            }
            storage[record.recordID] = record
            results.saveResults[record.recordID] = .success(record)
        }
        for recordID in recordIDsToDelete {
            if var queued = perRecordDeleteFailures[recordID], !queued.isEmpty {
                let failure = queued.removeFirst()
                perRecordDeleteFailures[recordID] = queued
                results.deleteResults[recordID] = .failure(failure)
                continue
            }
            if storage.removeValue(forKey: recordID) == nil {
                results.deleteResults[recordID] = .failure(CloudKitTestError.ckError(.unknownItem))
            } else {
                results.deleteResults[recordID] = .success(())
            }
        }
        return results
    }

    func records(
        matching query: CKQuery,
        inZoneWith zoneID: CKRecordZone.ID?,
        desiredKeys: [CKRecord.FieldKey]?,
        resultsLimit: Int
    ) async throws -> CloudKitQueryPage {
        ledger.append(.query(recordType: query.recordType))

        if !queryFailures.isEmpty, let failure = queryFailures.removeFirst() {
            throw failure
        }

        let matches = storage.values
            .filter { $0.recordType == query.recordType }
            .sorted { $0.recordID.recordName < $1.recordID.recordName }
            .prefix(max(resultsLimit, 0))
        return CloudKitQueryPage(
            matchResults: matches.map { record in
                if let failure = queryRecordFailures[record.recordID.recordName] {
                    return (record.recordID, .failure(failure))
                }
                return (record.recordID, .success(record))
            },
            queryCursor: nil
        )
    }

    func records(
        continuingMatchFrom cursor: CKQueryOperation.Cursor,
        desiredKeys: [CKRecord.FieldKey]?,
        resultsLimit: Int
    ) async throws -> CloudKitQueryPage {
        ledger.append(.queryContinuation)
        return CloudKitQueryPage()
    }

    func recordZoneChanges(inZoneWith zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        ledger.append(.zoneChanges(zoneName: zoneID.zoneName))
        if let zoneEnumerationFailure {
            throw zoneEnumerationFailure
        }
        if let zoneRecordFailure {
            throw zoneRecordFailure
        }
        return Array(storage.values).sorted { $0.recordID.recordName < $1.recordID.recordName }
    }

    func recordIDs(inZoneWith zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        ledger.append(.zoneRecordIDs(zoneName: zoneID.zoneName))
        if let zoneEnumerationFailure {
            throw zoneEnumerationFailure
        }
        return storage.keys.sorted { $0.recordName < $1.recordName }
    }

    func allRecordZoneIDs() async throws -> [CKRecordZone.ID] {
        ledger.append(.allZones)
        return [CKRecordZone.default().zoneID]
    }

    func deleteRecordZones(withIDs zoneIDs: [CKRecordZone.ID]) async throws -> [CKRecordZone.ID] {
        ledger.append(.deleteZones(zoneIDs.map(\.zoneName)))
        return zoneIDs
    }
}

/// A suspension point a test can open on demand.
@MainActor
final class AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

// MARK: - Clock and sleeper

@MainActor
final class ManualCloudSyncClock: CloudSyncClock {
    private(set) var now: Date
    private(set) var monotonicSeconds: TimeInterval

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000), monotonicSeconds: TimeInterval = 1_000) {
        self.now = now
        self.monotonicSeconds = monotonicSeconds
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        monotonicSeconds += seconds
    }
}

/// Records what it was asked to wait for and returns immediately, so a test that
/// exercises a retry never actually waits.
@MainActor
final class RecordingCloudSyncSleeper: CloudSyncSleeper {
    private(set) var requestedSleeps: [TimeInterval] = []
    weak var clock: ManualCloudSyncClock?

    init(clock: ManualCloudSyncClock? = nil) {
        self.clock = clock
    }

    var totalSleepSeconds: TimeInterval { requestedSleeps.reduce(0, +) }

    func sleep(seconds: TimeInterval) async throws {
        requestedSleeps.append(seconds)
        clock?.advance(seconds)
    }
}

@MainActor
final class InMemoryCloudSyncPreferencesStore: CloudSyncPreferencesStore {
    private var dates: [String: Date] = [:]

    func date(forKey key: String) -> Date? {
        dates[key]
    }

    func setDate(_ date: Date?, forKey key: String) {
        if let date {
            dates[key] = date
        } else {
            dates.removeValue(forKey: key)
        }
    }
}

// MARK: - Metrics and staging

@MainActor
final class RecordingCloudSyncMetricsSink: CloudSyncMetricsSink {
    private(set) var reports: [CloudSyncRunReport] = []

    var lastReport: CloudSyncRunReport? { reports.last }

    func record(_ report: CloudSyncRunReport) {
        reports.append(report)
    }
}

/// Stands in for the filesystem staging copy. `stagedSources` is what a test
/// asserts on; `missingSources` simulates a file that disappeared between the
/// decision to upload and the copy.
@MainActor
final class RecordingAssetStaging: CloudAssetStaging {
    private(set) var stagedSources: [URL] = []
    private(set) var cleanUpCount = 0
    var missingSources: Set<URL> = []

    func stage(_ sourceURL: URL) -> URL? {
        guard !missingSources.contains(sourceURL) else { return nil }
        stagedSources.append(sourceURL)
        return sourceURL.deletingLastPathComponent()
            .appendingPathComponent("staged-" + sourceURL.lastPathComponent)
    }

    func cleanUp() {
        cleanUpCount += 1
    }
}

// MARK: - Record builders

enum CloudKitTestRecords {
    static func record(
        type: String,
        name: String,
        fields: [String: any CKRecordValueProtocol] = [:]
    ) -> CKRecord {
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name))
        for (key, value) in fields {
            record[key] = value
        }
        return record
    }

    static func recordIDs(_ names: [String]) -> [CKRecord.ID] {
        names.map { CKRecord.ID(recordName: $0) }
    }

    static func names(count: Int, prefix: String = "record_") -> [String] {
        (0..<count).map { String(format: "\(prefix)%03d", $0) }
    }
}
