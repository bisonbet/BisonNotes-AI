//
//  EnhancedLoggingSystem.swift
//  Audio Journal
//
//  Comprehensive logging and debugging support for audio processing enhancements
//

import Foundation
import SwiftUI
import os.log
import AVFoundation
import CloudKit

// MARK: - Enhanced Logging Categories

enum EnhancedLogCategory: String, CaseIterable {
    case audioSession = "AudioSession"
    case chunking = "Chunking"
    case backgroundProcessing = "BackgroundProcessing"
    case iCloudSync = "iCloudSync"
    case fileManagement = "FileManagement"
    case performance = "Performance"
    case errorRecovery = "ErrorRecovery"
    case debug = "Debug"
    
    var emoji: String {
        switch self {
        case .audioSession: return "🎤"
        case .chunking: return "✂️"
        case .backgroundProcessing: return "⚙️"
        case .iCloudSync: return "☁️"
        case .fileManagement: return "📁"
        case .performance: return "📊"
        case .errorRecovery: return "🔄"
        case .debug: return "🔍"
        }
    }
}

// MARK: - Enhanced Logger

class EnhancedLogger: ObservableObject {
    static let shared = EnhancedLogger()
    
    private let logger: os.Logger = os.Logger(subsystem: "com.audiojournal.app", category: "EnhancedLogger")
    private var currentLevel: LogLevel = .info
    private var enabledCategories: Set<EnhancedLogCategory> = Set(EnhancedLogCategory.allCases)
    private var debugMode = false
    private var performanceTracking = false
    
    // Public getters for UI access
    var currentLevelValue: LogLevel { currentLevel }
    var enabledCategoriesValue: Set<EnhancedLogCategory> { enabledCategories }
    var debugModeValue: Bool { debugMode }
    var performanceTrackingValue: Bool { performanceTracking }
    
    // Debug configuration
    private var debugConfig = DebugConfiguration()
    
    // Performance tracking
    private var performanceMetrics: [String: PerformanceMetric] = [:]
    private let performanceQueue = DispatchQueue(label: "com.audiojournal.performance", qos: .utility)
    
    private init() {
        // Set default level based on build configuration
        #if DEBUG
        currentLevel = .debug
        debugMode = true
        #else
        currentLevel = .info
        debugMode = false
        #endif
        
        // Load saved debug configuration
        loadDebugConfiguration()
    }
    
    // MARK: - Configuration Methods
    
    func setLogLevel(_ level: LogLevel) {
        currentLevel = level
        os.Logger(subsystem: "com.audiojournal.app", category: "EnhancedLogger").info("🔧 Log level set to: \(level.rawValue)")
    }
    
    func enableCategory(_ category: EnhancedLogCategory) {
        enabledCategories.insert(category)
        logger.debug("🔧 Enabled logging category: \(category.rawValue)")
    }
    
    func disableCategory(_ category: EnhancedLogCategory) {
        enabledCategories.remove(category)
        logger.debug("🔧 Disabled logging category: \(category.rawValue)")
    }
    
    func setDebugMode(_ enabled: Bool) {
        debugMode = enabled
        if enabled {
            setLogLevel(.debug)
            enableAllCategories()
        } else {
            setLogLevel(.info)
            disableDebugCategories()
        }
        logger.info("🔧 Debug mode \(enabled ? "enabled" : "disabled")")
    }
    
    func enablePerformanceTracking(_ enabled: Bool) {
        performanceTracking = enabled
        logger.info("🔧 Performance tracking \(enabled ? "enabled" : "disabled")")
    }
    
    // MARK: - Logging Methods
    
    func log(_ message: String, level: LogLevel = .info, category: EnhancedLogCategory = .debug) {
        guard level.rawValue <= currentLevel.rawValue && enabledCategories.contains(category) else { return }
        
        let formattedMessage = "\(category.emoji) [\(category.rawValue)]: \(message)"
        
        switch level {
        case .error:
            logger.error("\(formattedMessage)")
        case .warning:
            logger.warning("\(formattedMessage)")
        case .info:
            logger.info("\(formattedMessage)")
        case .debug, .verbose:
            logger.debug("\(formattedMessage)")
        }
        
        // Additional debug logging if in debug mode
        if debugMode && level == .debug {
            logDebugInfo(message: message, category: category)
        }
    }
    
