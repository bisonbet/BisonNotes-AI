//
//  EnginePerformanceMonitor.swift
//  Audio Journal
//
//  Engine performance monitoring and statistics collection
//

import Foundation
import SwiftUI
import os.log

// MARK: - Engine Performance Monitor

@MainActor
class EnginePerformanceMonitor: ObservableObject {
    
    @Published var engineStatistics: [String: EnginePerformanceStatistics] = [:]
    @Published var recentPerformance: [EnginePerformanceData] = []
    @Published var performanceTrends: [PerformanceTrend] = []
    @Published var usageAnalytics: EngineUsageAnalytics?
    @Published var isMonitoring = false
    
    private let logger = Logger(subsystem: "com.audiojournal.app", category: "EnginePerformance")
    private let performanceDataKey = "EnginePerformanceData"
    private let statisticsKey = "EngineStatistics"
    private let analyticsKey = "EngineUsageAnalytics"
    
    // Performance data storage
    private var allPerformanceData: [EnginePerformanceData] = []
    private var monitoringTimer: Timer?
    
    // Configuration
    private let maxDataPoints = 1000 // Maximum performance data points to store
    private let trendAnalysisWindow = 30 // Days to analyze for trends
    private let statisticsUpdateInterval: TimeInterval = 300 // 5 minutes
    
    init() {
        loadPerformanceData()
        startMonitoring()
    }
    
    deinit {
        // Clean up timer synchronously in deinit
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        logger.info("Engine performance monitor deallocated")
    }
    
    // MARK: - Performance Tracking
    
    func trackEnginePerformance(
        engineName: String,
        processingTime: TimeInterval,
        textLength: Int,
        wordCount: Int,
        tokenCount: Int,
        summaryLength: Int,
        tasksExtracted: Int,
        remindersExtracted: Int,
        confidence: Double,
        qualityScore: Double,
        contentType: ContentType,
        success: Bool,
        errorMessage: String? = nil
    ) {
        let performanceData = EnginePerformanceData(
            engineName: engineName,
            processingTime: processingTime,
            textLength: textLength,
            wordCount: wordCount,
            tokenCount: tokenCount,
            summaryLength: summaryLength,
            tasksExtracted: tasksExtracted,
            remindersExtracted: remindersExtracted,
            confidence: confidence,
            qualityScore: qualityScore,
            contentType: contentType,
            success: success,
            errorMessage: errorMessage
        )
        
        // Add to recent performance
        recentPerformance.insert(performanceData, at: 0)
        if recentPerformance.count > 50 {
            recentPerformance = Array(recentPerformance.prefix(50))
        }
        
        // Add to all performance data
        allPerformanceData.append(performanceData)
        
        // Limit data points
        if allPerformanceData.count > maxDataPoints {
            allPerformanceData = Array(allPerformanceData.suffix(maxDataPoints))
        }
        
        // Update statistics
        updateEngineStatistics()
        
        // Save data
        savePerformanceData()
        
        logger.info("Tracked performance for \(engineName): \(processingTime)s, \(wordCount) words, \(success ? "success" : "failed")")
    }
    
    func trackEnhancedSummaryPerformance(_ summary: EnhancedSummaryData, engineName: String, processingTime: TimeInterval) {
        let wordCount = summary.originalLength
        let tokenCount = TokenManager.getTokenCount(summary.summary)
        let qualityScore = calculateQualityScore(for: summary)
        
        trackEnginePerformance(
            engineName: engineName,
            processingTime: processingTime,
            textLength: summary.summary.count,
            wordCount: wordCount,
            tokenCount: tokenCount,
            summaryLength: summary.summary.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
            tasksExtracted: summary.tasks.count,
            remindersExtracted: summary.reminders.count,
            confidence: summary.confidence,
            qualityScore: qualityScore,
            contentType: summary.contentType,
            success: true
        )
    }
    
