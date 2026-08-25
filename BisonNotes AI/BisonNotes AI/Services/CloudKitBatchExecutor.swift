//
//  CloudKitBatchExecutor.swift
//  BisonNotes AI
//
//  One place where records are fetched, saved, and deleted in batches, and the
//  only place that decides how CloudKit retries are paced.
//
//  Two invariants matter more than the batching itself:
//
//  * every record gets a result — succeeded, missing, deferred, or permanently
//    failed — so no caller can mistake a partial batch for a clean run; and
//  * only the record IDs that actually failed are ever resent. Resending a whole
//    batch because one item failed is how a routine sync turns into minutes of
//    duplicate traffic.
//

import CloudKit
import Foundation

@MainActor
final class CloudKitBatchExecutor {
    struct Limits: Equatable {
        /// CloudKit's documented ceiling for a metadata modify/fetch batch.
        var metadataBatchSize = 100
        /// Asset uploads are large; a rejected batch of 100 wastes an entire upload.
        var assetBatchSize = 4

        func batchSize(forAssetBearing hasAssets: Bool) -> Int {
            hasAssets ? assetBatchSize : metadataBatchSize
        }
    }

    static let defaultDeferralKey = "iCloudSyncNextEligibleDateV1"

    private let transport: any CloudKitTransport
    private let sleeper: any CloudSyncSleeper
    private let clock: any CloudSyncClock
    private let preferences: any CloudSyncPreferencesStore
    private let deferralKey: String
    private let jitterProvider: @MainActor () -> Double

    var limits: Limits
    var retryPolicy: CloudKitRetryPolicy

    init(
        transport: any CloudKitTransport,
        sleeper: any CloudSyncSleeper,
        clock: any CloudSyncClock,
        preferences: any CloudSyncPreferencesStore,
        limits: Limits = Limits(),
        retryPolicy: CloudKitRetryPolicy = CloudKitRetryPolicy(),
        deferralKey: String = CloudKitBatchExecutor.defaultDeferralKey,
        jitterProvider: @escaping @MainActor () -> Double = { Double.random(in: 0...1) }
    ) {
        self.transport = transport
        self.sleeper = sleeper
        self.clock = clock
        self.preferences = preferences
        self.limits = limits
        self.retryPolicy = retryPolicy
        self.deferralKey = deferralKey
        self.jitterProvider = jitterProvider
    }

    // MARK: - Fetch

    func fetch(
        _ recordIDs: [CKRecord.ID],
        desiredKeys: [CKRecord.FieldKey]? = nil
    ) async throws -> CloudKitFetchOutcome {
        var outcome = CloudKitFetchOutcome()
        let uniqueIDs = Self.deduplicated(recordIDs)
        guard !uniqueIDs.isEmpty else { return outcome }

        if let until = deferredUntil {
            outcome.deferred = Set(uniqueIDs)
            outcome.deferredUntil = until
            outcome.stats.deferredCount = uniqueIDs.count
            return outcome
        }

        for chunk in uniqueIDs.chunked(into: limits.metadataBatchSize) {
            try await fetchChunk(chunk, desiredKeys: desiredKeys, attempt: 0, into: &outcome)
        }
        return outcome
    }

    private func fetchChunk(
        _ recordIDs: [CKRecord.ID],
        desiredKeys: [CKRecord.FieldKey]?,
        attempt: Int,
        into outcome: inout CloudKitFetchOutcome
    ) async throws {
        guard !recordIDs.isEmpty else { return }

        outcome.stats.requestCount += 1
        outcome.stats.batchCount += 1

        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await transport.records(for: recordIDs, desiredKeys: desiredKeys)
        } catch let error as CKError {
            if error.code == .limitExceeded, recordIDs.count > 1 {
                let halves = Self.halved(recordIDs)
                try await fetchChunk(halves.0, desiredKeys: desiredKeys, attempt: attempt, into: &outcome)
                try await fetchChunk(halves.1, desiredKeys: desiredKeys, attempt: attempt, into: &outcome)
                return
            }
            try await retryFetch(recordIDs, desiredKeys: desiredKeys, after: error, attempt: attempt, into: &outcome)
            return
        }

