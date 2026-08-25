//
//  CloudKitTransport.swift
//  BisonNotes AI
//
//  The seam between the sync legs in `iCloudStorageManager` and CloudKit itself.
//  Production wires `CKDatabaseCloudKitTransport`; tests script a fake so the
//  batching, retry, manifest, and orchestration rules can be proved without a
//  network, an Apple account, or a deployed schema.
//

import CloudKit
import Foundation
import Synchronization

// MARK: - Transport

/// Everything the sync legs need from CloudKit.
///
/// `@MainActor` deliberately: `iCloudStorageManager` is main-actor isolated and
/// every `CKRecord` it builds stays there, so no record ever crosses an isolation
/// boundary and none of the Swift 6 escape hatches are required.
@MainActor
protocol CloudKitTransport: AnyObject {
    func accountStatus() async throws -> CKAccountStatus

    func records(
        for recordIDs: [CKRecord.ID],
        desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]

    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> CloudKitModifyResults

    func records(
        matching query: CKQuery,
        inZoneWith zoneID: CKRecordZone.ID?,
        desiredKeys: [CKRecord.FieldKey]?,
        resultsLimit: Int
    ) async throws -> CloudKitQueryPage

    func records(
        continuingMatchFrom cursor: CKQueryOperation.Cursor,
        desiredKeys: [CKRecord.FieldKey]?,
        resultsLimit: Int
    ) async throws -> CloudKitQueryPage

    /// Retained for explicit recovery only. Routine sync must never scan a zone.
    func recordZoneChanges(inZoneWith zoneID: CKRecordZone.ID) async throws -> [CKRecord]

    /// Identifiers only — no field values, so no audio asset is ever downloaded.
    /// Used by "Erase All iCloud Data" to enumerate what has to go.
    func recordIDs(inZoneWith zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID]

    func allRecordZoneIDs() async throws -> [CKRecordZone.ID]

    func deleteRecordZones(withIDs zoneIDs: [CKRecordZone.ID]) async throws -> [CKRecordZone.ID]
}

struct CloudKitModifyResults {
    var saveResults: [CKRecord.ID: Result<CKRecord, any Error>]
    var deleteResults: [CKRecord.ID: Result<Void, any Error>]

    init(
        saveResults: [CKRecord.ID: Result<CKRecord, any Error>] = [:],
        deleteResults: [CKRecord.ID: Result<Void, any Error>] = [:]
    ) {
        self.saveResults = saveResults
        self.deleteResults = deleteResults
    }
}

struct CloudKitQueryPage {
    var matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)]
    var queryCursor: CKQueryOperation.Cursor?

    init(
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)] = [],
        queryCursor: CKQueryOperation.Cursor? = nil
    ) {
        self.matchResults = matchResults
        self.queryCursor = queryCursor
    }

    var records: [CKRecord] {
        matchResults.compactMap { _, result in
            if case .success(let record) = result { return record }
            return nil
        }
    }
}

// MARK: - Production transport

@MainActor
final class CKDatabaseCloudKitTransport: CloudKitTransport {
    private let container: CKContainer
    private let database: CKDatabase

    init(container: CKContainer, database: CKDatabase) {
        self.container = container
        self.database = database
    }

    convenience init(container: CKContainer) {
        self.init(container: container, database: container.privateCloudDatabase)
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func records(
        for recordIDs: [CKRecord.ID],
        desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        try await database.records(for: recordIDs, desiredKeys: desiredKeys)
    }

    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> CloudKitModifyResults {
        let results = try await database.modifyRecords(
            saving: recordsToSave,
            deleting: recordIDsToDelete,
            savePolicy: savePolicy,
            atomically: atomically
        )
        return CloudKitModifyResults(
            saveResults: results.saveResults,
            deleteResults: results.deleteResults
        )
    }

    func records(
        matching query: CKQuery,
        inZoneWith zoneID: CKRecordZone.ID?,
        desiredKeys: [CKRecord.FieldKey]?,
        resultsLimit: Int
    ) async throws -> CloudKitQueryPage {
        let page = try await database.records(
            matching: query,
            inZoneWith: zoneID,
            desiredKeys: desiredKeys,
            resultsLimit: resultsLimit
        )
        return CloudKitQueryPage(matchResults: page.matchResults, queryCursor: page.queryCursor)
    }

    func records(
        continuingMatchFrom cursor: CKQueryOperation.Cursor,
        desiredKeys: [CKRecord.FieldKey]?,
        resultsLimit: Int
    ) async throws -> CloudKitQueryPage {
        let page = try await database.records(
            continuingMatchFrom: cursor,
            desiredKeys: desiredKeys,
            resultsLimit: resultsLimit
        )
        return CloudKitQueryPage(matchResults: page.matchResults, queryCursor: page.queryCursor)
    }

    func recordZoneChanges(inZoneWith zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: nil
        )

        // CloudKit invokes the per-record block on its own queue, so the
        // accumulator is shared state and needs real synchronization.
        let collected = Mutex<[CKRecord]>([])
        operation.recordWasChangedBlock = { _, result in
            if case .success(let record) = result {
                collected.withLock { $0.append(record) }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            operation.fetchRecordZoneChangesResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(operation)
        }

        return collected.withLock { $0 }
    }

    func recordIDs(inZoneWith zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = nil
        configuration.desiredKeys = []

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: configuration]
        )
        operation.fetchAllChanges = true

        let collected = Mutex<[CKRecord.ID]>([])
        operation.recordWasChangedBlock = { recordID, _ in
            // Keep the ID even when the record body failed to decode; it still
            // needs deleting.
            collected.withLock { $0.append(recordID) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            operation.fetchRecordZoneChangesResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(operation)
        }

        return collected.withLock { $0 }
    }

    func allRecordZoneIDs() async throws -> [CKRecordZone.ID] {
        try await database.allRecordZones().map(\.zoneID)
    }

    func deleteRecordZones(withIDs zoneIDs: [CKRecordZone.ID]) async throws -> [CKRecordZone.ID] {
        let results = try await database.modifyRecordZones(saving: [], deleting: zoneIDs)
        return results.deleteResults.compactMap { zoneID, result in
            if case .success = result { return zoneID }
            return nil
        }
    }
}

// MARK: - Injectable environment

@MainActor
protocol CloudSyncClock: AnyObject {
    var now: Date { get }
    /// Monotonic seconds. Phase timing must not move when the wall clock does.
    var monotonicSeconds: TimeInterval { get }
}

@MainActor
final class SystemCloudSyncClock: CloudSyncClock {
    var now: Date { Date() }
    var monotonicSeconds: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

@MainActor
protocol CloudSyncSleeper: AnyObject {
    func sleep(seconds: TimeInterval) async throws
}

@MainActor
final class SystemCloudSyncSleeper: CloudSyncSleeper {
    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// The small slice of persisted state the transport layer owns: when CloudKit has
/// told us not to come back yet.
@MainActor
protocol CloudSyncPreferencesStore: AnyObject {
    func date(forKey key: String) -> Date?
    func setDate(_ date: Date?, forKey key: String)
}

@MainActor
final class UserDefaultsCloudSyncPreferencesStore: CloudSyncPreferencesStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func date(forKey key: String) -> Date? {
        defaults.object(forKey: key) as? Date
    }

    func setDate(_ date: Date?, forKey key: String) {
        if let date {
            defaults.set(date, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
