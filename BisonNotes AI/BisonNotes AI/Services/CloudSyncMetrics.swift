//
//  CloudSyncMetrics.swift
//  BisonNotes AI
//
//  What a sync run cost, in a shape that can be logged safely. Every field is a
//  count, a duration, or a value from a fixed enum — there is deliberately no way
//  to put a recording name, a filename, an Apple account identifier, or a line of
//  transcript text into a report.
//

import Foundation

// MARK: - Vocabulary

/// The phase barrier every content-changing operation preserves, in order.
enum CloudSyncPhase: String, CaseIterable, Sendable {
    case flushOutboundTombstones
    case applyInboundTombstones
    case fetchCloudSnapshot
    case resolveWinners
    case writeContent
    case applyCloudWinners
    case commitManifest
    case pruneDuplicates
}

/// Why a run started. A closed set, so no caller-supplied text reaches the log.
enum CloudSyncReason: String, CaseIterable, Sendable {
    case appLaunch
    case appBecameActive
    case localChange
    case userDeletion
    case networkRestored
    case periodicHealthCheck
    /// A run re-entered because a server-requested backoff window has expired.
    case deferredRetry
    case manualBackup
    case manualRestore
    case databaseRepair
    case reviewRestore
    case reviewScan
    case legacyMigration
    case erase
    case migrationTool
}

enum CloudSyncRunResultKind: String, Sendable {
    case succeeded
    case failed
    case deferred
    case skippedNoChanges
    case coalesced
}

// MARK: - Report

struct CloudSyncRunReport: Equatable, Sendable {
    var runIdentifier: String
    var reason: CloudSyncReason
    var intent: CloudSyncIntent
    var result: CloudSyncRunResultKind = .succeeded
    /// How long the request waited for the coordinator before any work began.
    var queueDelaySeconds: TimeInterval = 0
    var totalSeconds: TimeInterval = 0
    var phaseSeconds: [CloudSyncPhase: TimeInterval] = [:]
    var phaseOrder: [CloudSyncPhase] = []

    var requestCount = 0
    var batchCount = 0
    var retryCount = 0
    var retryWaitSeconds: TimeInterval = 0
    var deferredItemCount = 0
    var deferredUntil: Date?

    var recordsFetched = 0
    var recordsSaved = 0
    var recordsDeleted = 0
    var recordsFailed = 0
    var conflictCount = 0

    var audioFilesUploaded = 0
    var audioBytesUploaded: Int64 = 0
    var audioSeconds: TimeInterval = 0

    /// Log line for `AppLog`. Counts only — see the file comment.
    var logDescription: String {
        var parts: [String] = [
            "run=\(runIdentifier)",
            "reason=\(reason.rawValue)",
            "intent=\(intent.rawValue)",
            "result=\(result.rawValue)",
            String(format: "queue=%.2fs", queueDelaySeconds),
            String(format: "total=%.2fs", totalSeconds),
            "requests=\(requestCount)",
            "batches=\(batchCount)",
            "fetched=\(recordsFetched)",
            "saved=\(recordsSaved)",
            "deleted=\(recordsDeleted)",
            "failed=\(recordsFailed)",
            "conflicts=\(conflictCount)",
            "retries=\(retryCount)",
            String(format: "retryWait=%.2fs", retryWaitSeconds)
        ]
        if deferredItemCount > 0 {
            parts.append("deferredItems=\(deferredItemCount)")
        }
        if let deferredUntil {
            parts.append(String(format: "deferredFor=%.0fs", deferredUntil.timeIntervalSinceNow))
        }
        let phases = phaseOrder.map { phase in
            String(format: "%@=%.2fs", phase.rawValue, phaseSeconds[phase] ?? 0)
        }
        if !phases.isEmpty {
            parts.append("phases[\(phases.joined(separator: " "))]")
        }
        return parts.joined(separator: " ")
    }

    /// Audio is reported on its own line so it can never be mistaken for metadata
    /// latency when a run is judged against the performance gates.
    var audioLogDescription: String? {
        guard audioFilesUploaded > 0 || audioBytesUploaded > 0 else { return nil }
        let megabytes = Double(audioBytesUploaded) / 1_048_576
        let throughput = totalSeconds > 0 ? megabytes / totalSeconds : 0
        return String(
            format: "run=%@ audioFiles=%d audioMB=%.2f audioSeconds=%.1f throughputMBps=%.2f",
            runIdentifier, audioFilesUploaded, megabytes, audioSeconds, throughput
        )
    }
}