        let retry = classifyFetchResults(results, for: recordIDs, into: &outcome)
        guard !retry.recordIDs.isEmpty, let retryError = retry.error else { return }
        try await retryFetch(
            retry.recordIDs,
            desiredKeys: desiredKeys,
            after: retryError,
            attempt: attempt,
            into: &outcome
        )
    }

    /// Sorts one batch's results into arrived / missing / failed, and reports which
    /// record IDs are worth sending again.
    private func classifyFetchResults(
        _ results: [CKRecord.ID: Result<CKRecord, any Error>],
        for recordIDs: [CKRecord.ID],
        into outcome: inout CloudKitFetchOutcome
    ) -> (recordIDs: [CKRecord.ID], error: CKError?) {
        var retryIDs: [CKRecord.ID] = []
        var retryError: CKError?

        for recordID in recordIDs {
            switch results[recordID] {
            case .success(let record):
                outcome.records[recordID] = record
            case .failure(let error):
                switch Self.classify(error) {
                case .missing:
                    outcome.missing.insert(recordID)
                case .retryable(let ckError):
                    retryIDs.append(recordID)
                    retryError = retryError ?? ckError
                case .conflict, .permanent:
                    // A conflict is not meaningful for a read.
                    outcome.failures[recordID] = error
                }
            case .none:
                outcome.missing.insert(recordID)
            }
        }

        return (retryIDs, retryError)
    }

    private func retryFetch(
        _ recordIDs: [CKRecord.ID],
        desiredKeys: [CKRecord.FieldKey]?,
        after error: CKError,
        attempt: Int,
        into outcome: inout CloudKitFetchOutcome
    ) async throws {
        switch try await resolveRetry(for: error, attempt: attempt, stats: &outcome.stats) {
        case .retry(let nextAttempt):
            // Only the record IDs that failed go back out.
            try await fetchChunk(recordIDs, desiredKeys: desiredKeys, attempt: nextAttempt, into: &outcome)
        case .deferred(let until):
            outcome.deferred.formUnion(recordIDs)
            outcome.deferredUntil = until
            outcome.stats.deferredCount += recordIDs.count
        case .failed:
            for recordID in recordIDs { outcome.failures[recordID] = error }
        }
    }

    // MARK: - Modify

    func save(
        _ records: [CKRecord],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .ifServerRecordUnchanged
    ) async throws -> CloudKitModifyOutcome {
        try await modify(saving: records, deleting: [], savePolicy: savePolicy)
    }

    func delete(_ recordIDs: [CKRecord.ID]) async throws -> CloudKitModifyOutcome {
        try await modify(saving: [], deleting: recordIDs)
    }

    func modify(
        saving records: [CKRecord],
        deleting recordIDs: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .ifServerRecordUnchanged
    ) async throws -> CloudKitModifyOutcome {
        var outcome = CloudKitModifyOutcome()
        let uniqueRecords = Self.deduplicatedRecords(records)
        let savedIDs = Set(uniqueRecords.map(\.recordID))
        let uniqueDeletes = Self.deduplicated(recordIDs).filter { !savedIDs.contains($0) }
        guard !uniqueRecords.isEmpty || !uniqueDeletes.isEmpty else { return outcome }

        if let until = deferredUntil {
            outcome.deferred.formUnion(savedIDs)
            outcome.deferred.formUnion(uniqueDeletes)
            outcome.deferredUntil = until
            outcome.stats.deferredCount = outcome.deferred.count
            return outcome
        }

        // Asset-bearing saves ride in much smaller batches; a rejected batch of
        // 100 would throw away every upload in it.
        let assetRecords = uniqueRecords.filter(Self.carriesAsset)
        let metadataRecords = uniqueRecords.filter { !Self.carriesAsset($0) }

        for chunk in metadataRecords.chunked(into: limits.metadataBatchSize) {
            try await modifyChunk(saving: chunk, deleting: [], savePolicy: savePolicy, attempt: 0, into: &outcome)
        }
        for chunk in assetRecords.chunked(into: limits.assetBatchSize) {
            try await modifyChunk(saving: chunk, deleting: [], savePolicy: savePolicy, attempt: 0, into: &outcome)
        }
        for chunk in uniqueDeletes.chunked(into: limits.metadataBatchSize) {
            try await modifyChunk(saving: [], deleting: chunk, savePolicy: savePolicy, attempt: 0, into: &outcome)
        }
        return outcome
    }

    private func modifyChunk(
        saving records: [CKRecord],
        deleting recordIDs: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        attempt: Int,
        into outcome: inout CloudKitModifyOutcome
    ) async throws {
        guard !records.isEmpty || !recordIDs.isEmpty else { return }

        outcome.stats.requestCount += 1
        outcome.stats.batchCount += 1

        let results: CloudKitModifyResults
        do {
            results = try await transport.modifyRecords(
                saving: records,
                deleting: recordIDs,
                savePolicy: savePolicy,
                atomically: false
            )
        } catch let error as CKError {
            if error.code == .limitExceeded, records.count + recordIDs.count > 1 {
                try await splitRejectedChunk(
                    saving: records,
                    deleting: recordIDs,
                    savePolicy: savePolicy,
                    attempt: attempt,
                    into: &outcome
                )
                return
            }
            try await retryModify(
                saving: records,
                deleting: recordIDs,
                savePolicy: savePolicy,
                after: error,
                attempt: attempt,
                into: &outcome
            )
            return
        }

        let retry = classifyModifyResults(results, saving: records, deleting: recordIDs, into: &outcome)
        guard !retry.records.isEmpty || !retry.recordIDs.isEmpty, let retryError = retry.error else { return }
        try await retryModify(
            saving: retry.records,
            deleting: retry.recordIDs,
            savePolicy: savePolicy,
            after: retryError,
            attempt: attempt,
            into: &outcome
        )
    }

    private func splitRejectedChunk(
        saving records: [CKRecord],
        deleting recordIDs: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        attempt: Int,
        into outcome: inout CloudKitModifyOutcome
    ) async throws {
        let saveHalves = Self.halved(records)
        let deleteHalves = Self.halved(recordIDs)
        try await modifyChunk(
            saving: saveHalves.0,
            deleting: deleteHalves.0,
            savePolicy: savePolicy,
            attempt: attempt,
            into: &outcome
        )
        try await modifyChunk(
            saving: saveHalves.1,
            deleting: deleteHalves.1,
            savePolicy: savePolicy,
            attempt: attempt,
            into: &outcome
        )
    }

    private func classifyModifyResults(
        _ results: CloudKitModifyResults,
        saving records: [CKRecord],
        deleting recordIDs: [CKRecord.ID],
        into outcome: inout CloudKitModifyOutcome
    ) -> (records: [CKRecord], recordIDs: [CKRecord.ID], error: CKError?) {
        var retryRecords: [CKRecord] = []
        var retryDeletes: [CKRecord.ID] = []
        var retryError: CKError?

        for record in records {
            switch results.saveResults[record.recordID] {
            case .success(let savedRecord):
                outcome.saved[record.recordID] = savedRecord
            case .failure(let error):
                switch Self.classify(error) {
                case .retryable(let ckError):
                    retryRecords.append(record)
                    retryError = retryError ?? ckError
                case .conflict(let serverRecord):
                    outcome.conflicts[record.recordID] = serverRecord
                case .missing, .permanent:
                    // `.unknownItem` here means the record vanished under an
                    // `.ifServerRecordUnchanged` save, which the caller must know about.
                    outcome.failures[record.recordID] = error
                }
            case .none:
                outcome.failures[record.recordID] = CKError(.internalError)
            }
        }

        for recordID in recordIDs {
            switch results.deleteResults[recordID] {
            case .success:
                outcome.deleted.insert(recordID)
            case .failure(let error):
                switch Self.classify(error) {
                case .missing:
                    // Already gone is the state the caller wanted.
                    outcome.alreadyAbsent.insert(recordID)
                    outcome.deleted.insert(recordID)
                case .retryable(let ckError):
                    retryDeletes.append(recordID)
                    retryError = retryError ?? ckError
                case .conflict, .permanent:
                    outcome.failures[recordID] = error
                }
            case .none:
                outcome.failures[recordID] = CKError(.internalError)
            }
        }

        return (retryRecords, retryDeletes, retryError)
    }

    private func retryModify(
        saving records: [CKRecord],
        deleting recordIDs: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        after error: CKError,
        attempt: Int,
        into outcome: inout CloudKitModifyOutcome
    ) async throws {
        let affectedIDs = records.map(\.recordID) + recordIDs
        switch try await resolveRetry(for: error, attempt: attempt, stats: &outcome.stats) {
        case .retry(let nextAttempt):
            // Records that already succeeded are never resent.
            try await modifyChunk(
                saving: records,
                deleting: recordIDs,
                savePolicy: savePolicy,
                attempt: nextAttempt,
                into: &outcome
            )
        case .deferred(let until):
            outcome.deferred.formUnion(affectedIDs)
            outcome.deferredUntil = until
            outcome.stats.deferredCount += affectedIDs.count
        case .failed:
            for recordID in affectedIDs { outcome.failures[recordID] = error }
        }
    }

    // MARK: - Shared retry handling

    private enum RetryResolution {
        case retry(nextAttempt: Int)
        case deferred(until: Date)
        case failed
    }

    /// Applies the retry policy, performing the wait itself so callers only decide
    /// *what* to resend. Never sleeps past `maximumForegroundWait`: a longer wait
    /// becomes a persisted eligibility time and a deferred result.
    private func resolveRetry(
        for error: CKError,
        attempt: Int,
        stats: inout CloudKitOperationStats
    ) async throws -> RetryResolution {
        switch retryPolicy.decision(for: error, attempt: attempt, jitter: jitterProvider()) {
        case .retry(let delay):
            stats.retryCount += 1
            stats.retryWaitSeconds += delay
            try await sleeper.sleep(seconds: delay)
            return .retry(nextAttempt: attempt + 1)
        case .deferFor(let seconds):
            return .deferred(until: recordDeferral(seconds: seconds))
        case .fail:
            return .failed
        }
    }
}

