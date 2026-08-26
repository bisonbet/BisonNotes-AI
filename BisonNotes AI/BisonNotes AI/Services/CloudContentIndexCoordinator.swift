//
//  CloudContentIndexCoordinator.swift
//  BisonNotes AI
//
//  `content_index` is one record that every device writes. Reading it, replacing
//  its arrays wholesale, and saving it is what produced the oplock conflicts in
//  the field: two devices that each added one item would each erase the other's.
//
//  Every routine mutation is therefore expressed as a delta — the names this run
//  added and the names it removed — and a conflict is resolved by reapplying that
//  delta on top of the server's current arrays. Unrelated entries another device
//  wrote survive, and a removal always beats a concurrent add of the same id
//  because a removal means a tombstone exists.
//

import CloudKit
import Foundation

// MARK: - Manifest

/// The record names the manifest currently claims are live in the cloud.
struct CloudActiveManifest: Equatable {
    var recordings: Set<String> = []
    var transcripts: Set<String> = []
    var summaries: Set<String> = []

    var isEmpty: Bool { recordings.isEmpty && transcripts.isEmpty && summaries.isEmpty }
    var totalCount: Int { recordings.count + transcripts.count + summaries.count }

    var allRecordNames: [String] {
        Array(recordings).sorted() + Array(transcripts).sorted() + Array(summaries).sorted()
    }
}

struct ManifestDelta: Equatable {
    var addRecordings: Set<String> = []
    var removeRecordings: Set<String> = []
    var addTranscripts: Set<String> = []
    var removeTranscripts: Set<String> = []
    var addSummaries: Set<String> = []
    var removeSummaries: Set<String> = []

    var isEmpty: Bool {
        addRecordings.isEmpty && removeRecordings.isEmpty &&
        addTranscripts.isEmpty && removeTranscripts.isEmpty &&
        addSummaries.isEmpty && removeSummaries.isEmpty
    }

    static func adding(
        recordings: Set<String> = [],
        transcripts: Set<String> = [],
        summaries: Set<String> = []
    ) -> ManifestDelta {
        ManifestDelta(addRecordings: recordings, addTranscripts: transcripts, addSummaries: summaries)
    }

    static func removing(
        recordings: Set<String> = [],
        transcripts: Set<String> = [],
        summaries: Set<String> = []
    ) -> ManifestDelta {
        ManifestDelta(
            removeRecordings: recordings,
            removeTranscripts: transcripts,
            removeSummaries: summaries
        )
    }

    /// Combines two deltas. A removal in either delta wins over an add in either,
    /// because the removal reflects content that is already gone from CloudKit.
    func merged(with other: ManifestDelta) -> ManifestDelta {
        func combine(
            _ addA: Set<String>, _ removeA: Set<String>,
            _ addB: Set<String>, _ removeB: Set<String>
        ) -> (add: Set<String>, remove: Set<String>) {
            let removes = removeA.union(removeB)
            return (addA.union(addB).subtracting(removes), removes)
        }

        let recordings = combine(addRecordings, removeRecordings, other.addRecordings, other.removeRecordings)
        let transcripts = combine(addTranscripts, removeTranscripts, other.addTranscripts, other.removeTranscripts)
        let summaries = combine(addSummaries, removeSummaries, other.addSummaries, other.removeSummaries)

        return ManifestDelta(
            addRecordings: recordings.add,
            removeRecordings: recordings.remove,
            addTranscripts: transcripts.add,
            removeTranscripts: transcripts.remove,
            addSummaries: summaries.add,
            removeSummaries: summaries.remove
        )
    }

    /// Reapplies this delta on top of whatever the manifest holds now — the
    /// server's copy after a conflict, or the local read on the first try.
    func applied(to manifest: CloudActiveManifest) -> CloudActiveManifest {
        CloudActiveManifest(
            recordings: manifest.recordings.union(addRecordings).subtracting(removeRecordings),
            transcripts: manifest.transcripts.union(addTranscripts).subtracting(removeTranscripts),
            summaries: manifest.summaries.union(addSummaries).subtracting(removeSummaries)
        )
    }
}

// MARK: - Coordinator

@MainActor
final class CloudContentIndexCoordinator {
    struct Configuration {
        var recordType: String
        var recordName: String
        var recordingNamesField: String
        var transcriptNamesField: String
        var summaryNamesField: String
        var schemaVersionField: String
        var manifestSchemaVersionField: String
        var updatedAtField: String
        var deviceIdentifierField: String
        var backupSchemaVersion: Int
        var manifestSchemaVersion: Int
    }

    enum CoordinatorError: Error {
        case conflictRetriesExhausted
        case saveFailed(any Error)
    }

    private let executor: CloudKitBatchExecutor
    private let configuration: Configuration
    private let deviceIdentifier: String
    private let clock: any CloudSyncClock
    private let maxConflictRetries: Int

    /// Serializes writes. A second `apply` while one is in flight merges into the
    /// follow-up rather than racing it, so the index is never written twice at once.
    private var writeChain: Task<CloudActiveManifest, any Error>?
    private var queuedDelta: ManifestDelta?

    init(
        executor: CloudKitBatchExecutor,
        configuration: Configuration,
        deviceIdentifier: String,
        clock: any CloudSyncClock,
        maxConflictRetries: Int = 3
    ) {
        self.executor = executor
        self.configuration = configuration
        self.deviceIdentifier = deviceIdentifier
        self.clock = clock
        self.maxConflictRetries = maxConflictRetries
    }

    private var recordID: CKRecord.ID { CKRecord.ID(recordName: configuration.recordName) }

    // MARK: Reading

    /// The manifest, but only when it carries the current schema version. An older
    /// manifest is not trustworthy enough to drive a known-ID fetch.
    func fetchTrustedManifest() async throws -> CloudActiveManifest {
        try await fetchManifestState().manifest
    }