    func trackEngineFailure(engineName: String, processingTime: TimeInterval, error: Error, textLength: Int, wordCount: Int) {
        trackEnginePerformance(
            engineName: engineName,
            processingTime: processingTime,
            textLength: textLength,
            wordCount: wordCount,
            tokenCount: 0,
            summaryLength: 0,
            tasksExtracted: 0,
            remindersExtracted: 0,
            confidence: 0.0,
            qualityScore: 0.0,
            contentType: .general,
            success: false,
            errorMessage: error.localizedDescription
        )
    }
    
    // MARK: - Statistics Management
    
    private func updateEngineStatistics() {
        let engineGroups = Dictionary(grouping: allPerformanceData, by: { $0.engineName })
        
        for (engineName, data) in engineGroups {
            let statistics = calculateEngineStatistics(engineName: engineName, data: data)
            engineStatistics[engineName] = statistics
        }
        
        // Update usage analytics
        updateUsageAnalytics()
        
        // Update performance trends
        updatePerformanceTrends()
    }
    
    private func calculateEngineStatistics(engineName: String, data: [EnginePerformanceData]) -> EnginePerformanceStatistics {
        let totalRuns = data.count
        let successfulRuns = data.filter { $0.success }.count
        let failedRuns = totalRuns - successfulRuns
        
        let successfulData = data.filter { $0.success }
        
        let averageProcessingTime = successfulData.isEmpty ? 0.0 : successfulData.map { $0.processingTime }.reduce(0, +) / Double(successfulData.count)
        let averageWordsPerSecond = successfulData.isEmpty ? 0.0 : successfulData.map { $0.wordsPerSecond }.reduce(0, +) / Double(successfulData.count)
        let averageConfidence = successfulData.isEmpty ? 0.0 : successfulData.map { $0.confidence }.reduce(0, +) / Double(successfulData.count)
        let averageQualityScore = successfulData.isEmpty ? 0.0 : successfulData.map { $0.qualityScore }.reduce(0, +) / Double(successfulData.count)
        let averageCompressionRatio = successfulData.isEmpty ? 0.0 : successfulData.map { $0.compressionRatio }.reduce(0, +) / Double(successfulData.count)
        
        let totalWordsProcessed = successfulData.map { $0.wordCount }.reduce(0, +)
        let totalTasksExtracted = successfulData.map { $0.tasksExtracted }.reduce(0, +)
        let totalRemindersExtracted = successfulData.map { $0.remindersExtracted }.reduce(0, +)
        
        let contentTypeDistribution = Dictionary(grouping: successfulData, by: { $0.contentType }).mapValues { $0.count }
        
        let recentPerformance = data.sorted { $0.timestamp > $1.timestamp }.prefix(10).map { $0 }
        
        return EnginePerformanceStatistics(
            engineName: engineName,
            totalRuns: totalRuns,
            successfulRuns: successfulRuns,
            failedRuns: failedRuns,
            averageProcessingTime: averageProcessingTime,
            averageWordsPerSecond: averageWordsPerSecond,
            averageConfidence: averageConfidence,
            averageQualityScore: averageQualityScore,
            averageCompressionRatio: averageCompressionRatio,
            totalWordsProcessed: totalWordsProcessed,
            totalTasksExtracted: totalTasksExtracted,
            totalRemindersExtracted: totalRemindersExtracted,
            contentTypeDistribution: contentTypeDistribution,
            recentPerformance: Array(recentPerformance),
            lastUpdated: Date()
        )
    }
    
    // MARK: - Quality Scoring
    
    private func calculateQualityScore(for summary: EnhancedSummaryData) -> Double {
        var score = 0.0
        
        // Summary relevance (40%)
        let summaryRelevance = calculateSummaryRelevance(summary.summary, originalLength: summary.originalLength)
        score += summaryRelevance * 0.4
        
        // Task extraction quality (25%)
        let taskQuality = calculateTaskExtractionQuality(summary.tasks)
        score += taskQuality * 0.25
        
        // Reminder extraction quality (25%)
        let reminderQuality = calculateReminderExtractionQuality(summary.reminders)
        score += reminderQuality * 0.25
        
        // Content classification accuracy (10%)
        let classificationQuality = calculateClassificationQuality(summary.contentType, summary.summary)
        score += classificationQuality * 0.1
        
        return min(score, 1.0)
    }
    
