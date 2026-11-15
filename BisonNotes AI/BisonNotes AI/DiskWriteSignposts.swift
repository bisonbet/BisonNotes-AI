//
//  DiskWriteSignposts.swift
//  BisonNotes AI
//
//  Attributes the app's disk writes to the work that caused them.
//
//  iOS raised disk-write exceptions for this app at 1–4 GB a day. The
//  diagnostic stacks show Core Data/SQLite saves, Core ML model compilation and
//  plain file writes, but no app frames, so they cannot say which feature did
//  the writing. MetricKit can: every interval marked with `mxSignpost` is
//  reported in the next daily `MXMetricPayload` with its cumulative logical
//  writes. `DiskWriteMetricsLog` records those reports so a diagnostic export
//  shows the breakdown.
//

import Foundation
import MetricKit
import os

/// The work suspected of the large writes. Each is one MetricKit signpost name.
enum DiskWritePhase: Sendable, CaseIterable {
    case transcription
    case asrModelLoad
    case speakerLabels
    case summarization
    case transcriptCleanup
    case cloudSync
    case recordingMerge
    /// From recording intent to stop, including interruption recovery.
    case recording
    case audioImport
    case watchTransfer
    /// Parakeet, speaker-label, Transcript Cleanup and on-device summary models.
    case modelDownload
    /// Loading an on-device MLX summary model.
    case mlxModelLoad
    /// Every `CoreDataManager` save. Nested inside the other phases, so it
    /// measures the SQLite share of their writes rather than adding to them.
    case coreDataSave
    /// The first minute after launch.
    case launchWindow

    /// `mxSignpost` takes a `StaticString`, so the names are spelled out here.
    var signpostName: StaticString {
        switch self {
        case .transcription: return "Transcription"
        case .asrModelLoad: return "ASRModelLoad"
        case .speakerLabels: return "SpeakerLabels"
        case .summarization: return "Summarization"
        case .transcriptCleanup: return "TranscriptCleanup"
        case .cloudSync: return "CloudSync"
        case .recordingMerge: return "RecordingMerge"
        case .recording: return "Recording"
        case .audioImport: return "AudioImport"
        case .watchTransfer: return "WatchTransfer"
        case .modelDownload: return "ModelDownload"
        case .mlxModelLoad: return "MLXModelLoad"
        case .coreDataSave: return "CoreDataSave"
        case .launchWindow: return "LaunchWindow"
        }
    }
}

/// Begin/end markers rather than a closure wrapper, so a call site keeps its own
/// actor isolation: `let s = DiskWriteSignposts.begin(.x); defer { DiskWriteSignposts.end(s) }`.
enum DiskWriteSignposts {
    static let category = "DiskWrites"

    /// Unchecked because `OSSignpostID` is a plain value with no Sendable
    /// annotation; an interval is ended once, from wherever it was handed.
    struct Interval: @unchecked Sendable {
        fileprivate let phase: DiskWritePhase
        fileprivate let id: OSSignpostID
    }

    // `OSLog` is Sendable; it is created once and only read afterwards.
    private static let log = MXMetricManager.makeLogHandle(category: category)

    static func begin(_ phase: DiskWritePhase) -> Interval {
        let id = OSSignpostID(log: log)
        mxSignpost(.begin, log: log, name: phase.signpostName, signpostID: id)
        return Interval(phase: phase, id: id)
    }

    static func end(_ interval: Interval) {
        mxSignpost(.end, log: log, name: interval.phase.signpostName, signpostID: interval.id)
    }
}

/// Keeps one line per daily MetricKit metric report: the day's total logical
/// writes, then each `DiskWrites` signpost's count and writes.
enum DiskWriteMetricsLog {
    private static var file: PersistentLogFile {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PersistentLogFile(
            url: directory.appendingPathComponent("disk_write_metrics_log.txt"),
            maxLines: 60,
            maxBytes: 64 * 1024
        )
    }

    static func record(_ payload: MXMetricPayload) {
        // iOS also delivers empty, zero-length reports on some launches. They
        // carry no disk metrics and only cluttered the export with `n/a` lines.
        let hasSignposts = payload.signpostMetrics?.contains {
            $0.signpostCategory == DiskWriteSignposts.category
        } == true
        guard payload.diskIOMetrics != nil || hasSignposts else { return }
        let line = summary(of: payload)
        file.append(LogTrimPolicy.clamp(line, maxBytes: 4 * 1024))
        AppLog.shared.info("MetricKit daily metrics: \(line)", category: .general)
    }

    static func exportText() -> String {
        let text = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        guard !text.isEmpty else {
            return "No MetricKit metric reports yet. iOS delivers one about once a day."
        }
        // Intervals nest, so their writes overlap rather than add up.
        return "Phases overlap: ASRModelLoad and SpeakerLabels run inside Transcription, "
            + "and CoreDataSave inside every other phase.\n" + text
    }

    static func summary(of payload: MXMetricPayload) -> String {
        let iso = ISO8601DateFormatter()
        var parts = [
            "[\(iso.string(from: payload.timeStampEnd))]",
            "window=\(iso.string(from: payload.timeStampBegin))..\(iso.string(from: payload.timeStampEnd))",
            "app=\(payload.latestApplicationVersion)",
            "writes=\(megabytes(payload.diskIOMetrics?.cumulativeLogicalWrites))"
        ]
        let signposts = (payload.signpostMetrics ?? [])
            .filter { $0.signpostCategory == DiskWriteSignposts.category }
            .sorted { $0.signpostName < $1.signpostName }
        for metric in signposts {
            let writes = megabytes(metric.signpostIntervalData?.cumulativeLogicalWrites)
            parts.append("\(metric.signpostName)[n=\(metric.totalCount) writes=\(writes)]")
        }
        return parts.joined(separator: " ")
    }

    private static func megabytes(_ measurement: Measurement<UnitInformationStorage>?) -> String {
        guard let measurement else { return "n/a" }
        let value = measurement.converted(to: .megabytes).value
        return String(format: "%.1fMB", value)
    }
}
