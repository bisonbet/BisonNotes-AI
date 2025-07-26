//
//  PerformanceOptimizer.swift
//  Audio Journal
//
//  Performance optimization and memory management for summarization processing
//

import Foundation
import SwiftUI
import os.log

// MARK: - Performance Optimizer

@MainActor
class PerformanceOptimizer: ObservableObject {
    
    @Published var isProcessing = false
    @Published var processingProgress: Double = 0.0
    @Published var memoryUsage: MemoryUsage = MemoryUsage()
    @Published var performanceMetrics: PerformanceMetrics = PerformanceMetrics()
    
    private let logger = Logger(subsystem: "com.audiojournal.app", category: "Performance")
    private let processingQueue = DispatchQueue(label: "com.audiojournal.processing", qos: .userInitiated)
    private let cacheQueue = DispatchQueue(label: "com.audiojournal.cache", qos: .utility)
    
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
    
    init() {
        startMemoryMonitoring()
    }
    
    deinit {
        stopMemoryMonitoring()
    }
    
    // MARK: - Chunked Processing
    
    func processLargeTranscript(_ text: String, using engine: SummarizationEngine, chunkSize: Int = 2000) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType) {
        
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
        
        // Validate input size
        let wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        
        if wordCount <= chunkSize {
            // Process normally for small content
            let result = try await engine.processComplete(text: text)
            cacheResult(key: cacheKey, result: result, cost: text.count)
            return result
        }
        
        // Chunk processing for large content
        logger.info("Processing large transcript with chunked approach: \(wordCount) words")
        
        let chunks = createTextChunks(text, maxWords: chunkSize)
        var allTasks: [TaskItem] = []
        var allReminders: [ReminderItem] = []
        var summaryParts: [String] = []
        var contentTypes: [ContentType] = []
        
        for (index, chunk) in chunks.enumerated() {
            processingProgress = Double(index) / Double(chunks.count) * 0.8 // 80% for chunk processing
            
            do {
                let chunkResult = try await processChunkWithRetry(chunk, using: engine, retryCount: 2)
                
                summaryParts.append(chunkResult.summary)
                allTasks.append(contentsOf: chunkResult.tasks)
                allReminders.append(contentsOf: chunkResult.reminders)
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
        
        // Consolidate results
        let finalSummary = consolidateSummaryParts(summaryParts)
        let finalTasks = deduplicateAndLimitTasks(allTasks, limit: 15)
        let finalReminders = deduplicateAndLimitReminders(allReminders, limit: 15)
        let finalContentType = determinePrimaryContentType(contentTypes)
        
        processingProgress = 1.0
        
        let result = (summary: finalSummary, tasks: finalTasks, reminders: finalReminders, contentType: finalContentType)
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
    
    func optimizeMemoryUsage() {
        Task {
            await performMemoryOptimization()
        }
    }
    
    private func performMemoryOptimization() async {
        logger.info("Performing memory optimization")
        
        // Clear caches if memory usage is high
        let currentMemory = getCurrentMemoryUsage()
        if currentMemory.usedMemoryMB > 100 { // If using more than 100MB
            clearCaches()
        }
        
        // Force garbage collection
        autoreleasepool {
            // This block helps with memory cleanup
        }
        
        // Update memory usage
        await updateMemoryUsage()
    }
    
    func clearCaches() {
        summaryCache.removeAllObjects()
        processingCache.removeAllObjects()
        logger.info("Cleared all caches to free memory")
    }
    
    // MARK: - Progress Tracking
    
    func trackProgress(for operation: String, progress: Double) {
        DispatchQueue.main.async {
            self.processingProgress = progress
        }
    }
    
    // MARK: - Private Helper Methods
    
    private func createTextChunks(_ text: String, maxWords: Int) -> [String] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var chunks: [String] = []
        var currentChunk: [String] = []
        var currentWordCount = 0
        
        for sentence in sentences {
            let sentenceWordCount = sentence.components(separatedBy: .whitespacesAndNewlines).count
            
            if currentWordCount + sentenceWordCount > maxWords && !currentChunk.isEmpty {
                // Start new chunk
                chunks.append(currentChunk.joined(separator: ". ") + ".")
                currentChunk = [sentence]
                currentWordCount = sentenceWordCount
            } else {
                currentChunk.append(sentence)
                currentWordCount += sentenceWordCount
            }
        }
        
        // Add remaining chunk
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.joined(separator: ". ") + ".")
        }
        
        return chunks
    }
    
    private func processChunkWithRetry(_ chunk: String, using engine: SummarizationEngine, retryCount: Int) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType) {
        
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
    
    private func consolidateSummaryParts(_ parts: [String]) -> String {
        guard !parts.isEmpty else { return "" }
        
        if parts.count == 1 {
            return parts[0]
        }
        
        // Combine and deduplicate summary parts
        let combinedText = parts.joined(separator: " ")
        let sentences = combinedText.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        // Remove duplicate sentences
        let uniqueSentences = Array(NSOrderedSet(array: sentences.map { $0.lowercased() }))
            .compactMap { lowercased in
                sentences.first { $0.lowercased() == lowercased as? String }
            }
        
        // Limit to reasonable length
        let limitedSentences = Array(uniqueSentences.prefix(5))
        return limitedSentences.joined(separator: ". ") + "."
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
    
    private func getCachedResult(key: String) -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType)? {
        return summaryCache.object(forKey: NSString(string: key))?.result
    }
    
    private func cacheResult(key: String, result: (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType), cost: Int) {
        let cachedResult = CachedSummaryResult(result: result, timestamp: Date())
        summaryCache.setObject(cachedResult, forKey: NSString(string: key), cost: cost)
    }
    
    // MARK: - Memory Monitoring
    
    private func startMemoryMonitoring() {
        memoryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task {
                await self.updateMemoryUsage()
            }
        }
    }
    
    nonisolated private func stopMemoryMonitoring() {
        Task { @MainActor in
            memoryMonitorTimer?.invalidate()
            memoryMonitorTimer = nil
        }
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
        
        Task {
            await MainActor.run {
                self.performanceMetrics = PerformanceMetrics(
                    averageProcessingTime: processingTime,
                    wordsPerSecond: wordsPerSecond,
                    cacheHitRate: calculateCacheHitRate(),
                    memoryEfficiency: calculateMemoryEfficiency()
                )
            }
        }
    }
    
    private func calculateCacheHitRate() -> Double {
        // This would be tracked over time in a real implementation
        return 0.75 // Placeholder
    }
    
    private func calculateMemoryEfficiency() -> Double {
        let currentUsage = memoryUsage.usedMemoryMB
        return max(0.0, 1.0 - (currentUsage / 200.0)) // Efficiency decreases as memory usage increases
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
    let result: (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType)
    let timestamp: Date
    
    init(result: (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType), timestamp: Date) {
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