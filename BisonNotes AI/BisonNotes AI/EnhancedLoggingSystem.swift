//
//  EnhancedLoggingSystem.swift
//  BisonNotes AI
//
//  Always-on logging via Apple's Unified Logging System (OSLog).
//  Zero overhead in production — the OS handles persistence, compression, and pruning.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
import os
import os.log
import AVFoundation

// MARK: - Log Categories

enum LogCategory: String, CaseIterable, Sendable {
    case audioSession = "AudioSession"
    case recording = "Recording"
    case transcription = "Transcription"
    case summarization = "Summarization"
    case chunking = "Chunking"
    case backgroundProcessing = "BackgroundProcessing"
    case iCloudSync = "iCloudSync"
    case fileManagement = "FileManagement"
    case dataMigration = "DataMigration"
    case networking = "Networking"
    case watchConnectivity = "WatchConnectivity"
    case coreData = "CoreData"
    case performance = "Performance"
    case errorRecovery = "ErrorRecovery"
    case general = "General"
}

// MARK: - Persisted Log Budgets

/// Budget rules for the rolling files that survive a crash.
///
/// A line-count cap alone does not bound a log file. A single message can be a
/// model response, a decoded payload, or a CloudKit error description, and one
/// 350 KB line was enough to push a 500-line error log past 4 MB — which then
/// cost a 4 MB read and a 4 MB rewrite on *every* subsequent log call. So each
/// line is clamped first and the file carries a byte ceiling as well.
///
/// Pure so the budgets can be tested without touching the filesystem.
enum LogTrimPolicy {
    /// Clamps one line so a single huge message cannot consume the whole budget.
    /// Keeps the head, which is where the message and the first frames live.
    static func clamp(_ line: String, maxBytes: Int) -> String {
        let flattened = line.replacingOccurrences(of: "\n", with: "⏎")
        guard flattened.utf8.count > maxBytes else { return flattened }

        let marker = "…[truncated]"
        let budget = max(0, maxBytes - marker.utf8.count)
        var kept = String()
        var used = 0
        for character in flattened {
            let width = String(character).utf8.count
            if used + width > budget { break }
            kept.append(character)
            used += width
        }
        return kept + marker
    }

    /// Drops the oldest lines until the joined text fits both budgets.
    /// Always keeps at least the newest line, so a log call is never a no-op.
    static func trim(lines: [String], maxLines: Int, maxBytes: Int) -> [String] {
        var kept = lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
        var total = kept.reduce(0) { $0 + $1.utf8.count + 1 }
        var firstKept = 0
        while total > maxBytes, firstKept < kept.count - 1 {
            total -= kept[firstKept].utf8.count + 1
            firstKept += 1
        }
        if firstKept > 0 { kept = Array(kept.dropFirst(firstKept)) }
        return kept
    }
}

// MARK: - Rolling Log File

/// One rolling file that survives a crash.
///
/// Split out of `AppLog` so the append-and-compact behavior can be exercised
/// against a real file. The budgets in `LogTrimPolicy` are pure and were already
/// covered, but they cannot catch a file handle opened in the wrong mode — which
/// is exactly the defect this type was extracted to make testable.
struct PersistentLogFile: Sendable {
    let url: URL
    let maxLines: Int
    let maxBytes: Int
    /// Compaction rewrites the file, so it must not run on every line. Appending is
    /// cheap; the rewrite happens only once the file crosses its ceiling, and then
    /// takes it well under, leaving room for many more appends before the next one.
    var compactionTargetFraction = 0.75

    /// Appends one already-clamped line, compacting only once the file is over budget.
    func append(_ line: String) {
        guard let sizeAfterAppend = appendToExistingFile(line) else {
            // No file yet, or it was removed under us — create it.
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
            AppFileProtection.apply(to: url)
            return
        }

        guard sizeAfterAppend > UInt64(maxBytes) else { return }
        compact(toByteBudget: Int(Double(maxBytes) * compactionTargetFraction))
    }

