//
//  EnginePerformanceData.swift
//  Audio Journal
//
//  Engine performance monitoring and statistics data structures
//

import Foundation

// MARK: - Engine Performance Data

struct EnginePerformanceData: Codable, Identifiable {
    let id: UUID
    let engineName: String
    let timestamp: Date
    let processingTime: TimeInterval
    let textLength: Int
    let wordCount: Int
    let tokenCount: Int
    let summaryLength: Int
    let tasksExtracted: Int
    let remindersExtracted: Int
    let confidence: Double
    let qualityScore: Double
    let contentType: ContentType
    let success: Bool
    let errorMessage: String?
    
    init(engineName: String, processingTime: TimeInterval, textLength: Int, wordCount: Int, tokenCount: Int, summaryLength: Int, tasksExtracted: Int, remindersExtracted: Int, confidence: Double, qualityScore: Double, contentType: ContentType, success: Bool, errorMessage: String? = nil) {
        self.id = UUID()
        self.engineName = engineName
        self.timestamp = Date()
        self.processingTime = processingTime
        self.textLength = textLength
        self.wordCount = wordCount
        self.tokenCount = tokenCount
        self.summaryLength = summaryLength
        self.tasksExtracted = tasksExtracted
        self.remindersExtracted = remindersExtracted
        self.confidence = confidence
        self.qualityScore = qualityScore
        self.contentType = contentType
        self.success = success
        self.errorMessage = errorMessage
    }
    
    var wordsPerSecond: Double {
        return processingTime > 0 ? Double(wordCount) / processingTime : 0.0
    }
    
    var tokensPerSecond: Double {
        return processingTime > 0 ? Double(tokenCount) / processingTime : 0.0
    }
    
    var compressionRatio: Double {
        return wordCount > 0 ? Double(summaryLength) / Double(wordCount) : 0.0
    }
    
    var formattedProcessingTime: String {
        return String(format: "%.2fs", processingTime)
    }
    
    var formattedWordsPerSecond: String {
        return String(format: "%.1f words/s", wordsPerSecond)
    }
    
    var formattedConfidence: String {
        return String(format: "%.1f%%", confidence * 100)
    }
    
    var formattedQualityScore: String {
        return String(format: "%.1f%%", qualityScore * 100)
    }
}

// MARK: - Engine Performance Statistics

struct EnginePerformanceStatistics: Codable {
    let engineName: String
    let totalRuns: Int
    let successfulRuns: Int
    let failedRuns: Int
    let averageProcessingTime: TimeInterval
    let averageWordsPerSecond: Double
    let averageConfidence: Double
    let averageQualityScore: Double
    let averageCompressionRatio: Double
    let totalWordsProcessed: Int
    let totalTasksExtracted: Int
    let totalRemindersExtracted: Int
    let contentTypeDistribution: [ContentType: Int]
    let recentPerformance: [EnginePerformanceData]
    let lastUpdated: Date
    
    var successRate: Double {
        return totalRuns > 0 ? Double(successfulRuns) / Double(totalRuns) : 0.0
    }
    
    var formattedSuccessRate: String {
        return String(format: "%.1f%%", successRate * 100)
    }
    
    var formattedAverageProcessingTime: String {
        return String(format: "%.2fs", averageProcessingTime)
    }
    
    var formattedAverageWordsPerSecond: String {
        return String(format: "%.1f words/s", averageWordsPerSecond)
    }
    
    var formattedAverageConfidence: String {
        return String(format: "%.1f%%", averageConfidence * 100)
    }
    
    var formattedAverageQualityScore: String {
        return String(format: "%.1f%%", averageQualityScore * 100)
    }
    
    var formattedAverageCompressionRatio: String {
        return String(format: "%.1f%%", averageCompressionRatio * 100)
    }
    
    var performanceLevel: PerformanceLevel {
        switch successRate {
        case 0.9...1.0: return .excellent
        case 0.7..<0.9: return .good
        case 0.5..<0.7: return .fair
        default: return .poor
        }
    }
}

// MARK: - Performance Level

enum PerformanceLevel: String, CaseIterable {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
    
    var color: String {
        switch self {
        case .excellent: return "green"
        case .good: return "blue"
        case .fair: return "orange"
        case .poor: return "red"
        }
    }
    
    var description: String {
        switch self {
        case .excellent: return "High success rate and performance"
        case .good: return "Good performance with minor issues"
        case .fair: return "Acceptable performance with some issues"
        case .poor: return "Poor performance, needs attention"
        }
    }
}

// MARK: - Engine Comparison Data