    // MARK: - Category-Specific Logging
    
    func logAudioSession(_ message: String, level: LogLevel = .info) {
        log(message, level: level, category: .audioSession)
    }
    
    func logChunking(_ message: String, level: LogLevel = .info) {
        log(message, level: level, category: .chunking)
    }
    
    func logBackgroundProcessing(_ message: String, level: LogLevel = .info) {
        log(message, level: level, category: .backgroundProcessing)
    }
    
    func logiCloudSync(_ message: String, level: LogLevel = .info) {
        log(message, level: level, category: .iCloudSync)
    }
    
    func logFileManagement(_ message: String, level: LogLevel = .info) {
        log(message, level: level, category: .fileManagement)
    }
    
    func logPerformance(_ message: String, level: LogLevel = .info) {
        log(message, level: level, category: .performance)
    }
    
    func logErrorRecovery(_ message: String, level: LogLevel = .info) {
        log(message, level: level, category: .errorRecovery)
    }
    
    func logDebug(_ message: String, level: LogLevel = .debug) {
        log(message, level: level, category: .debug)
    }
    
    // MARK: - Performance Tracking
    
    func startPerformanceTracking(_ operation: String, context: String = "") {
        guard performanceTracking else { return }
        
        let metric = PerformanceMetric(
            operation: operation,
            context: context,
            startTime: Date(),
            memoryUsage: getCurrentMemoryUsage()
        )
        
        performanceQueue.async {
            self.performanceMetrics[operation] = metric
        }
        
        logPerformance("Started tracking: \(operation)", level: .debug)
    }
    
    func endPerformanceTracking(_ operation: String) -> PerformanceResult? {
        guard performanceTracking else { return nil }
        
        return performanceQueue.sync {
            guard let metric = performanceMetrics.removeValue(forKey: operation) else {
                return nil
            }
            
            let duration = Date().timeIntervalSince(metric.startTime)
            let endMemoryUsage = getCurrentMemoryUsage()
            let memoryDelta = endMemoryUsage - metric.memoryUsage
            
            let result = PerformanceResult(
                operation: operation,
                context: metric.context,
                duration: duration,
                memoryUsage: endMemoryUsage,
                memoryDelta: memoryDelta,
                timestamp: Date()
            )
            
            logPerformance("Completed: \(operation) in \(String(format: "%.2f", duration))s", level: .info)
            
            if debugMode {
                logDebug("Performance result: \(result.description)")
            }
            
            return result
        }
    }
    
    // MARK: - Debug Information
    
    func logDebugInfo(message: String, category: EnhancedLogCategory) {
        let debugInfo = getDebugInfo()
        logDebug("Debug info for \(category.rawValue): \(debugInfo)", level: .verbose)
    }
    
    func getDebugInfo() -> String {
        let device = UIDevice.current
        let memoryUsage = getCurrentMemoryUsage()
        let storageInfo = getStorageInfo()
        
        return """
        Device: \(device.model)
        iOS: \(device.systemVersion)
        Memory: \(String(format: "%.1f", memoryUsage)) MB
        Storage: \(storageInfo)
        Debug Mode: \(debugMode)
        Performance Tracking: \(performanceTracking)
        """
    }
    
    // MARK: - Diagnostic Information
    
    func generateDiagnosticReport() -> DiagnosticReport {
        let device = UIDevice.current
        let memoryUsage = getCurrentMemoryUsage()
        let storageInfo = getStorageInfo()
        let performanceResults = Array(performanceMetrics.values)
        
        return DiagnosticReport(
            timestamp: Date(),
            deviceInfo: DeviceDiagnosticInfo(
                model: device.model,
                systemVersion: device.systemVersion,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
                memoryUsage: memoryUsage,
                storageInfo: storageInfo
            ),
            debugConfiguration: debugConfig,
            performanceResults: performanceResults,
            enabledCategories: Array(enabledCategories),
            logLevel: currentLevel
        )
    }
    