    private func calculateSummaryRelevance(_ summary: String, originalLength: Int) -> Double {
        guard !summary.isEmpty && originalLength > 0 else { return 0.0 }
        
        var score = 0.5 // Base score
        
        // Length appropriateness
        let compressionRatio = Double(summary.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count) / Double(originalLength)
        if compressionRatio >= 0.1 && compressionRatio <= 0.3 {
            score += 0.3 // Good compression ratio
        } else if compressionRatio > 0.3 {
            score += 0.1 // Too verbose
        }
        
        // Content quality indicators
        let sentences = summary.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        let avgSentenceLength = sentences.map { $0.components(separatedBy: .whitespaces).count }.reduce(0, +) / max(sentences.count, 1)
        
        if avgSentenceLength >= 8 && avgSentenceLength <= 20 {
            score += 0.2 // Good sentence length
        }
        
        return min(score, 1.0)
    }
    
    private func calculateTaskExtractionQuality(_ tasks: [TaskItem]) -> Double {
        guard !tasks.isEmpty else { return 0.3 } // No tasks found
        
        let avgConfidence = tasks.map { $0.confidence }.reduce(0, +) / Double(tasks.count)
        let highConfidenceTasks = tasks.filter { $0.confidence >= 0.7 }.count
        let highPriorityTasks = tasks.filter { $0.priority == .high }.count
        
        var score = avgConfidence * 0.6
        score += Double(highConfidenceTasks) / Double(tasks.count) * 0.2
        score += Double(highPriorityTasks) / Double(tasks.count) * 0.2
        
        return min(score, 1.0)
    }
    
    private func calculateReminderExtractionQuality(_ reminders: [ReminderItem]) -> Double {
        guard !reminders.isEmpty else { return 0.3 } // No reminders found
        
        let avgConfidence = reminders.map { $0.confidence }.reduce(0, +) / Double(reminders.count)
        let highConfidenceReminders = reminders.filter { $0.confidence >= 0.7 }.count
        let urgentReminders = reminders.filter { $0.urgency == .immediate }.count
        
        var score = avgConfidence * 0.6
        score += Double(highConfidenceReminders) / Double(reminders.count) * 0.2
        score += Double(urgentReminders) / Double(reminders.count) * 0.2
        
        return min(score, 1.0)
    }
    
    private func calculateClassificationQuality(_ contentType: ContentType, _ summary: String) -> Double {
        // Simple heuristic based on content type and summary characteristics
        switch contentType {
        case .meeting:
            return summary.lowercased().contains("meeting") || summary.lowercased().contains("discussion") ? 0.8 : 0.5
        case .personalJournal:
            return summary.lowercased().contains("feel") || summary.lowercased().contains("think") ? 0.8 : 0.5
        case .technical:
            return summary.lowercased().contains("code") || summary.lowercased().contains("technical") ? 0.8 : 0.5
        case .general:
            return 0.6 // Default for general content
        }
    }
    
    // MARK: - Usage Analytics
    
    private func updateUsageAnalytics() {
        let totalUsage = allPerformanceData.count
        let engineUsage = Dictionary(grouping: allPerformanceData, by: { $0.engineName }).mapValues { $0.count }
        let contentTypeUsage = Dictionary(grouping: allPerformanceData, by: { $0.contentType }).mapValues { $0.count }
        
        // Time-based usage
        let timeBasedUsage = calculateTimeBasedUsage()
        let dayBasedUsage = calculateDayBasedUsage()
        
        let averageSessionLength = calculateAverageSessionLength()
        let mostUsedEngine = engineUsage.max { $0.value < $1.value }?.key
        let leastUsedEngine = engineUsage.min { $0.value < $1.value }?.key
        
        usageAnalytics = EngineUsageAnalytics(
            totalUsage: totalUsage,
            engineUsage: engineUsage,
            contentTypeUsage: contentTypeUsage,
            timeBasedUsage: timeBasedUsage,
            dayBasedUsage: dayBasedUsage,
            averageSessionLength: averageSessionLength,
            mostUsedEngine: mostUsedEngine,
            leastUsedEngine: leastUsedEngine
        )
    }
    