    /// Appends and returns the file's new size, or `nil` when there is no file to
    /// append to so `append` can create one.
    ///
    /// Two things here are easy to get wrong, and both were:
    ///
    /// The handle is opened for *updating* rather than writing, because the
    /// separator check reads a byte and a write-only descriptor fails that read
    /// with EBADF. When it did, this reported failure and `append` replaced the
    /// whole log with the single newest line, losing all history on every call.
    ///
    /// The new size comes from the handle rather than `URL.resourceValues`, which
    /// caches the first value it reads for the lifetime of the `URL`. `AppLog`
    /// holds one URL per log for the whole process, so a cached size froze at
    /// whatever the file measured first and the byte ceiling never fired.
    ///
    /// Files written by earlier versions end without a trailing newline, so the
    /// separator is added when the existing content lacks one; otherwise the first
    /// append after an upgrade would run onto the end of the last line.
    private func appendToExistingFile(_ line: String) -> UInt64? {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            var needsSeparator = false
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                needsSeparator = try handle.read(upToCount: 1) != Data([0x0A])
                try handle.seek(toOffset: end)
            }
            guard let data = ((needsSeparator ? "\n" : "") + line + "\n").data(using: .utf8) else {
                return end
            }
            try handle.write(contentsOf: data)
            return try handle.offset()
        } catch {
            return nil
        }
    }

    private func compact(toByteBudget budget: Int) {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = existing.components(separatedBy: "\n").filter { !$0.isEmpty }
        let kept = LogTrimPolicy.trim(lines: lines, maxLines: maxLines, maxBytes: budget)
        try? (kept.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        AppFileProtection.apply(to: url)
    }
}

// MARK: - App Logger

final class AppLog: Sendable {
    static let shared = AppLog()

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.bisonnotes.app"

    private let loggers: [LogCategory: os.Logger]

    private init() {
        var map = [LogCategory: os.Logger]()
        for cat in LogCategory.allCases {
            map[cat] = os.Logger(subsystem: AppLog.subsystem, category: cat.rawValue)
        }
        loggers = map
    }

    // MARK: - Persistent Log Buffer