    // MARK: - Private Helper Methods
    
    private func enableAllCategories() {
        enabledCategories = Set(EnhancedLogCategory.allCases)
    }
    
    private func disableDebugCategories() {
        enabledCategories.remove(.debug)
        enabledCategories.remove(.performance)
    }
    
    private func loadDebugConfiguration() {
        debugConfig = DebugConfiguration.load()
    }
    
    private func getCurrentMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / 1024.0 / 1024.0
        }
        
        return 0.0
    }
    
    private func getStorageInfo() -> String {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let freeSize = attributes[.systemFreeSize] as? NSNumber {
                let freeSizeGB = Double(truncating: freeSize) / 1024.0 / 1024.0 / 1024.0
                return String(format: "%.1f GB free", freeSizeGB)
            }
        } catch {
            return "Unknown"
        }
        return "Unknown"
    }
}

// MARK: - Debug Configuration

struct DebugConfiguration: Codable, Equatable {
    var enableVerboseLogging: Bool = false
    var enablePerformanceTracking: Bool = true
    var enableMemoryTracking: Bool = true
    var enableStorageTracking: Bool = true
    var enableNetworkTracking: Bool = true
    var maxLogHistory: Int = 1000
    var logRetentionDays: Int = 7
    
    static func load() -> DebugConfiguration {
        if let data = UserDefaults.standard.data(forKey: "DebugConfiguration"),
           let config = try? JSONDecoder().decode(DebugConfiguration.self, from: data) {
            return config
        }
        return DebugConfiguration()
    }
    
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "DebugConfiguration")
        }
    }
}

// MARK: - Performance Tracking

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
        return "\(operation) (\(context)): \(String(format: "%.2f", duration))s, Memory: \(String(format: "%.1f", memoryUsage))MB (\(String(format: "%+.1f", memoryDelta))MB)"
    }
}

// MARK: - Diagnostic Report

struct DiagnosticReport {
    let timestamp: Date
    let deviceInfo: DeviceDiagnosticInfo
    let debugConfiguration: DebugConfiguration
    let performanceResults: [PerformanceMetric]
    let enabledCategories: [EnhancedLogCategory]
    let logLevel: LogLevel
    