    private func calculateTimeBasedUsage() -> [String: Int] {
        let calendar = Calendar.current
        var hourlyUsage: [String: Int] = [:]
        
        for data in allPerformanceData {
            let hour = calendar.component(.hour, from: data.timestamp)
            let hourString = String(format: "%02d:00", hour)
            hourlyUsage[hourString, default: 0] += 1
        }
        
        return hourlyUsage
    }
    
    private func calculateDayBasedUsage() -> [String: Int] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        var dailyUsage: [String: Int] = [:]
        
        for data in allPerformanceData {
            let dayName = formatter.string(from: data.timestamp)
            dailyUsage[dayName, default: 0] += 1
        }
        
        return dailyUsage
    }
    
    private func calculateAverageSessionLength() -> TimeInterval {
        // Group consecutive operations within 5 minutes as a session
        let sortedData = allPerformanceData.sorted { $0.timestamp < $1.timestamp }
        var sessions: [TimeInterval] = []
        var currentSessionStart: Date?
        
        for data in sortedData {
            if let start = currentSessionStart {
                let timeDiff = data.timestamp.timeIntervalSince(start)
                if timeDiff > 300 { // 5 minutes
                    sessions.append(timeDiff)
                    currentSessionStart = data.timestamp
                }
            } else {
                currentSessionStart = data.timestamp
            }
        }
        
        return sessions.isEmpty ? 0.0 : sessions.reduce(0, +) / Double(sessions.count)
    }
    
    // MARK: - Performance Trends
    
    private func updatePerformanceTrends() {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -trendAnalysisWindow, to: Date()) ?? Date()
        let recentData = allPerformanceData.filter { $0.timestamp >= cutoffDate }
        
        let engineGroups = Dictionary(grouping: recentData, by: { $0.engineName })
        
        performanceTrends.removeAll()
        
        for (engineName, data) in engineGroups {
            let sortedData = data.sorted { $0.timestamp < $1.timestamp }
            
            // Calculate trends for different metrics
            let processingTimeTrend = calculateTrend(values: sortedData.map { $0.processingTime }, timestamps: sortedData.map { $0.timestamp })
            let confidenceTrend = calculateTrend(values: sortedData.map { $0.confidence }, timestamps: sortedData.map { $0.timestamp })
            let qualityTrend = calculateTrend(values: sortedData.map { $0.qualityScore }, timestamps: sortedData.map { $0.timestamp })
            
            performanceTrends.append(contentsOf: [
                PerformanceTrend(engineName: engineName, metric: "Processing Time", values: sortedData.map { $0.processingTime }, timestamps: sortedData.map { $0.timestamp }, trend: processingTimeTrend),
                PerformanceTrend(engineName: engineName, metric: "Confidence", values: sortedData.map { $0.confidence }, timestamps: sortedData.map { $0.timestamp }, trend: confidenceTrend),
                PerformanceTrend(engineName: engineName, metric: "Quality Score", values: sortedData.map { $0.qualityScore }, timestamps: sortedData.map { $0.timestamp }, trend: qualityTrend)
            ])
        }
    }
    
    private func calculateTrend(values: [Double], timestamps: [Date]) -> PerformanceTrend.TrendDirection {
        guard values.count >= 3 else { return .stable }
        
        // Simple linear regression
        let n = Double(values.count)
        let xValues = Array(0..<values.count).map { Double($0) }
        
        let sumX = xValues.reduce(0, +)
        let sumY = values.reduce(0, +)
        let sumXY = zip(xValues, values).map(*).reduce(0, +)
        let sumX2 = xValues.map { $0 * $0 }.reduce(0, +)
        
        let slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX)
        
        if slope > 0.01 {
            return .improving
        } else if slope < -0.01 {
            return .declining
        } else {
            return .stable
        }
    }
    
    // MARK: - Monitoring Control
    
    func startMonitoring() {
        isMonitoring = true
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: statisticsUpdateInterval, repeats: true) { _ in
            Task { @MainActor in
                self.updateEngineStatistics()
            }
        }
        logger.info("Engine performance monitoring started")
    }
    
    func stopMonitoring() {
        isMonitoring = false
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        logger.info("Engine performance monitoring stopped")
    }
    
    // MARK: - Data Persistence
    
    private func savePerformanceData() {
        do {
            let data = try JSONEncoder().encode(allPerformanceData)
            UserDefaults.standard.set(data, forKey: performanceDataKey)
            
            let statisticsData = try JSONEncoder().encode(engineStatistics)
            UserDefaults.standard.set(statisticsData, forKey: statisticsKey)
            
            if let analytics = usageAnalytics {
                let analyticsData = try JSONEncoder().encode(analytics)
                UserDefaults.standard.set(analyticsData, forKey: analyticsKey)
            }
        } catch {
            logger.error("Failed to save performance data: \(error)")
        }
    }
    
    private func loadPerformanceData() {
        // Load performance data
        if let data = UserDefaults.standard.data(forKey: performanceDataKey) {
            do {
                allPerformanceData = try JSONDecoder().decode([EnginePerformanceData].self, from: data)
            } catch {
                logger.error("Failed to load performance data: \(error)")
            }
        }
        
        // Load statistics
        if let data = UserDefaults.standard.data(forKey: statisticsKey) {
            do {
                engineStatistics = try JSONDecoder().decode([String: EnginePerformanceStatistics].self, from: data)
            } catch {
                logger.error("Failed to load engine statistics: \(error)")
            }
        }
        
        // Load analytics
        if let data = UserDefaults.standard.data(forKey: analyticsKey) {
            do {
                usageAnalytics = try JSONDecoder().decode(EngineUsageAnalytics.self, from: data)
            } catch {
                logger.error("Failed to load usage analytics: \(error)")
            }
        }
    }
    
    // MARK: - Public Interface
    
    func getEngineComparisonData(timeRange: DateInterval? = nil) -> EngineComparisonData {
        let effectiveTimeRange = timeRange ?? DateInterval(start: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date(), duration: 7 * 24 * 3600)
        
        let filteredData = allPerformanceData.filter { effectiveTimeRange.contains($0.timestamp) }
        let engineGroups = Dictionary(grouping: filteredData, by: { $0.engineName })
        
        let engines = Array(engineGroups.keys).sorted()
        var metrics: [String: [Double]] = [:]
        
        for engine in engines {
            let data = engineGroups[engine] ?? []
            let successfulData = data.filter { $0.success }
            
            if !successfulData.isEmpty {
                let avgProcessingTime = successfulData.map { $0.processingTime }.reduce(0, +) / Double(successfulData.count)
                let avgQualityScore = successfulData.map { $0.qualityScore }.reduce(0, +) / Double(successfulData.count)
                let successRate = Double(successfulData.count) / Double(data.count)
                
                metrics["processingTime", default: []].append(avgProcessingTime)
                metrics["qualityScore", default: []].append(avgQualityScore)
                metrics["successRate", default: []].append(successRate)
            } else {
                metrics["processingTime", default: []].append(0.0)
                metrics["qualityScore", default: []].append(0.0)
                metrics["successRate", default: []].append(0.0)
            }
        }
        
        return EngineComparisonData(engines: engines, metrics: metrics, timeRange: effectiveTimeRange)
    }
    
    func clearPerformanceData() {
        allPerformanceData.removeAll()
        recentPerformance.removeAll()
        engineStatistics.removeAll()
        performanceTrends.removeAll()
        usageAnalytics = nil
        
        UserDefaults.standard.removeObject(forKey: performanceDataKey)
        UserDefaults.standard.removeObject(forKey: statisticsKey)
        UserDefaults.standard.removeObject(forKey: analyticsKey)
        
        logger.info("Performance data cleared")
    }
} 