    /// Rolling file that persists .error and .fault messages across crashes.
    /// Kept small (last 500 lines) so it doesn't bloat device storage.
    private let persistentLogURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("persistent_error_log.txt")
    }()

    /// Rolling breadcrumb log that persists recent app activity across crashes.
    /// This intentionally stores all levels, but keeps only a small tail so a
    /// post-crash export has useful previous-process context without growing forever.
    private let persistentBreadcrumbURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("persistent_breadcrumb_log.txt")
    }()

    private let bufferQueue = DispatchQueue(label: "com.bisonnotes.logbuffer", qos: .utility)
    private static let maxBufferLines = 500
    private static let maxBreadcrumbLines = 750
    /// Byte ceilings. See ``LogTrimPolicy`` for why the line counts above are not
    /// enough on their own. Sized so a full export stays small enough to email.
    private static let maxErrorLogBytes = 512 * 1024
    private static let maxBreadcrumbLogBytes = 256 * 1024
    private static let maxPersistedLineBytes = 8 * 1024
    private static let cleanShutdownKey = "AppLog_CleanShutdown"
    private let sessionId = UUID().uuidString
    private struct LifecycleState {
        var previousSessionCrashed = false
        var launchWasMarked = false
    }
    private let lifecycleState = OSAllocatedUnfairLock(initialState: LifecycleState())

    /// Captured once at launch before the shutdown marker is reset. This
    /// diagnostic fact remains stable for the lifetime of the process.
    var previousSessionCrashed: Bool {
        lifecycleState.withLock { $0.previousSessionCrashed }
    }

    /// Call on app launch. Reads the previous session's shutdown state, then resets the flag.
    /// Must be called before anything checks `previousSessionCrashed`.
    func markLaunch() {
        let shouldMarkLaunch = lifecycleState.withLock { state -> Bool in
            guard !state.launchWasMarked else { return false }
            state.launchWasMarked = true

            // On very first install the key doesn't exist — UserDefaults returns false,
            // which would look like a crash. Treat missing key as clean.
            let hasKey = UserDefaults.standard.object(forKey: Self.cleanShutdownKey) != nil
            state.previousSessionCrashed = hasKey && !UserDefaults.standard.bool(forKey: Self.cleanShutdownKey)
            return true
        }
        guard shouldMarkLaunch else { return }

        // Reset for this session — if we crash, it stays false
        UserDefaults.standard.set(false, forKey: Self.cleanShutdownKey)

        lifecycleBreadcrumb("launch session=\(sessionId) previousSessionCrashed=\(previousSessionCrashed)")
    }

    /// Call when app becomes active. A later foreground crash should not inherit a
    /// previous clean background transition from the same launch.
    func markSessionActive() {
        UserDefaults.standard.set(false, forKey: Self.cleanShutdownKey)
        lifecycleBreadcrumb("active session=\(sessionId)")
    }

    /// Call when app enters background or terminates — marks this session as clean.
    func markCleanShutdown() {
        UserDefaults.standard.set(true, forKey: Self.cleanShutdownKey)
        lifecycleBreadcrumb("clean-shutdown-marker session=\(sessionId)")
    }

    /// Returns the contents of the persistent error log (survives crashes).
    func persistedErrorLog() -> String {
        (try? String(contentsOf: persistentLogURL, encoding: .utf8)) ?? ""
    }

    /// Returns recent app breadcrumbs from the current and previous process.
    func persistedBreadcrumbLog() -> String {
        (try? String(contentsOf: persistentBreadcrumbURL, encoding: .utf8)) ?? ""
    }

    private func persistLine(_ line: String, to file: PersistentLogFile) {
        let clamped = LogTrimPolicy.clamp(line, maxBytes: Self.maxPersistedLineBytes)
        bufferQueue.async { file.append(clamped) }
    }

    private func persistErrorLine(_ line: String) {
        persistLine(line, to: PersistentLogFile(
            url: persistentLogURL,
            maxLines: Self.maxBufferLines,
            maxBytes: Self.maxErrorLogBytes
        ))
    }

    private func persistBreadcrumbLine(_ line: String) {
        persistLine(line, to: PersistentLogFile(
            url: persistentBreadcrumbURL,
            maxLines: Self.maxBreadcrumbLines,
            maxBytes: Self.maxBreadcrumbLogBytes
        ))
    }

    private func lifecycleBreadcrumb(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        persistBreadcrumbLine("[\(timestamp)] [LIFECYCLE] [General] \(message)")
    }

    // MARK: - Core Logging

    func log(_ message: String, level: OSLogType = .info, category: LogCategory = .general) {
        guard let logger = loggers[category] else { return }
        switch level {
        case .error:   logger.error("\(message, privacy: .public)")
        case .fault:   logger.fault("\(message, privacy: .public)")
        case .debug:   logger.debug("\(message, privacy: .public)")
        case .info:    logger.info("\(message, privacy: .public)")
        default:       logger.notice("\(message, privacy: .public)")
        }

        // Persist .error and .fault to rolling buffer file (survives crashes)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let levelStr = Self.levelString(level)
        persistBreadcrumbLine("[\(timestamp)] [\(levelStr)] [\(category.rawValue)] \(message)")

        if level == .error || level == .fault {
            persistErrorLine("[\(timestamp)] [\(levelStr)] [\(category.rawValue)] \(message)")
        }
    }

    private static func levelString(_ level: OSLogType) -> String {
        switch level {
        case .fault:
            return "FAULT"
        case .error:
            return "ERROR"
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        default:
            return "NOTICE"
        }
    }

    // MARK: - Convenience: Level Methods

    func error(_ message: String, category: LogCategory = .general) {
        log(message, level: .error, category: category)
    }

    func warning(_ message: String, category: LogCategory = .general) {
        log(message, level: .error, category: category)
    }

    func info(_ message: String, category: LogCategory = .general) {
        log(message, level: .info, category: category)
    }

    func debug(_ message: String, category: LogCategory = .general) {
        log(message, level: .debug, category: category)
    }

    // MARK: - Convenience: Category Methods

    func general(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .general)
    }

    func audioSession(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .audioSession)
    }

    func recording(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .recording)
    }

    func transcription(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .transcription)
    }

    func summarization(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .summarization)
    }

    func chunking(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .chunking)
    }

    func backgroundProcessing(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .backgroundProcessing)
    }

    func iCloudSync(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .iCloudSync)
    }

    func fileManagement(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .fileManagement)
    }

    func dataMigration(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .dataMigration)
    }

    func networking(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .networking)
    }

    func watchConnectivity(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .watchConnectivity)
    }

    func coreData(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .coreData)
    }

    func performance(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .performance)
    }

    func errorRecovery(_ message: String, level: OSLogType = .info) {
        log(message, level: level, category: .errorRecovery)
    }

    // MARK: - Performance Tracking

    private let performanceMetrics = OSAllocatedUnfairLock(initialState: [String: PerformanceMetric]())

    func startPerformanceTracking(_ operation: String, context: String = "") {
        let metric = PerformanceMetric(
            operation: operation,
            context: context,
            startTime: Date(),
            memoryUsage: Self.currentMemoryUsage
        )
        performanceMetrics.withLock { $0[operation] = metric }
        performance("Started tracking: \(operation)", level: .debug)
    }

    func endPerformanceTracking(_ operation: String) -> PerformanceResult? {
        let result = performanceMetrics.withLock { metrics -> PerformanceResult? in
            guard let metric = metrics.removeValue(forKey: operation) else { return nil }
            let duration = Date().timeIntervalSince(metric.startTime)
            let endMemory = Self.currentMemoryUsage
            return PerformanceResult(
                operation: operation,
                context: metric.context,
                duration: duration,
                memoryUsage: endMemory,
                memoryDelta: endMemory - metric.memoryUsage,
                timestamp: Date()
            )
        }
        if let result {
            performance("Completed: \(operation) in \(String(format: "%.2f", result.duration))s")
        }
        return result
    }

    // MARK: - Diagnostic Info

    static var currentMemoryUsage: Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? Double(info.resident_size) / 1024.0 / 1024.0 : 0.0
    }

    static var freeStorageGB: String {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let free = attrs[.systemFreeSize] as? NSNumber {
                return String(format: "%.1f GB free", Double(truncating: free) / 1024.0 / 1024.0 / 1024.0)
            }
        } catch {}
        return "Unknown"
    }

    @MainActor
    func generateDiagnosticReport() -> DiagnosticReport {
        #if canImport(UIKit)
        let model = UIDevice.current.model
        let systemVersion = UIDevice.current.systemVersion
        #else
        let model = "Mac"
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        return DiagnosticReport(
            timestamp: Date(),
            deviceInfo: DeviceDiagnosticInfo(
                model: model,
                systemVersion: systemVersion,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
                memoryUsage: Self.currentMemoryUsage,
                storageInfo: Self.freeStorageGB
            )
        )
    }
}

