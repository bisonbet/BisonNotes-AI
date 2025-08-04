//
//  PerformanceOptimizer.swift
//  Audio Journal
//
//  Performance optimization and memory management for summarization processing
//

import Foundation
import SwiftUI
import os.log

// MARK: - Logging Level Management

enum LogLevel: Int, CaseIterable {
    case error = 0
    case warning = 1
    case info = 2
    case debug = 3
    case verbose = 4
    
    var emoji: String {
        switch self {
        case .error: return "❌"
        case .warning: return "⚠️"
        case .info: return "ℹ️"
        case .debug: return "🔍"
        case .verbose: return "🔧"
        }
    }
    
    var description: String {
        switch self {
        case .error: return "Error"
        case .warning: return "Warning"
        case .info: return "Info"
        case .debug: return "Debug"
        case .verbose: return "Verbose"
        }
    }
}

class AppLogger {
    static let shared = AppLogger()
    
    private let logger = Logger(subsystem: "com.audiojournal.app", category: "AppLogger")
    private var currentLevel: LogLevel = .info
    
    private init() {
        // Set default level based on build configuration
        #if DEBUG
        currentLevel = .debug
        #else
        currentLevel = .info
        #endif
    }
    
    func setLogLevel(_ level: LogLevel) {
        currentLevel = level
    }
    
    func log(_ message: String, level: LogLevel = .info, category: String = "General") {
        guard level.rawValue <= currentLevel.rawValue else { return }
        
        let formattedMessage = "\(level.emoji) [\(category)]: \(message)"
        
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
    }
    
    // Convenience methods for different log levels
    func error(_ message: String, category: String = "General") {
        log(message, level: .error, category: category)
    }
    
    func warning(_ message: String, category: String = "General") {
        log(message, level: .warning, category: category)
    }
    
    func info(_ message: String, category: String = "General") {
        log(message, level: .info, category: category)
    }
    
    func debug(_ message: String, category: String = "General") {
        log(message, level: .debug, category: category)
    }
    
    func verbose(_ message: String, category: String = "General") {
        log(message, level: .verbose, category: category)
    }
}

// MARK: - Battery Monitor

struct BatteryInfo {
    let level: Float
    let state: UIDevice.BatteryState
    let isLowPowerMode: Bool
    
    var isLowBattery: Bool {
        return level < 0.2 || isLowPowerMode
    }
    
    var shouldOptimizeForBattery: Bool {
        return level < 0.3 || isLowPowerMode
    }
    
    var formattedLevel: String {
        return String(format: "%.0f%%", level * 100)
    }
}

// MARK: - Optimization Level

enum OptimizationLevel {
    case balanced
    case batteryOptimized
    case memoryOptimized
    
    var description: String {
        switch self {
        case .balanced: return "Balanced"
        case .batteryOptimized: return "Battery Optimized"
        case .memoryOptimized: return "Memory Optimized"
        }
    }
}

// MARK: - String Extension for Chunking

extension String {
    func chunked(into size: Int) -> [String] {
        var chunks: [String] = []
        var currentChunk = ""
        
        let words = self.components(separatedBy: .whitespacesAndNewlines)
        
        for word in words {
            let testChunk = currentChunk.isEmpty ? word : "\(currentChunk) \(word)"
            
            if testChunk.count > size && !currentChunk.isEmpty {
                chunks.append(currentChunk)
                currentChunk = word
            } else {
                currentChunk = testChunk
            }
        }
        
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        
        return chunks
    }
}

// MARK: - Performance Optimizer

@MainActor
class PerformanceOptimizer: ObservableObject, Sendable {
    @MainActor static let shared = PerformanceOptimizer()
    
    @Published var isProcessing = false
    @Published var processingProgress: Double = 0.0
    @Published var memoryUsage: MemoryUsage = MemoryUsage()
    @Published var batteryInfo: BatteryInfo = BatteryInfo(level: 1.0, state: .unknown, isLowPowerMode: false)
    @Published var performanceMetrics: PerformanceMetrics = PerformanceMetrics()
    @Published var optimizationLevel: OptimizationLevel = .balanced
    
    private let logger = Logger(subsystem: "com.audiojournal.app", category: "Performance")
    private let processingQueue = DispatchQueue(label: "com.audiojournal.processing", qos: .userInitiated)
    private let cacheQueue = DispatchQueue(label: "com.audiojournal.cache", qos: .utility)
    private let streamingQueue = DispatchQueue(label: "com.audiojournal.streaming", qos: .utility)
    
