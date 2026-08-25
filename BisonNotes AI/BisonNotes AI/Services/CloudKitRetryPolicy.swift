//
//  CloudKitRetryPolicy.swift
//  BisonNotes AI
//
//  How long to wait before touching CloudKit again, and the per-record results a
//  batched operation reports back. Both live next to each other because they
//  answer the same question: what still needs doing after this request?
//

import CloudKit
import Foundation

// MARK: - Retry policy

struct CloudKitRetryPolicy: Equatable {
    /// Retries after the first attempt. Three means at most four requests for one batch.
    var maxRetries: Int = 3
    /// Base for the bounded exponential backoff used when CloudKit supplies no delay.
    var baseDelay: TimeInterval = 2
    /// Ceiling for a self-calculated delay.
    var maximumBackoffDelay: TimeInterval = 30
    /// A wait longer than this is not worth holding a foreground task open for.
    var maximumForegroundWait: TimeInterval = 30
    /// Fraction of the calculated delay that jitter may add.
    var jitterFraction: Double = 0.25

    enum Decision: Equatable {
        /// Sleep, then retry the failed record IDs.
        case retry(after: TimeInterval)
        /// CloudKit asked for a long wait. Persist the eligibility time and report deferred.
        case deferFor(seconds: TimeInterval)
        /// Out of attempts, or the error will never succeed on retry.
        case fail
    }

    /// - Parameters:
    ///   - attempt: retries already performed for this batch (0 on the first failure).
    ///   - jitter: unit random value; injected so tests are deterministic.
    func decision(for error: CKError, attempt: Int, jitter: Double) -> Decision {
        // A server-requested delay is honored even when the code is not on the
        // usual retryable list: CloudKit only sends it when waiting will help.
        let serverDelay = error.suggestedRetryAfterSeconds

        if let serverDelay, serverDelay > maximumForegroundWait {
            return .deferFor(seconds: serverDelay)
        }

        guard serverDelay != nil || Self.isRetryable(error) else { return .fail }
        guard attempt < maxRetries else { return .fail }

        if let serverDelay {
            return .retry(after: max(serverDelay, 0))
        }

        let exponential = min(baseDelay * pow(2, Double(attempt)), maximumBackoffDelay)
        let jittered = exponential * (1 + jitterFraction * max(0, min(1, jitter)))
        let delay = min(jittered, maximumBackoffDelay)
        if delay > maximumForegroundWait {
            return .deferFor(seconds: delay)
        }
        return .retry(after: delay)
    }

    static func isRetryable(_ error: CKError) -> Bool {
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .batchRequestFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - Outcomes

/// Per-record results of a batched fetch. Callers read `records` for what arrived
/// and must treat `deferred` and `failures` as work that still needs doing.
struct CloudKitFetchOutcome {
    var records: [CKRecord.ID: CKRecord] = [:]
    var missing: Set<CKRecord.ID> = []
    var deferred: Set<CKRecord.ID> = []
    var failures: [CKRecord.ID: any Error] = [:]
    var deferredUntil: Date?
    var stats = CloudKitOperationStats()

    var isComplete: Bool { deferred.isEmpty && failures.isEmpty }
    var fetchedRecords: [CKRecord] { Array(records.values) }

    func record(for recordID: CKRecord.ID) -> CKRecord? { records[recordID] }

    /// Rethrows the first permanent failure. Used where the previous per-record
    /// code path threw, so error surfacing to the UI is unchanged.
    func throwIfFailed() throws {
        if let error = failures.values.first { throw error }
    }
}

/// Per-record results of a batched save/delete.
struct CloudKitModifyOutcome {
    var saved: [CKRecord.ID: CKRecord] = [:]
    var deleted: Set<CKRecord.ID> = []
    /// Delete of an absent record. Treated as success by callers, reported here for metrics.
    var alreadyAbsent: Set<CKRecord.ID> = []
    /// `.serverRecordChanged`, keyed by record ID, carrying the server's copy.
    var conflicts: [CKRecord.ID: CKRecord] = [:]
    var deferred: Set<CKRecord.ID> = []
    var failures: [CKRecord.ID: any Error] = [:]
    var deferredUntil: Date?
    var stats = CloudKitOperationStats()

    var isComplete: Bool { deferred.isEmpty && failures.isEmpty && conflicts.isEmpty }
    var savedCount: Int { saved.count }
    var deletedCount: Int { deleted.count }

    func throwIfFailed() throws {
        if let error = failures.values.first { throw error }
    }
}

struct CloudKitOperationStats: Equatable {
    var requestCount = 0
    var batchCount = 0
    var retryCount = 0
    var retryWaitSeconds: TimeInterval = 0
    var deferredCount = 0

    mutating func add(_ other: CloudKitOperationStats) {
        requestCount += other.requestCount
        batchCount += other.batchCount
        retryCount += other.retryCount
        retryWaitSeconds += other.retryWaitSeconds
        deferredCount += other.deferredCount
    }
}