// MARK: - Backward Compatibility

// Alias so existing callers of EnhancedLogger.shared continue to compile during migration.
// These will be removed once all callers are migrated.
typealias EnhancedLogger = AppLog
typealias AppLogger = AppLog
typealias EnhancedLogCategory = LogCategory

extension AppLog {
    // Bridge old EnhancedLogger category-specific methods that used LogLevel
    func logAudioSession(_ message: String, level: OSLogType = .info) {
        audioSession(message, level: level)
    }
    func logChunking(_ message: String, level: OSLogType = .info) {
        chunking(message, level: level)
    }
    func logBackgroundProcessing(_ message: String, level: OSLogType = .info) {
        backgroundProcessing(message, level: level)
    }
    func logiCloudSync(_ message: String, level: OSLogType = .info) {
        iCloudSync(message, level: level)
    }
    func logFileManagement(_ message: String, level: OSLogType = .info) {
        fileManagement(message, level: level)
    }
    func logPerformance(_ message: String, level: OSLogType = .info) {
        performance(message, level: level)
    }
    func logErrorRecovery(_ message: String, level: OSLogType = .info) {
        errorRecovery(message, level: level)
    }
    func logDebug(_ message: String, level: OSLogType = .debug) {
        log(message, level: level, category: .general)
    }