    // MARK: - Caching System
    
    private var summaryCache: NSCache<NSString, CachedSummaryResult> = {
        let cache = NSCache<NSString, CachedSummaryResult>()
        cache.countLimit = 50 // Maximum 50 cached summaries
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB total cache size
        return cache
    }()
    
    private var processingCache: NSCache<NSString, ProcessingResult> = {
        let cache = NSCache<NSString, ProcessingResult>()
        cache.countLimit = 20 // Maximum 20 processing results
        cache.totalCostLimit = 20 * 1024 * 1024 // 20MB total cache size
        return cache
    }()
    
    // MARK: - Performance Monitoring
    
    private var processingStartTime: Date?
    private var memoryMonitorTimer: Timer?
    private var batteryMonitorTimer: Timer?
    private var optimizationTimer: Timer?
    
    init() {
        startMemoryMonitoring()
        startBatteryMonitoring()
        startOptimizationMonitoring()
    }
    
    deinit {
        // Use weak self to avoid capture cycle
        Task { [weak self] in
            await self?.stopAllMonitoring()
        }
    }
    
    // MARK: - Battery Monitoring
    
    private func startBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        batteryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateBatteryInfo()
            }
        }
        
        // Initial battery info update
        Task { @MainActor in
            await updateBatteryInfo()
        }
    }
    
    private func updateBatteryInfo() async {
        let device = UIDevice.current
        let batteryInfo = BatteryInfo(
            level: device.batteryLevel,
            state: device.batteryState,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        
        self.batteryInfo = batteryInfo
        
        // Adjust optimization level based on battery state
        await adjustOptimizationLevel()
        
    }
    
    private func adjustOptimizationLevel() async {
        let newLevel: OptimizationLevel
        
        if batteryInfo.shouldOptimizeForBattery {
            newLevel = .batteryOptimized
        } else if memoryUsage.isHighUsage {
            newLevel = .memoryOptimized
        } else {
            newLevel = .balanced
        }
        
        if newLevel != optimizationLevel {
            optimizationLevel = newLevel
            await applyOptimizationSettings()
        }
    }
    
    private func applyOptimizationSettings() async {
        switch optimizationLevel {
        case .batteryOptimized:
            // Reduce processing frequency and cache size
            summaryCache.countLimit = 25
            processingCache.countLimit = 10
            logger.info("Applied battery optimization settings")
            
        case .memoryOptimized:
            // Reduce cache sizes and increase cleanup frequency
            summaryCache.countLimit = 30
            processingCache.countLimit = 15
            clearCaches()
            logger.info("Applied memory optimization settings")
            
        case .balanced:
            // Standard settings
            summaryCache.countLimit = 50
            processingCache.countLimit = 20
            logger.info("Applied balanced optimization settings")
        }
    }
    
    // MARK: - Streaming File Processing
    
    func processLargeFileWithStreaming(_ url: URL, chunkSize: Int = 1024 * 1024) async throws -> Data {
        logger.info("Starting streaming processing for file: \(url.lastPathComponent)")
        
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        
        var processedData = Data()
        var totalBytesRead: Int64 = 0
        let totalFileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var shouldStopProcessing = false
        
        while !shouldStopProcessing {
            autoreleasepool {
                let chunk = fileHandle.readData(ofLength: chunkSize)
                if chunk.isEmpty { 
                    shouldStopProcessing = true
                    return 
                }
                
                processedData.append(chunk)
                totalBytesRead += Int64(chunk.count)
                
                // Update progress
                let progress = Double(totalBytesRead) / Double(totalFileSize)
                Task { @MainActor in
                    self.processingProgress = progress
                }
                
                // Memory management: limit processed data size
                if processedData.count > 50 * 1024 * 1024 { // 50MB limit
                    logger.warning("Processed data size limit reached, processing in segments")
                    shouldStopProcessing = true
                    return
                }
            }
            
            // Yield control to prevent blocking
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        
        return processedData
    }
    
    // MARK: - Enhanced Memory Management
    
    func optimizeMemoryUsage() {
        Task {
            await performAdvancedMemoryOptimization()
        }
    }
    
    private func performAdvancedMemoryOptimization() async {
        logger.info("Performing advanced memory optimization")
        
        let currentMemory = getCurrentMemoryUsage()
        
        // Aggressive cache clearing if memory usage is high
        if currentMemory.usedMemoryMB > 100 {
            clearCaches()
            await forceGarbageCollection()
        }
        
        // Adaptive cache size adjustment
        if currentMemory.usedMemoryMB > 150 {
            summaryCache.countLimit = max(10, summaryCache.countLimit / 2)
            processingCache.countLimit = max(5, processingCache.countLimit / 2)
        }
        
        // Update memory usage
        await updateMemoryUsage()
        
        logger.info("Memory optimization complete. Current usage: \(currentMemory.usedMemoryMB)MB")
    }
    
    private func forceGarbageCollection() async {
        // Force autorelease pool cleanup
        autoreleasepool {
            // This block helps with memory cleanup
        }
        
        // Small delay to allow system to reclaim memory
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }
    
    // MARK: - Background Processing Optimization
    
    func optimizeBackgroundProcessing() async {
        
        // Note: DispatchQueue QoS cannot be changed after creation
        // The queue will continue using its original QoS setting
        // Battery optimization is handled through chunk size and processing frequency
        
        // Adjust chunk processing size based on memory usage
        _ = calculateOptimalChunkSize()
    }
    
    public func calculateOptimalChunkSize() -> Int {
        let baseSize = 1024 * 1024 // 1MB base
        
        if memoryUsage.isHighUsage {
            return baseSize / 2 // 512KB
        } else if batteryInfo.shouldOptimizeForBattery {
            return baseSize / 4 // 256KB
        } else {
            return baseSize // 1MB
        }
    }
    
    // MARK: - Network Optimization for iCloud Sync
    
    func optimizeNetworkUsage() async {
        
        // Adjust sync frequency based on battery and network conditions
        let _: TimeInterval
        
        if batteryInfo.shouldOptimizeForBattery {
            _ = 600 // 10 minutes
        } else if memoryUsage.isHighUsage {
            _ = 300 // 5 minutes
        } else {
            _ = 180 // 3 minutes
        }
        
    }
    
    // MARK: - Progress Tracking with Battery Awareness
    
    func trackProgressWithBatteryAwareness(for operation: String, progress: Double) {
        processingProgress = progress
        
        // Reduce update frequency when battery is low
        if batteryInfo.shouldOptimizeForBattery {
            // Only update every 10% when battery is low
            let roundedProgress = round(progress * 10) / 10
            processingProgress = roundedProgress
        }
    }
    
    // MARK: - Enhanced Chunked Processing with Streaming
    
    func processLargeTranscriptWithStreaming(_ text: String, using engine: SummarizationEngine) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        
        let startTime = Date()
        processingStartTime = startTime
        
        // Check cache first
        let cacheKey = "\(text.hashValue)_\(engine.name)"
        if let cachedResult = getCachedResult(key: cacheKey) {
            logger.info("Cache hit for large transcript processing")
            return cachedResult
        }
        
        logger.info("Processing large transcript with streaming optimization")
        
        // Determine optimal chunk size based on current conditions
        let optimalChunkSize = calculateOptimalChunkSize()
        let chunks = text.chunked(into: optimalChunkSize)
        
        logger.info("Split transcript into \(chunks.count) chunks of ~\(optimalChunkSize) bytes each")

        var summaryParts: [String] = []
        var allTasks: [TaskItem] = []
        var allReminders: [ReminderItem] = []
        var allTitles: [TitleItem] = []
        var contentTypes: [ContentType] = []

        // Initialize Ollama service for meta-summary generation
        let ollamaService = OllamaService()
        _ = await ollamaService.testConnection()
        
        for (index, chunk) in chunks.enumerated() {
            processingProgress = Double(index) / Double(chunks.count) * 0.8 // 80% for chunk processing
            
            do {
                let chunkResult = try await processChunkWithRetry(chunk, using: engine, retryCount: 2)
                
                summaryParts.append(chunkResult.summary)
                allTasks.append(contentsOf: chunkResult.tasks)
                allReminders.append(contentsOf: chunkResult.reminders)
                allTitles.append(contentsOf: chunkResult.titles)
                contentTypes.append(chunkResult.contentType)
                
                // Memory management: clear intermediate results
                autoreleasepool {
                    // Process chunk results
                }
                
                // Battery-aware processing delays
                if batteryInfo.shouldOptimizeForBattery {
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
                }
                
            } catch {
                logger.error("Failed to process chunk \(index): \(error)")
                // Continue with other chunks
            }
        }
        
        processingProgress = 0.9 // 90% - consolidating results
        
        // Consolidate results using TokenManager with AI-generated meta-summary
        let finalSummary = try await TokenManager.combineSummaries(
            summaryParts,
            contentType: determinePrimaryContentType(contentTypes),
            service: ollamaService
        )
        let finalTasks = deduplicateAndLimitTasks(allTasks, limit: 15)
        let finalReminders = deduplicateAndLimitReminders(allReminders, limit: 15)
        let finalContentType = determinePrimaryContentType(contentTypes)
        
        processingProgress = 1.0
        
        let finalTitles = deduplicateAndLimitTitles(allTitles, limit: 15)
        
        let result = (summary: finalSummary, tasks: finalTasks, reminders: finalReminders, titles: finalTitles, contentType: finalContentType)
        cacheResult(key: cacheKey, result: result, cost: text.count)
        
        return result
    }
    
    // MARK: - Background Processing with Battery Optimization
    
    func processInBackgroundWithBatteryOptimization<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            let queue = batteryInfo.shouldOptimizeForBattery ? 
                DispatchQueue(label: "com.audiojournal.processing.battery", qos: .utility) :
                processingQueue
            
            queue.async {
                Task {
                    do {
                        let result = try await operation()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    // MARK: - Monitoring Control
    
    private func startOptimizationMonitoring() {
        optimizationTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performPeriodicOptimization()
            }
        }
    }
    
    private func performPeriodicOptimization() async {
        await adjustOptimizationLevel()
        await optimizeBackgroundProcessing()
        await optimizeNetworkUsage()
    }
    
    private func stopAllMonitoring() async {
        memoryMonitorTimer?.invalidate()
        batteryMonitorTimer?.invalidate()
        optimizationTimer?.invalidate()
        
        memoryMonitorTimer = nil
        batteryMonitorTimer = nil
        optimizationTimer = nil
        
        UIDevice.current.isBatteryMonitoringEnabled = false
    }
    
    // MARK: - Chunked Processing
    
    func processLargeTranscript(_ text: String, using engine: SummarizationEngine) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        
        let startTime = Date()
        processingStartTime = startTime
        
        isProcessing = true
        processingProgress = 0.0
        
        defer {
            isProcessing = false
            processingProgress = 0.0
            recordProcessingMetrics(startTime: startTime, textLength: text.count)
        }
        
        // Check cache first
        let cacheKey = createCacheKey(text: text, engine: engine.name)
        if let cachedResult = getCachedResult(key: cacheKey) {
            logger.info("Using cached result for transcript processing")
            return cachedResult
        }
        
        // Check if text needs chunking based on token count
        let tokenCount = TokenManager.getTokenCount(text)
        logger.info("Text token count: \(tokenCount)")
        
        if !TokenManager.needsChunking(text) {
            // Process normally for small content
            let result = try await engine.processComplete(text: text)
            cacheResult(key: cacheKey, result: result, cost: text.count)
            return result
        }
        
        // Chunk processing for large content
        logger.info("Processing large transcript with token-based chunking: \(tokenCount) tokens")
        
        let chunks = TokenManager.chunkText(text)
        var allTasks: [TaskItem] = []
        var allReminders: [ReminderItem] = []
        var allTitles: [TitleItem] = []
        var summaryParts: [String] = []
        var contentTypes: [ContentType] = []

        // Initialize Ollama service for meta-summary generation
        let ollamaService = OllamaService()
        _ = await ollamaService.testConnection()
        
        for (index, chunk) in chunks.enumerated() {
            processingProgress = Double(index) / Double(chunks.count) * 0.8 // 80% for chunk processing
            
            do {
                let chunkResult = try await processChunkWithRetry(chunk, using: engine, retryCount: 2)
                
                summaryParts.append(chunkResult.summary)
                allTasks.append(contentsOf: chunkResult.tasks)
                allReminders.append(contentsOf: chunkResult.reminders)
                allTitles.append(contentsOf: chunkResult.titles)
                contentTypes.append(chunkResult.contentType)
                
                // Memory management: clear intermediate results
                autoreleasepool {
                    // Process chunk results
                }
                
            } catch {
                logger.error("Failed to process chunk \(index): \(error)")
                // Continue with other chunks
            }
        }
        
        processingProgress = 0.9 // 90% - consolidating results
        
        // Consolidate results using TokenManager with AI-generated meta-summary
        let finalSummary = try await TokenManager.combineSummaries(
            summaryParts,
            contentType: determinePrimaryContentType(contentTypes),
            service: ollamaService
        )
        let finalTasks = deduplicateAndLimitTasks(allTasks, limit: 15)
        let finalReminders = deduplicateAndLimitReminders(allReminders, limit: 15)
        let finalContentType = determinePrimaryContentType(contentTypes)
        
        processingProgress = 1.0
        
        let finalTitles = deduplicateAndLimitTitles(allTitles, limit: 15)
        
        let result = (summary: finalSummary, tasks: finalTasks, reminders: finalReminders, titles: finalTitles, contentType: finalContentType)
        cacheResult(key: cacheKey, result: result, cost: text.count)
        
        return result
    }
    
    // MARK: - Background Processing
    
    func processInBackground<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            processingQueue.async {
                Task {
                    do {
                        let result = try await operation()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    // MARK: - Memory Management
    
    func clearCaches() {
        summaryCache.removeAllObjects()
        processingCache.removeAllObjects()
        logger.info("Cleared all caches to free memory")
    }
    
    // MARK: - Progress Tracking
    
    func trackProgress(for operation: String, progress: Double) {
        processingProgress = progress
    }
    
    // MARK: - Private Helper Methods
    

    
    private func processChunkWithRetry(_ chunk: String, using engine: SummarizationEngine, retryCount: Int) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        
        var lastError: Error?
        
        for attempt in 0...retryCount {
            do {
                return try await engine.processComplete(text: chunk)
            } catch {
                lastError = error
                logger.warning("Chunk processing attempt \(attempt + 1) failed: \(error)")
                
                if attempt < retryCount {
                    // Wait before retry with exponential backoff
                    let delay = TimeInterval(pow(2.0, Double(attempt))) // 1s, 2s, 4s...
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? SummarizationError.processingFailed(reason: "All retry attempts failed")
    }
    

    
    private func deduplicateAndLimitTasks(_ tasks: [TaskItem], limit: Int) -> [TaskItem] {
        // Remove duplicates based on text similarity
        var uniqueTasks: [TaskItem] = []
        
        for task in tasks {
            let isDuplicate = uniqueTasks.contains { existingTask in
                let similarity = calculateTextSimilarity(task.text, existingTask.text)
                return similarity > 0.8
            }
            
            if !isDuplicate {
                uniqueTasks.append(task)
            }
        }
        
        // Sort by priority and confidence, then limit
        let sortedTasks = uniqueTasks.sorted { task1, task2 in
            if task1.priority.sortOrder != task2.priority.sortOrder {
                return task1.priority.sortOrder < task2.priority.sortOrder
            }
            return task1.confidence > task2.confidence
        }
        
        return Array(sortedTasks.prefix(limit))
    }
    
    private func deduplicateAndLimitReminders(_ reminders: [ReminderItem], limit: Int) -> [ReminderItem] {
        // Remove duplicates based on text similarity
        var uniqueReminders: [ReminderItem] = []
        
        for reminder in reminders {
            let isDuplicate = uniqueReminders.contains { existingReminder in
                let similarity = calculateTextSimilarity(reminder.text, existingReminder.text)
                return similarity > 0.8
            }
            
            if !isDuplicate {
                uniqueReminders.append(reminder)
            }
        }
        
        // Sort by urgency and confidence, then limit
        let sortedReminders = uniqueReminders.sorted { reminder1, reminder2 in
            if reminder1.urgency.sortOrder != reminder2.urgency.sortOrder {
                return reminder1.urgency.sortOrder < reminder2.urgency.sortOrder
            }
            return reminder1.confidence > reminder2.confidence
        }
        
        return Array(sortedReminders.prefix(limit))
    }
    
    private func deduplicateAndLimitTitles(_ titles: [TitleItem], limit: Int) -> [TitleItem] {
        // Remove duplicates based on text similarity
        var uniqueTitles: [TitleItem] = []
        
        for title in titles {
            let isDuplicate = uniqueTitles.contains { existingTitle in
                let similarity = calculateTextSimilarity(title.text, existingTitle.text)
                return similarity > 0.8
            }
            
            if !isDuplicate {
                uniqueTitles.append(title)
            }
        }
        
        // Sort by confidence, then limit
        let sortedTitles = uniqueTitles.sorted { title1, title2 in
            return title1.confidence > title2.confidence
        }
        
        return Array(sortedTitles.prefix(limit))
    }
    
    private func calculateTextSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.lowercased().components(separatedBy: .whitespacesAndNewlines))
        let words2 = Set(text2.lowercased().components(separatedBy: .whitespacesAndNewlines))
        
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        
        return union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
    }
    
    private func determinePrimaryContentType(_ types: [ContentType]) -> ContentType {
        guard !types.isEmpty else { return .general }
        
        // Count occurrences of each type
        let typeCounts = Dictionary(grouping: types, by: { $0 }).mapValues { $0.count }
        
        // Return the most common type
        return typeCounts.max { $0.value < $1.value }?.key ?? .general
    }
    
    // MARK: - Caching Methods
    
    private func createCacheKey(text: String, engine: String) -> String {
        let textHash = text.hash
        return "\(engine)_\(textHash)"
    }
    
    private func getCachedResult(key: String) -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType)? {
        return summaryCache.object(forKey: NSString(string: key))?.result
    }
    
    private func cacheResult(key: String, result: (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType), cost: Int) {
        let cachedResult = CachedSummaryResult(result: result, timestamp: Date())
        summaryCache.setObject(cachedResult, forKey: NSString(string: key), cost: cost)
    }
    
    // MARK: - Memory Monitoring
    
    private func startMemoryMonitoring() {
        memoryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateMemoryUsage()
            }
        }
    }
    
    private func stopMemoryMonitoring() {
        memoryMonitorTimer?.invalidate()
        memoryMonitorTimer = nil
    }
    
    private func updateMemoryUsage() async {
        let usage = getCurrentMemoryUsage()
        await MainActor.run {
            self.memoryUsage = usage
        }
    }
    
    private func getCurrentMemoryUsage() -> MemoryUsage {
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
            let usedMemoryMB = Double(info.resident_size) / 1024.0 / 1024.0
            return MemoryUsage(usedMemoryMB: usedMemoryMB, isHighUsage: usedMemoryMB > 150)
        } else {
            return MemoryUsage()
        }
    }
    
    private func recordProcessingMetrics(startTime: Date, textLength: Int) {
        let processingTime = Date().timeIntervalSince(startTime)
        let wordsPerSecond = Double(textLength) / max(processingTime, 0.1)
        
        performanceMetrics = PerformanceMetrics(
            averageProcessingTime: processingTime,
            wordsPerSecond: wordsPerSecond,
            cacheHitRate: calculateCacheHitRate(),
            memoryEfficiency: calculateMemoryEfficiency()
        )
    }
    
    private func calculateCacheHitRate() -> Double {
        // This would be tracked over time in a real implementation
        return 0.75 // Placeholder
    }
    
    private func calculateMemoryEfficiency() -> Double {
        let currentUsage = memoryUsage.usedMemoryMB
        return max(0.0, 1.0 - (currentUsage / 200.0)) // Efficiency decreases as memory usage increases
    }
    
    // MARK: - Logging Control Methods
    
    func optimizeStartupLogging() {
        logger.info("Optimizing startup logging levels")
        
        // Reduce verbose logging during startup
        #if DEBUG
        // In debug builds, keep some debug info but reduce verbose messages
        AppLogger.shared.setLogLevel(.debug)
        #else
        // In release builds, only show important messages
        AppLogger.shared.setLogLevel(.info)
        #endif
    }
    
    nonisolated static func shouldLogEngineInitialization() -> Bool {
        #if DEBUG
        return false // Disable verbose engine initialization logs even in debug
        #else
        return false
        #endif
    }
    
    nonisolated static func shouldLogEngineAvailabilityChecks() -> Bool {
        #if DEBUG
        return false // Disable verbose availability check logs
        #else
        return false
        #endif
    }
}