// MARK: - Sink

@MainActor
protocol CloudSyncMetricsSink: AnyObject {
    func record(_ report: CloudSyncRunReport)
}

@MainActor
final class CloudSyncLogMetricsSink: CloudSyncMetricsSink {
    func record(_ report: CloudSyncRunReport) {
        AppLog.shared.iCloudSync("Sync metrics \(report.logDescription)", level: .debug)
        if let audio = report.audioLogDescription {
            AppLog.shared.iCloudSync("Sync audio \(audio)", level: .debug)
        }
    }
}

// MARK: - Recorder

/// Accumulates one run's timings and counts. Phase timing uses the monotonic
/// clock so a wall-clock adjustment mid-sync cannot invent or erase seconds.
@MainActor
final class CloudSyncRunRecorder {
    private let clock: any CloudSyncClock
    private let sink: (any CloudSyncMetricsSink)?
    private let startedAt: TimeInterval
    private var openPhase: (phase: CloudSyncPhase, startedAt: TimeInterval)?
    private var report: CloudSyncRunReport
    private var finished = false

    init(
        reason: CloudSyncReason,
        intent: CloudSyncIntent,
        queueDelaySeconds: TimeInterval = 0,
        clock: any CloudSyncClock,
        sink: (any CloudSyncMetricsSink)?,
        runIdentifier: String = UUID().uuidString.prefix(8).lowercased()
    ) {
        self.clock = clock
        self.sink = sink
        self.startedAt = clock.monotonicSeconds
        self.report = CloudSyncRunReport(
            runIdentifier: runIdentifier,
            reason: reason,
            intent: intent,
            queueDelaySeconds: queueDelaySeconds
        )
    }

    var runIdentifier: String { report.runIdentifier }
    var phaseOrder: [CloudSyncPhase] { report.phaseOrder }
    var currentReport: CloudSyncRunReport { report }

    func begin(_ phase: CloudSyncPhase) {
        endOpenPhase()
        report.phaseOrder.append(phase)
        openPhase = (phase, clock.monotonicSeconds)
    }

    func endPhase() {
        endOpenPhase()
    }

    private func endOpenPhase() {
        guard let open = openPhase else { return }
        let elapsed = clock.monotonicSeconds - open.startedAt
        report.phaseSeconds[open.phase, default: 0] += elapsed
        openPhase = nil
    }

    /// Folds one executor call's cost into the run.
    func add(_ stats: CloudKitOperationStats) {
        report.requestCount += stats.requestCount
        report.batchCount += stats.batchCount
        report.retryCount += stats.retryCount
        report.retryWaitSeconds += stats.retryWaitSeconds
        report.deferredItemCount += stats.deferredCount
    }

    func add(fetch outcome: CloudKitFetchOutcome) {
        add(outcome.stats)
        report.recordsFetched += outcome.records.count
        report.recordsFailed += outcome.failures.count
        if let until = outcome.deferredUntil {
            report.deferredUntil = until
        }
    }

    func add(modify outcome: CloudKitModifyOutcome) {
        add(outcome.stats)
        report.recordsSaved += outcome.saved.count
        report.recordsDeleted += outcome.deleted.count
        report.recordsFailed += outcome.failures.count
        report.conflictCount += outcome.conflicts.count
        if let until = outcome.deferredUntil {
            report.deferredUntil = until
        }
    }

    func addAudio(fileCount: Int, byteCount: Int64, seconds: TimeInterval) {
        report.audioFilesUploaded += fileCount
        report.audioBytesUploaded += byteCount
        report.audioSeconds += seconds
    }

    @discardableResult
    func finish(_ result: CloudSyncRunResultKind) -> CloudSyncRunReport {
        guard !finished else { return report }
        finished = true
        endOpenPhase()
        report.result = result
        report.totalSeconds = clock.monotonicSeconds - startedAt
        sink?.record(report)
        return report
    }
}
