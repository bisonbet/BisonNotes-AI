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

        // An earlier chunk, split, or retry may have closed the gate. CloudKit asked
        // this device to stop; the chunks behind it must not keep going.
        if let until = deferredUntil {
            markDeferred(recordIDs, until: until, into: &outcome)
            return
        }

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
            try await retryFetch(
                recordIDs.map { RetryableFailure(recordID: $0, error: error) },
                desiredKeys: desiredKeys,
                attempt: attempt,
                into: &outcome
            )
            return
        }

        let retryable = classifyFetchResults(results, for: recordIDs, into: &outcome)
        guard !retryable.isEmpty else { return }
        try await retryFetch(retryable, desiredKeys: desiredKeys, attempt: attempt, into: &outcome)
    }

    /// Sorts one batch's results into arrived / missing / failed, and reports which
    /// records are worth sending again — each with its own error, because CloudKit
    /// can ask for a different wait per record.
    private func classifyFetchResults(
        _ results: [CKRecord.ID: Result<CKRecord, any Error>],
        for recordIDs: [CKRecord.ID],
        into outcome: inout CloudKitFetchOutcome
    ) -> [RetryableFailure] {
        var retryable: [RetryableFailure] = []

        for recordID in recordIDs {
            switch results[recordID] {
            case .success(let record):
                outcome.records[recordID] = record
            case .failure(let error):
                switch Self.classify(error) {
                case .missing:
                    outcome.missing.insert(recordID)
                case .retryable(let ckError):
                    retryable.append(RetryableFailure(recordID: recordID, error: ckError))
                case .conflict, .permanent:
                    // A conflict is not meaningful for a read.
                    outcome.failures[recordID] = error
                }
            case .none:
                outcome.missing.insert(recordID)
            }
        }

        return retryable
    }

    private func retryFetch(
        _ failures: [RetryableFailure],
        desiredKeys: [CKRecord.FieldKey]?,
        attempt: Int,
        into outcome: inout CloudKitFetchOutcome
    ) async throws {
        let plan = planRetry(for: failures, attempt: attempt)

        for failure in plan.permanent {
            outcome.failures[failure.recordID] = failure.error
        }
        if !plan.deferred.isEmpty, let until = plan.deferredUntil {
            markDeferred(plan.deferred, until: until, into: &outcome)
        }

        guard !plan.retryable.isEmpty else { return }
        outcome.stats.retryCount += 1
        outcome.stats.retryWaitSeconds += plan.retryDelay
        try await sleeper.sleep(seconds: plan.retryDelay)
        // Only the record IDs that failed go back out.
        try await fetchChunk(plan.retryable, desiredKeys: desiredKeys, attempt: attempt + 1, into: &outcome)
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

        // An earlier chunk, split, or retry may have closed the gate. Writing on
        // through a backoff CloudKit asked for is what deepens the throttling.
        if let until = deferredUntil {
            markDeferred(records.map(\.recordID) + recordIDs, until: until, into: &outcome)
            return
        }

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
                failures: (records.map(\.recordID) + recordIDs).map {
                    RetryableFailure(recordID: $0, error: error)
                },
                savePolicy: savePolicy,
                attempt: attempt,
                into: &outcome
            )
            return
        }

        let retry = classifyModifyResults(results, saving: records, deleting: recordIDs, into: &outcome)
        guard !retry.failures.isEmpty else { return }
        try await retryModify(
            saving: retry.records,
            deleting: retry.recordIDs,
            failures: retry.failures,
            savePolicy: savePolicy,
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
        // Halving the two lists independently makes no progress when a chunk
        // holds one save and one delete: each half comes back whole, so the
        // first recursion is handed the identical chunk and the split repeats
        // for as long as CloudKit keeps rejecting it. Separating the two kinds
        // is what shrinks such a chunk, and it shrinks any mixed chunk.
        if !records.isEmpty, !recordIDs.isEmpty {
            try await modifyChunk(
                saving: records,
                deleting: [],
                savePolicy: savePolicy,
                attempt: attempt,
                into: &outcome
            )
            try await modifyChunk(
                saving: [],
                deleting: recordIDs,
                savePolicy: savePolicy,
                attempt: attempt,
                into: &outcome
            )
            return
        }

        // One kind only, and a chunk is split only when it holds more than one
        // record, so both halves are strictly smaller than what was rejected.
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
    ) -> (records: [CKRecord], recordIDs: [CKRecord.ID], failures: [RetryableFailure]) {
        var retryRecords: [CKRecord] = []
        var retryDeletes: [CKRecord.ID] = []
        var retryable: [RetryableFailure] = []

        for record in records {
            switch results.saveResults[record.recordID] {
            case .success(let savedRecord):
                outcome.saved[record.recordID] = savedRecord
            case .failure(let error):
                switch Self.classify(error) {
                case .retryable(let ckError):
                    retryRecords.append(record)
                    retryable.append(RetryableFailure(recordID: record.recordID, error: ckError))
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
                    retryable.append(RetryableFailure(recordID: recordID, error: ckError))
                case .conflict, .permanent:
                    outcome.failures[recordID] = error
                }
            case .none:
                outcome.failures[recordID] = CKError(.internalError)
            }
        }

        return (retryRecords, retryDeletes, retryable)
    }

    private func retryModify(
        saving records: [CKRecord],
        deleting recordIDs: [CKRecord.ID],
        failures: [RetryableFailure],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        attempt: Int,
        into outcome: inout CloudKitModifyOutcome
    ) async throws {
        let plan = planRetry(for: failures, attempt: attempt)

        for failure in plan.permanent {
            outcome.failures[failure.recordID] = failure.error
        }
        if !plan.deferred.isEmpty, let until = plan.deferredUntil {
            markDeferred(plan.deferred, until: until, into: &outcome)
        }

        let resendable = Set(plan.retryable)
        guard !resendable.isEmpty else { return }
        outcome.stats.retryCount += 1
        outcome.stats.retryWaitSeconds += plan.retryDelay
        try await sleeper.sleep(seconds: plan.retryDelay)
        // Records that already succeeded — or that are now deferred — are never resent.
        try await modifyChunk(
            saving: records.filter { resendable.contains($0.recordID) },
            deleting: recordIDs.filter { resendable.contains($0) },
            savePolicy: savePolicy,
            attempt: attempt + 1,
            into: &outcome
        )
    }

    // MARK: - Shared retry handling

    struct RetryableFailure {
        let recordID: CKRecord.ID
        let error: CKError
    }

    private struct RetryPlan {
        var retryable: [CKRecord.ID] = []
        /// The longest wait any resendable record asked for. Retrying sooner than
        /// that would ignore what CloudKit said about one of them.
        var retryDelay: TimeInterval = 0
        var deferred: [CKRecord.ID] = []
        var deferredUntil: Date?
        var permanent: [RetryableFailure] = []
    }

    /// Decides what happens to each failed record separately.
    ///
    /// CloudKit can ask for two seconds on one record and two minutes on another in
    /// the same batch. Applying the first error's decision to all of them resent
    /// records long before the server said they could go.
    private func planRetry(for failures: [RetryableFailure], attempt: Int) -> RetryPlan {
        var plan = RetryPlan()
        var longestDeferral: TimeInterval = 0

        for failure in failures {
            switch retryPolicy.decision(for: failure.error, attempt: attempt, jitter: jitterProvider()) {
            case .retry(let delay):
                plan.retryable.append(failure.recordID)
                plan.retryDelay = max(plan.retryDelay, delay)
            case .deferFor(let seconds):
                plan.deferred.append(failure.recordID)
                longestDeferral = max(longestDeferral, seconds)
            case .fail:
                plan.permanent.append(failure)
            }
        }

        if !plan.deferred.isEmpty {
            plan.deferredUntil = recordDeferral(seconds: longestDeferral)
            // The gate is global: once it closes nothing may be sent, so records
            // that would otherwise have been retried wait with the rest.
            plan.deferred.append(contentsOf: plan.retryable)
            plan.retryable.removeAll()
        }

        return plan
    }

    private func markDeferred(
        _ recordIDs: [CKRecord.ID],
        until: Date,
        into outcome: inout CloudKitFetchOutcome
    ) {
        let newlyDeferred = recordIDs.filter { !outcome.deferred.contains($0) }
        outcome.deferred.formUnion(newlyDeferred)
        outcome.deferredUntil = until
        outcome.stats.deferredCount += newlyDeferred.count
    }

    private func markDeferred(
        _ recordIDs: [CKRecord.ID],
        until: Date,
        into outcome: inout CloudKitModifyOutcome
    ) {
        let newlyDeferred = recordIDs.filter { !outcome.deferred.contains($0) }
        outcome.deferred.formUnion(newlyDeferred)
        outcome.deferredUntil = until
        outcome.stats.deferredCount += newlyDeferred.count
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

    /// Applies the retry policy to an error raised *outside* a batched operation —
    /// a `CKQuery` or a zone scan — so those paths respect the same gate.
    ///
    /// Returns the deferral when one was recorded. Any throttling answer counts:
    /// a query that CloudKit is rate-limiting must not be escalated into a heavier
    /// zone scan, which is more traffic in the window it just asked us to sit out.
    @discardableResult
    func recordDeferralIfThrottled(_ error: CKError) -> Date? {
        switch retryPolicy.decision(for: error, attempt: 0, jitter: jitterProvider()) {
        case .deferFor(let seconds):
            return recordDeferral(seconds: seconds)
        case .retry(let delay):
            return recordDeferral(seconds: delay)
        case .fail:
            return nil
        }
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