    // Bridge old EnhancedLogger structured methods
    #if os(iOS)
    func logAudioSessionConfiguration(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) {
        audioSession("Configuring audio session - Category: \(category), Mode: \(mode), Options: \(options)")
    }
    func logAudioSessionInterruption(_ type: AVAudioSession.InterruptionType) {
        audioSession("Audio interruption: \(type == .began ? "began" : "ended")", level: .error)
    }
    func logAudioSessionRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        audioSession("Audio route change: \(reason)")
    }
    #endif
    func logChunkingStart(_ fileURL: URL, strategy: ChunkingStrategy) {
        chunking("Starting chunking for \(fileURL.lastPathComponent) with strategy: \(strategy)")
    }
    func logChunkingProgress(_ currentChunk: Int, totalChunks: Int, fileURL: URL) {
        chunking("Chunking progress: \(currentChunk)/\(totalChunks) for \(fileURL.lastPathComponent)", level: .debug)
    }
    func logChunkingComplete(_ fileURL: URL, chunkCount: Int) {
        chunking("Chunking complete for \(fileURL.lastPathComponent): \(chunkCount) chunks created")
    }
    func logChunkingError(_ error: Error, fileURL: URL) {
        chunking("Chunking error for \(fileURL.lastPathComponent): \(error.localizedDescription)", level: .error)
    }
    func logBackgroundJobStart(_ job: ProcessingJob) {
        backgroundProcessing("Starting background job: \(job.type.displayName) for \(job.recordingName)")
    }
    func logBackgroundJobProgress(_ job: ProcessingJob, progress: Double) {
        backgroundProcessing("Job progress: \(Int(progress * 100))% for \(job.recordingName)", level: .debug)
    }
    func logBackgroundJobComplete(_ job: ProcessingJob) {
        backgroundProcessing("Background job completed: \(job.type.displayName) for \(job.recordingName)")
    }
    func logBackgroundJobError(_ job: ProcessingJob, error: Error) {
        backgroundProcessing("Background job failed: \(job.type.displayName) for \(job.recordingName) - \(error.localizedDescription)", level: .error)
    }
    func logiCloudSyncStart(_ operation: String) {
        iCloudSync("Starting iCloud sync operation: \(operation)", level: .debug)
    }
    func logiCloudSyncProgress(_ operation: String, progress: Double) {
        iCloudSync("iCloud sync progress: \(Int(progress * 100))% for \(operation)", level: .debug)
    }
    func logiCloudSyncComplete(_ operation: String, itemCount: Int) {
        iCloudSync("iCloud sync completed: \(operation) - \(itemCount) items processed")
    }
    func logiCloudSyncError(_ operation: String, error: Error) {
        iCloudSync("iCloud sync error: \(operation) - \(error.localizedDescription)", level: .error)
    }
    func logFileOperation(_ operation: String, fileURL: URL) {
        fileManagement("File operation: \(operation) on \(fileURL.lastPathComponent)")
    }
    func logFileRelationshipUpdate(_ recordingURL: URL, transcriptExists: Bool, summaryExists: Bool) {
        fileManagement("File relationship updated for \(recordingURL.lastPathComponent) - Transcript: \(transcriptExists), Summary: \(summaryExists)", level: .debug)
    }
    func logFileDeletion(_ fileURL: URL, preserveSummary: Bool) {
        fileManagement("File deletion: \(fileURL.lastPathComponent) (preserve summary: \(preserveSummary))")
    }
    func logErrorRecoveryAttempt(_ error: Error, recoveryAction: String) {
        errorRecovery("Attempting recovery for \(error.localizedDescription): \(recoveryAction)")
    }
    func logErrorRecoverySuccess(_ error: Error, recoveryAction: String) {
        errorRecovery("Recovery successful for \(error.localizedDescription): \(recoveryAction)")
    }
    func logErrorRecoveryFailure(_ error: Error, recoveryAction: String, failureReason: String) {
        errorRecovery("Recovery failed for \(error.localizedDescription): \(recoveryAction) - \(failureReason)", level: .error)
    }

    // Bridge old enablePerformanceTracking — now a no-op (always on)
    func enablePerformanceTracking(_ enabled: Bool) {}

    // Bridge old AppLogger string-based category API.
    // These accept a String category (ignored — routes to .general) for source compatibility
    // while callers are migrated to use LogCategory enum.
    func verbose(_ message: String, category: String = "General") {
        log(message, level: .debug, category: .general)
    }
    func info(_ message: String, category: String) {
        log(message, level: .info, category: .general)
    }
    func warning(_ message: String, category: String) {
        log(message, level: .error, category: .general)
    }
    func error(_ message: String, category: String) {
        log(message, level: .error, category: .general)
    }
}

// MARK: - Supporting Types

struct PerformanceMetric: Sendable {
    let operation: String
    let context: String
    let startTime: Date
    let memoryUsage: Double
}

struct PerformanceResult: Sendable {
    let operation: String
    let context: String
    let duration: TimeInterval
    let memoryUsage: Double
    let memoryDelta: Double
    let timestamp: Date

    var description: String {
        "\(operation) (\(context)): \(String(format: "%.2f", duration))s, Memory: \(String(format: "%.1f", memoryUsage))MB (\(String(format: "%+.1f", memoryDelta))MB)"
    }
}

struct DiagnosticReport: Sendable {
    let timestamp: Date
    let deviceInfo: DeviceDiagnosticInfo

    var formattedReport: String {
        """
        === Diagnostic Report ===
        Timestamp: \(timestamp)

        Device Information:
        - Model: \(deviceInfo.model)
        - iOS Version: \(deviceInfo.systemVersion)
        - App Version: \(deviceInfo.appVersion)
        - Memory Usage: \(String(format: "%.1f", deviceInfo.memoryUsage)) MB
        - Storage: \(deviceInfo.storageInfo)
        """
    }
}

struct DeviceDiagnosticInfo: Sendable {
    let model: String
    let systemVersion: String
    let appVersion: String
    let memoryUsage: Double
    let storageInfo: String
}