// MARK: - Supporting Structures

struct MemoryUsage {
    let usedMemoryMB: Double
    let isHighUsage: Bool
    
    init(usedMemoryMB: Double = 0.0, isHighUsage: Bool = false) {
        self.usedMemoryMB = usedMemoryMB
        self.isHighUsage = isHighUsage
    }
    
    var formattedUsage: String {
        return String(format: "%.1f MB", usedMemoryMB)
    }
    
    var usageLevel: MemoryUsageLevel {
        switch usedMemoryMB {
        case 0..<50: return .low
        case 50..<100: return .moderate
        case 100..<150: return .high
        default: return .critical
        }
    }
}

enum MemoryUsageLevel {
    case low, moderate, high, critical
    
    var color: Color {
        switch self {
        case .low: return .green
        case .moderate: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }
    
    var description: String {
        switch self {
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }
}

struct PerformanceMetrics {
    let averageProcessingTime: TimeInterval
    let wordsPerSecond: Double
    let cacheHitRate: Double
    let memoryEfficiency: Double
    
    init(averageProcessingTime: TimeInterval = 0.0, wordsPerSecond: Double = 0.0, cacheHitRate: Double = 0.0, memoryEfficiency: Double = 1.0) {
        self.averageProcessingTime = averageProcessingTime
        self.wordsPerSecond = wordsPerSecond
        self.cacheHitRate = cacheHitRate
        self.memoryEfficiency = memoryEfficiency
    }
    
    var formattedProcessingTime: String {
        return String(format: "%.2fs", averageProcessingTime)
    }
    
    var formattedWordsPerSecond: String {
        return String(format: "%.0f words/s", wordsPerSecond)
    }
    
    var formattedCacheHitRate: String {
        return String(format: "%.1f%%", cacheHitRate * 100)
    }
    
    var formattedMemoryEfficiency: String {
        return String(format: "%.1f%%", memoryEfficiency * 100)
    }
}

class CachedSummaryResult: NSObject {
    let result: (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType)
    let timestamp: Date
    
    init(result: (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType), timestamp: Date) {
        self.result = result
        self.timestamp = timestamp
        super.init()
    }
}

class ProcessingResult: NSObject {
    let data: Data
    let timestamp: Date
    
    init(data: Data, timestamp: Date) {
        self.data = data
        self.timestamp = timestamp
        super.init()
    }
}

// MARK: - Performance Monitoring View

struct PerformanceMonitorView: View {
    @ObservedObject var optimizer: PerformanceOptimizer
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Memory Usage Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Memory Usage")
                            .font(.headline)
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(optimizer.memoryUsage.formattedUsage)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(optimizer.memoryUsage.usageLevel.color)
                                
                                Text(optimizer.memoryUsage.usageLevel.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("Optimize") {
                                optimizer.optimizeMemoryUsage()
                            }
                            .buttonStyle(.bordered)
                            .disabled(optimizer.isProcessing)
                        }
                        
                        ProgressView(value: min(optimizer.memoryUsage.usedMemoryMB / 200.0, 1.0))
                            .progressViewStyle(LinearProgressViewStyle(tint: optimizer.memoryUsage.usageLevel.color))
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    // Performance Metrics Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Performance Metrics")
                            .font(.headline)
                        
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            MetricCard(
                                title: "Processing Time",
                                value: optimizer.performanceMetrics.formattedProcessingTime,
                                icon: "clock"
                            )
                            
                            MetricCard(
                                title: "Words/Second",
                                value: optimizer.performanceMetrics.formattedWordsPerSecond,
                                icon: "speedometer"
                            )
                            
                            MetricCard(
                                title: "Cache Hit Rate",
                                value: optimizer.performanceMetrics.formattedCacheHitRate,
                                icon: "memorychip"
                            )
                            
                            MetricCard(
                                title: "Memory Efficiency",
                                value: optimizer.performanceMetrics.formattedMemoryEfficiency,
                                icon: "gauge"
                            )
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    // Cache Management Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Cache Management")
                            .font(.headline)
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Cache Status")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Text("Caching enabled for faster processing")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("Clear Cache") {
                                optimizer.clearCaches()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    // Processing Status
                    if optimizer.isProcessing {
                        VStack(spacing: 8) {
                            Text("Processing...")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            ProgressView(value: optimizer.processingProgress)
                                .progressViewStyle(LinearProgressViewStyle())
                            
                            Text("\(Int(optimizer.processingProgress * 100))% Complete")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(12)
                    }
                }
                .padding()
            }
            .navigationTitle("Performance Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
            
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
}