    /// The manifest and whether it can be trusted.
    ///
    /// The two are not the same question. An untrusted manifest yields an empty
    /// list, and a caller that cannot tell that apart from "the cloud holds
    /// nothing" will look up only the ids it already knows and never discover
    /// what is up there.
    func fetchManifestState() async throws -> (manifest: CloudActiveManifest, isTrusted: Bool) {
        guard let record = try await fetchIndexRecord() else {
            return (CloudActiveManifest(), false)
        }
        guard isTrusted(record) else {
            return (CloudActiveManifest(), false)
        }
        return (manifest(from: record), true)
    }

    func fetchIndexRecord() async throws -> CKRecord? {
        let outcome = try await executor.fetch([recordID])
        try outcome.throwIfIncomplete()
        return outcome.records[recordID]
    }

    func isTrusted(_ record: CKRecord) -> Bool {
        let version = record[configuration.manifestSchemaVersionField] as? Int
            ?? (record[configuration.manifestSchemaVersionField] as? NSNumber)?.intValue
            ?? 0
        return version >= configuration.manifestSchemaVersion
    }

    // MARK: Writing

    @discardableResult
    func apply(_ delta: ManifestDelta) async throws -> CloudActiveManifest {
        guard !delta.isEmpty else {
            return try await fetchTrustedManifest()
        }

        queuedDelta = (queuedDelta ?? ManifestDelta()).merged(with: delta)

        while true {
            if let running = writeChain {
                // Wait for the in-flight write rather than starting a second one.
                // Our delta is already queued, so it either rode along or runs next.
                _ = try? await running.value
                // Awaiting a finished task can return without suspending, and the
                // writer clears `writeChain` from its own continuation, so yield
                // rather than spinning the main actor.
                await Task.yield()
                continue
            }
            guard let pending = queuedDelta else {
                // Another caller's write carried this delta out.
                return try await fetchTrustedManifest()
            }
            queuedDelta = nil
            return try await runWrite(pending)
        }
    }

    /// Full replacement. Only correct during explicit repair or migration, where a
    /// single device is the authority for the whole manifest.
    @discardableResult
    func replace(with manifest: CloudActiveManifest) async throws -> CloudActiveManifest {
        while let running = writeChain {
            _ = try? await running.value
        }
        let task = Task { @MainActor [weak self] () throws -> CloudActiveManifest in
            guard let self else { return manifest }
            return try await self.write(manifest, rebasing: nil)
        }
        writeChain = task
        defer { writeChain = nil }
        return try await task.value
    }

    private func runWrite(_ delta: ManifestDelta) async throws -> CloudActiveManifest {
        let task = Task { @MainActor [weak self] () throws -> CloudActiveManifest in
            guard let self else { return CloudActiveManifest() }
            // An untrusted (older-schema) manifest is still the only record of what
            // the cloud holds, so a delta rebases onto it rather than discarding it.
            let current = try await self.fetchIndexRecord().map(self.manifest(from:)) ?? CloudActiveManifest()
            return try await self.write(delta.applied(to: current), rebasing: delta)
        }
        writeChain = task
        defer { writeChain = nil }
        return try await task.value
    }

    private func write(
        _ manifest: CloudActiveManifest,
        rebasing delta: ManifestDelta?
    ) async throws -> CloudActiveManifest {
        var desired = manifest
        var pendingRecord: CKRecord?
        var attempt = 0

        while true {
            let record: CKRecord
            if let pendingRecord {
                record = pendingRecord
            } else if let existing = try await fetchIndexRecord() {
                record = existing
            } else {
                record = CKRecord(recordType: configuration.recordType, recordID: recordID)
            }
            write(desired, into: record)

            let outcome = try await executor.save([record])
            if outcome.saved[recordID] != nil {
                return desired
            }
            if let serverRecord = outcome.conflicts[recordID] {
                attempt += 1
                guard attempt <= maxConflictRetries else { throw CoordinatorError.conflictRetriesExhausted }
                // Another device wrote between our read and our save. Its record —
                // change tag included — is the base for the retry, so unrelated
                // entries it added survive and only this run's delta is reapplied.
                pendingRecord = serverRecord
                if let delta {
                    desired = delta.applied(to: self.manifest(from: serverRecord))
                }
                continue
            }
            if let failure = outcome.failures[recordID] {
                throw CoordinatorError.saveFailed(failure)
            }
            if outcome.deferred.contains(recordID) {
                // CloudKit asked us to back off. The manifest keeps its previous
                // contents; the caller's next run reapplies the same delta.
                return try await fetchTrustedManifest()
            }
            return desired
        }
    }

    // MARK: Record mapping

    private func manifest(from record: CKRecord) -> CloudActiveManifest {
        CloudActiveManifest(
            recordings: Set(record[configuration.recordingNamesField] as? [String] ?? []),
            transcripts: Set(record[configuration.transcriptNamesField] as? [String] ?? []),
            summaries: Set(record[configuration.summaryNamesField] as? [String] ?? [])
        )
    }

    private func write(_ manifest: CloudActiveManifest, into record: CKRecord) {
        record[configuration.recordingNamesField] = Array(manifest.recordings).sorted() as NSArray
        record[configuration.transcriptNamesField] = Array(manifest.transcripts).sorted() as NSArray
        record[configuration.summaryNamesField] = Array(manifest.summaries).sorted() as NSArray
        record[configuration.schemaVersionField] = configuration.backupSchemaVersion
        record[configuration.manifestSchemaVersionField] = configuration.manifestSchemaVersion
        record[configuration.updatedAtField] = clock.now
        record[configuration.deviceIdentifierField] = deviceIdentifier
    }
}