    var formattedReport: String {
        return """
        === Diagnostic Report ===
        Timestamp: \(timestamp)
        
        Device Information:
        - Model: \(deviceInfo.model)
        - iOS Version: \(deviceInfo.systemVersion)
        - App Version: \(deviceInfo.appVersion)
        - Memory Usage: \(String(format: "%.1f", deviceInfo.memoryUsage)) MB
        - Storage: \(deviceInfo.storageInfo)
        
        Debug Configuration:
        - Verbose Logging: \(debugConfiguration.enableVerboseLogging)
        - Performance Tracking: \(debugConfiguration.enablePerformanceTracking)
        - Memory Tracking: \(debugConfiguration.enableMemoryTracking)
        - Storage Tracking: \(debugConfiguration.enableStorageTracking)
        - Network Tracking: \(debugConfiguration.enableNetworkTracking)
        
        Logging:
        - Level: \(logLevel)
        - Enabled Categories: \(enabledCategories.map { $0.rawValue }.joined(separator: ", "))
        
        Performance Results: \(performanceResults.count) tracked operations
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

// MARK: - Enhanced Logging Extensions

extension EnhancedLogger {
    
    // MARK: - Audio Session Logging
    
    func logAudioSessionConfiguration(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) {
        logAudioSession("Configuring audio session - Category: \(category), Mode: \(mode), Options: \(options)", level: .info)
    }
    
    func logAudioSessionInterruption(_ type: AVAudioSession.InterruptionType) {
        logAudioSession("Audio interruption: \(type == .began ? "began" : "ended")", level: .warning)
    }
    
    func logAudioSessionRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        logAudioSession("Audio route change: \(reason)", level: .info)
    }
    
    // MARK: - Chunking Logging
    
    func logChunkingStart(_ fileURL: URL, strategy: ChunkingStrategy) {
        logChunking("Starting chunking for \(fileURL.lastPathComponent) with strategy: \(strategy)", level: .info)
    }
    
    func logChunkingProgress(_ currentChunk: Int, totalChunks: Int, fileURL: URL) {
        logChunking("Chunking progress: \(currentChunk)/\(totalChunks) for \(fileURL.lastPathComponent)", level: .debug)
    }
    
    func logChunkingComplete(_ fileURL: URL, chunkCount: Int) {
        logChunking("Chunking complete for \(fileURL.lastPathComponent): \(chunkCount) chunks created", level: .info)
    }
    
    func logChunkingError(_ error: Error, fileURL: URL) {
        logChunking("Chunking error for \(fileURL.lastPathComponent): \(error.localizedDescription)", level: .error)
    }
    
    // MARK: - Background Processing Logging
    
    func logBackgroundJobStart(_ job: ProcessingJob) {
        logBackgroundProcessing("Starting background job: \(job.type.displayName) for \(job.recordingName)", level: .info)
    }
    
    func logBackgroundJobProgress(_ job: ProcessingJob, progress: Double) {
        logBackgroundProcessing("Job progress: \(Int(progress * 100))% for \(job.recordingName)", level: .debug)
    }
    
    func logBackgroundJobComplete(_ job: ProcessingJob) {
        logBackgroundProcessing("Background job completed: \(job.type.displayName) for \(job.recordingName)", level: .info)
    }
    
    func logBackgroundJobError(_ job: ProcessingJob, error: Error) {
        logBackgroundProcessing("Background job failed: \(job.type.displayName) for \(job.recordingName) - \(error.localizedDescription)", level: .error)
    }
    
    // MARK: - iCloud Sync Logging
    
    func logiCloudSyncStart(_ operation: String) {
        logiCloudSync("Starting iCloud sync operation: \(operation)", level: .info)
    }
    
    func logiCloudSyncProgress(_ operation: String, progress: Double) {
        logiCloudSync("iCloud sync progress: \(Int(progress * 100))% for \(operation)", level: .debug)
    }
    
    func logiCloudSyncComplete(_ operation: String, itemCount: Int) {
        logiCloudSync("iCloud sync completed: \(operation) - \(itemCount) items processed", level: .info)
    }
    
    func logiCloudSyncError(_ operation: String, error: Error) {
        logiCloudSync("iCloud sync error: \(operation) - \(error.localizedDescription)", level: .error)
    }
    
    // MARK: - File Management Logging
    
    func logFileOperation(_ operation: String, fileURL: URL) {
        logFileManagement("File operation: \(operation) on \(fileURL.lastPathComponent)", level: .info)
    }
    
    func logFileRelationshipUpdate(_ recordingURL: URL, transcriptExists: Bool, summaryExists: Bool) {
        logFileManagement("File relationship updated for \(recordingURL.lastPathComponent) - Transcript: \(transcriptExists), Summary: \(summaryExists)", level: .debug)
    }
    
    func logFileDeletion(_ fileURL: URL, preserveSummary: Bool) {
        logFileManagement("File deletion: \(fileURL.lastPathComponent) (preserve summary: \(preserveSummary))", level: .info)
    }
    
    // MARK: - Error Recovery Logging
    
    func logErrorRecoveryAttempt(_ error: Error, recoveryAction: String) {
        logErrorRecovery("Attempting recovery for \(error.localizedDescription): \(recoveryAction)", level: .info)
    }
    
    func logErrorRecoverySuccess(_ error: Error, recoveryAction: String) {
        logErrorRecovery("Recovery successful for \(error.localizedDescription): \(recoveryAction)", level: .info)
    }
    
    func logErrorRecoveryFailure(_ error: Error, recoveryAction: String, failureReason: String) {
        logErrorRecovery("Recovery failed for \(error.localizedDescription): \(recoveryAction) - \(failureReason)", level: .error)
    }
}

 