struct EngineComparisonData: Codable {
    let engines: [String]
    let metrics: [String: [Double]]
    let timeRange: DateInterval
    
    var bestEngine: String? {
        guard !engines.isEmpty else { return nil }
        
        // Find engine with highest average quality score
        if let qualityScores = metrics["qualityScore"] {
            let maxIndex = qualityScores.enumerated().max { $0.element < $1.element }?.offset
            return maxIndex.map { engines[$0] }
        }
        
        return nil
    }
    
    var fastestEngine: String? {
        guard !engines.isEmpty else { return nil }
        
        // Find engine with lowest average processing time
        if let processingTimes = metrics["processingTime"] {
            let minIndex = processingTimes.enumerated().min { $0.element < $1.element }?.offset
            return minIndex.map { engines[$0] }
        }
        
        return nil
    }
    
    var mostReliableEngine: String? {
        guard !engines.isEmpty else { return nil }
        
        // Find engine with highest success rate
        if let successRates = metrics["successRate"] {
            let maxIndex = successRates.enumerated().max { $0.element < $1.element }?.offset
            return maxIndex.map { engines[$0] }
        }
        
        return nil
    }
}

// MARK: - Quality Metrics

struct QualityMetrics: Codable {
    let summaryRelevance: Double
    let taskAccuracy: Double
    let reminderAccuracy: Double
    let contentClassificationAccuracy: Double
    let overallQuality: Double
    
    init(summaryRelevance: Double, taskAccuracy: Double, reminderAccuracy: Double, contentClassificationAccuracy: Double) {
        self.summaryRelevance = summaryRelevance
        self.taskAccuracy = taskAccuracy
        self.reminderAccuracy = reminderAccuracy
        self.contentClassificationAccuracy = contentClassificationAccuracy
        
        // Calculate overall quality as weighted average
        self.overallQuality = (summaryRelevance * 0.4 + taskAccuracy * 0.25 + reminderAccuracy * 0.25 + contentClassificationAccuracy * 0.1)
    }
    
    var formattedSummaryRelevance: String {
        return String(format: "%.1f%%", summaryRelevance * 100)
    }
    
    var formattedTaskAccuracy: String {
        return String(format: "%.1f%%", taskAccuracy * 100)
    }
    
    var formattedReminderAccuracy: String {
        return String(format: "%.1f%%", reminderAccuracy * 100)
    }
    
    var formattedContentClassificationAccuracy: String {
        return String(format: "%.1f%%", contentClassificationAccuracy * 100)
    }
    
    var formattedOverallQuality: String {
        return String(format: "%.1f%%", overallQuality * 100)
    }
}

// MARK: - Performance Trends

struct PerformanceTrend: Codable, Identifiable {
    let id = UUID()
    let engineName: String
    let metric: String
    let values: [Double]
    let timestamps: [Date]
    let trend: TrendDirection
    
    enum CodingKeys: String, CodingKey {
        case engineName, metric, values, timestamps, trend
    }
    
    enum TrendDirection: String, Codable {
        case improving = "Improving"
        case declining = "Declining"
        case stable = "Stable"
        
        var color: String {
            switch self {
            case .improving: return "green"
            case .declining: return "red"
            case .stable: return "blue"
            }
        }
    }
    
    var averageValue: Double {
        return values.isEmpty ? 0.0 : values.reduce(0, +) / Double(values.count)
    }
    
    var formattedAverageValue: String {
        return String(format: "%.2f", averageValue)
    }
}

// MARK: - Engine Usage Analytics

struct EngineUsageAnalytics: Codable {
    let totalUsage: Int
    let engineUsage: [String: Int]
    let contentTypeUsage: [ContentType: Int]
    let timeBasedUsage: [String: Int] // Hour of day
    let dayBasedUsage: [String: Int] // Day of week
    let averageSessionLength: TimeInterval
    let mostUsedEngine: String?
    let leastUsedEngine: String?
    
    var usageDistribution: [String: Double] {
        let total = Double(totalUsage)
        return engineUsage.mapValues { Double($0) / total }
    }
    
    var formattedAverageSessionLength: String {
        let minutes = Int(averageSessionLength / 60)
        let seconds = Int(averageSessionLength.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(seconds)s"
    }
    
    var mostPopularContentType: ContentType? {
        return contentTypeUsage.max { $0.value < $1.value }?.key
    }
    
    var peakUsageHour: String? {
        return timeBasedUsage.max { $0.value < $1.value }?.key
    }
    
    var peakUsageDay: String? {
        return dayBasedUsage.max { $0.value < $1.value }?.key
    }
} 