//
//  EnhancedLoggingSystem.swift
//  BisonNotes AI
//
//  Always-on logging via Apple's Unified Logging System (OSLog).
//  Zero overhead in production — the OS handles persistence, compression, and pruning.
//

import Foundation
import UIKit
import os.log
import AVFoundation

// MARK: - Log Categories

enum LogCategory: String, CaseIterable {
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

// MARK: - App Logger

class AppLog {
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

    private let bufferQueue = DispatchQueue(label: "com.bisonnotes.logbuffer", qos: .utility)
    private static let maxBufferLines = 500
    private static let cleanShutdownKey = "AppLog_CleanShutdown"

    /// Captured at launch before the flag is reset so the value survives the whole session.
    private(set) var previousSessionCrashed: Bool = false

    /// Call on app launch. Reads the previous session's shutdown state, then resets the flag.
    /// Must be called before anything checks `previousSessionCrashed`.
    func markLaunch() {
        // On very first install the key doesn't exist — UserDefaults returns false,
        // which would look like a crash. Treat missing key as clean.
        let hasKey = UserDefaults.standard.object(forKey: Self.cleanShutdownKey) != nil
        previousSessionCrashed = hasKey && !UserDefaults.standard.bool(forKey: Self.cleanShutdownKey)
        // Reset for this session — if we crash, it stays false
        UserDefaults.standard.set(false, forKey: Self.cleanShutdownKey)
    }

    /// Call when app enters background or resigns active — marks this session as clean.
    func markCleanShutdown() {
        UserDefaults.standard.set(true, forKey: Self.cleanShutdownKey)
    }

    /// Returns the contents of the persistent error log (survives crashes).
    func persistedErrorLog() -> String {
        (try? String(contentsOf: persistentLogURL, encoding: .utf8)) ?? ""
    }

    private func persistToBuffer(_ line: String) {
        bufferQueue.async { [url = persistentLogURL] in
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var lines = existing.components(separatedBy: "\n").filter { !$0.isEmpty }
            lines.append(line)
            // Keep only the last N lines
            if lines.count > Self.maxBufferLines {
                lines = Array(lines.suffix(Self.maxBufferLines))
            }
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
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
        if level == .error || level == .fault {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let levelStr = level == .fault ? "FAULT" : "ERROR"
            persistToBuffer("[\(timestamp)] [\(levelStr)] [\(category.rawValue)] \(message)")
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

    private var performanceMetrics: [String: PerformanceMetric] = [:]
    private let performanceQueue = DispatchQueue(label: "com.bisonnotes.performance", qos: .utility)

    func startPerformanceTracking(_ operation: String, context: String = "") {
        let metric = PerformanceMetric(
            operation: operation,
            context: context,
            startTime: Date(),
            memoryUsage: Self.currentMemoryUsage
        )
        performanceQueue.async {
            self.performanceMetrics[operation] = metric
        }
        performance("Started tracking: \(operation)", level: .debug)
    }

    func endPerformanceTracking(_ operation: String) -> PerformanceResult? {
        return performanceQueue.sync {
            guard let metric = performanceMetrics.removeValue(forKey: operation) else { return nil }
            let duration = Date().timeIntervalSince(metric.startTime)
            let endMemory = Self.currentMemoryUsage
            let result = PerformanceResult(
                operation: operation,
                context: metric.context,
                duration: duration,
                memoryUsage: endMemory,
                memoryDelta: endMemory - metric.memoryUsage,
                timestamp: Date()
            )
            performance("Completed: \(operation) in \(String(format: "%.2f", duration))s")
            return result
        }
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

    func generateDiagnosticReport() -> DiagnosticReport {
        let device = UIDevice.current
        return DiagnosticReport(
            timestamp: Date(),
            deviceInfo: DeviceDiagnosticInfo(
                model: device.model,
                systemVersion: device.systemVersion,
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
    func logAudioSessionConfiguration(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) {
        audioSession("Configuring audio session - Category: \(category), Mode: \(mode), Options: \(options)")
    }
    func logAudioSessionInterruption(_ type: AVAudioSession.InterruptionType) {
        audioSession("Audio interruption: \(type == .began ? "began" : "ended")", level: .error)
    }
    func logAudioSessionRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        audioSession("Audio route change: \(reason)")
    }
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

struct PerformanceMetric {
    let operation: String
    let context: String
    let startTime: Date
    let memoryUsage: Double
}

struct PerformanceResult {
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

struct DiagnosticReport {
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

struct DeviceDiagnosticInfo {
    let model: String
    let systemVersion: String
    let appVersion: String
    let memoryUsage: Double
    let storageInfo: String
}