// MARK: - Backoff gate

extension CloudKitBatchExecutor {
    /// When CloudKit has asked us to wait, this is when we may ask again.
    /// Nothing — not a fetch, not a query, not a fallback scan — may issue a
    /// request before it.
    var deferredUntil: Date? {
        guard let eligible = preferences.date(forKey: deferralKey) else { return nil }
        return eligible > clock.now ? eligible : nil
    }

    var isDeferred: Bool { deferredUntil != nil }

    func clearDeferral() {
        preferences.setDate(nil, forKey: deferralKey)
    }

    @discardableResult
    private func recordDeferral(seconds: TimeInterval) -> Date {
        let until = clock.now.addingTimeInterval(max(seconds, 0))
        if let existing = preferences.date(forKey: deferralKey), existing > until {
            return existing
        }
        preferences.setDate(until, forKey: deferralKey)
        return until
    }
}

// MARK: - Classification and collection helpers

extension CloudKitBatchExecutor {
    // MARK: - Classification

    private enum RecordErrorClass {
        case missing
        case retryable(CKError)
        case conflict(CKRecord)
        case permanent
    }

    private static func classify(_ error: any Error) -> RecordErrorClass {
        guard let ckError = error as? CKError else { return .permanent }
        switch ckError.code {
        case .unknownItem:
            return .missing
        case .serverRecordChanged:
            if let serverRecord = ckError.serverRecord {
                return .conflict(serverRecord)
            }
            return .permanent
        default:
            if CloudKitRetryPolicy.isRetryable(ckError) || ckError.suggestedRetryAfterSeconds != nil {
                return .retryable(ckError)
            }
            return .permanent
        }
    }

    static func carriesAsset(_ record: CKRecord) -> Bool {
        record.allKeys().contains { record[$0] is CKAsset }
    }

    // MARK: - Collection helpers

    private static func deduplicated(_ recordIDs: [CKRecord.ID]) -> [CKRecord.ID] {
        var seen = Set<CKRecord.ID>()
        return recordIDs.filter { seen.insert($0).inserted }
    }

    private static func deduplicatedRecords(_ records: [CKRecord]) -> [CKRecord] {
        var seen = Set<CKRecord.ID>()
        var unique: [CKRecord] = []
        // Later entries win: a caller that rebuilt a record mid-run means the
        // newer object, not the stale one, should reach CloudKit.
        for record in records.reversed() where seen.insert(record.recordID).inserted {
            unique.append(record)
        }
        return unique.reversed()
    }

    private static func halved<Element>(_ items: [Element]) -> ([Element], [Element]) {
        guard items.count > 1 else { return (items, []) }
        let midpoint = items.count / 2
        return (Array(items[..<midpoint]), Array(items[midpoint...]))
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
