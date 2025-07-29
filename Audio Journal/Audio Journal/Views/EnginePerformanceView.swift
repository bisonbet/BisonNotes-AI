//
//  EnginePerformanceView.swift
//  Audio Journal
//
//  Engine performance monitoring and statistics dashboard
//

import SwiftUI
import Charts

struct EnginePerformanceView: View {
    @ObservedObject var summaryManager: SummaryManager
    @State private var selectedTimeRange: TimeRange = .week
    @State private var selectedEngine: String?
    @State private var showingClearDataAlert = false
    
    enum TimeRange: String, CaseIterable {
        case day = "24 Hours"
        case week = "7 Days"
        case month = "30 Days"
        case all = "All Time"
        
        var dateInterval: DateInterval {
            let now = Date()
            let calendar = Calendar.current
            
            switch self {
            case .day:
                let start = calendar.date(byAdding: .day, value: -1, to: now) ?? now
                return DateInterval(start: start, duration: 24 * 3600)
            case .week:
                let start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
                return DateInterval(start: start, duration: 7 * 24 * 3600)
            case .month:
                let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
                return DateInterval(start: start, duration: 30 * 24 * 3600)
            case .all:
                let start = calendar.date(byAdding: .year, value: -1, to: now) ?? now
                return DateInterval(start: start, duration: 365 * 24 * 3600)
            }
        }
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header with controls
                    headerSection
                    
                    // Engine Statistics Overview
                    engineStatisticsSection
                    
                    // Performance Trends
                    performanceTrendsSection
                    
                    // Usage Analytics
                    usageAnalyticsSection
                    
                    // Recent Performance
                    recentPerformanceSection
                    
                    // Engine Comparison
                    engineComparisonSection
                }
                .padding()
            }
            .navigationTitle("Engine Performance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear Data") {
                        showingClearDataAlert = true
                    }
                    .foregroundColor(.red)
                }
            }
            .alert("Clear Performance Data", isPresented: $showingClearDataAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    summaryManager.clearPerformanceData()
                }
            } message: {
                Text("This will permanently delete all performance tracking data. This action cannot be undone.")
            }
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Time Range")
                    .font(.headline)
                
                Spacer()
                
                Picker("Time Range", selection: $selectedTimeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.menu)
            }
            
            HStack {
                Text("Monitoring Status")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(summaryManager.isPerformanceMonitoringEnabled() ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    
                    Text(summaryManager.isPerformanceMonitoringEnabled() ? "Active" : "Inactive")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    // MARK: - Engine Statistics Section
    
    private var engineStatisticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Engine Statistics")
                .font(.headline)
            
            let statistics = summaryManager.getEnginePerformanceStatistics()
            
            if statistics.isEmpty {
                Text("No performance data available")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    ForEach(Array(statistics.keys.sorted()), id: \.self) { engineName in
                        if let stats = statistics[engineName] {
                            EngineStatsCard(statistics: stats)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    // MARK: - Performance Trends Section
    
    private var performanceTrendsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Performance Trends")
                .font(.headline)
            
            let trends = summaryManager.getPerformanceTrends()
            
            if trends.isEmpty {
                Text("No trend data available")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(trends.prefix(6)) { trend in
                        TrendRow(trend: trend)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    // MARK: - Usage Analytics Section
    
    private var usageAnalyticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage Analytics")
                .font(.headline)
            
            if let analytics = summaryManager.getUsageAnalytics() {
                VStack(spacing: 16) {
                    // Usage Distribution
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Engine Usage Distribution")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        ForEach(Array(analytics.engineUsage.keys.sorted()), id: \.self) { engine in
                            HStack {
                                Text(engine)
                                    .font(.caption)
                                
                                Spacer()
                                
                                Text("\(analytics.engineUsage[engine] ?? 0)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                
                                Text("(\(String(format: "%.1f", (analytics.usageDistribution[engine] ?? 0) * 100))%)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    // Popular Content Types
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Content Type Usage")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        ForEach(Array(analytics.contentTypeUsage.keys.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { contentType in
                            HStack {
                                Text(contentType.rawValue)
                                    .font(.caption)
                                
                                Spacer()
                                
                                Text("\(analytics.contentTypeUsage[contentType] ?? 0)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                    
                    // Usage Patterns
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Most Used Engine")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(analytics.mostUsedEngine ?? "None")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Peak Usage Hour")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(analytics.peakUsageHour ?? "None")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                    }
                }
            } else {
                Text("No usage analytics available")
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    // MARK: - Recent Performance Section
    
    private var recentPerformanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Performance")
                .font(.headline)
            
            let recentData = summaryManager.getRecentPerformanceData()
            
            if recentData.isEmpty {
                Text("No recent performance data")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(recentData.prefix(10)) { data in
                        RecentPerformanceRow(data: data)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    // MARK: - Engine Comparison Section
    
    private var engineComparisonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Engine Comparison")
                .font(.headline)
            
            let comparison = summaryManager.getEngineComparisonData(timeRange: selectedTimeRange.dateInterval)
            
            if comparison.engines.isEmpty {
                Text("No comparison data available")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                VStack(spacing: 16) {
                    // Best Engine
                    if let bestEngine = comparison.bestEngine {
                        ComparisonMetricRow(
                            title: "Best Quality",
                            value: bestEngine,
                            icon: "star.fill",
                            color: .yellow
                        )
                    }
                    
                    // Fastest Engine
                    if let fastestEngine = comparison.fastestEngine {
                        ComparisonMetricRow(
                            title: "Fastest Processing",
                            value: fastestEngine,
                            icon: "speedometer",
                            color: .green
                        )
                    }
                    
                    // Most Reliable Engine
                    if let mostReliableEngine = comparison.mostReliableEngine {
                        ComparisonMetricRow(
                            title: "Most Reliable",
                            value: mostReliableEngine,
                            icon: "checkmark.circle.fill",
                            color: .blue
                        )
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Supporting Views

struct EngineStatsCard: View {
    let statistics: EnginePerformanceStatistics
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statistics.engineName)
                .font(.subheadline)
                .fontWeight(.medium)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Success Rate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(statistics.formattedSuccessRate)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("Avg Time")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(statistics.formattedAverageProcessingTime)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("Quality")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(statistics.formattedAverageQualityScore)
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
            
            // Performance level indicator
            HStack {
                Circle()
                    .fill(performanceColor)
                    .frame(width: 8, height: 8)
                
                Text(statistics.performanceLevel.rawValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
    
    private var performanceColor: Color {
        switch statistics.performanceLevel {
        case .excellent: return .green
        case .good: return .blue
        case .fair: return .orange
        case .poor: return .red
        }
    }
}

struct TrendRow: View {
    let trend: PerformanceTrend
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(trend.engineName) - \(trend.metric)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("Average: \(trend.formattedAverageValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                Image(systemName: trendIcon)
                    .foregroundColor(trendColor)
                
                Text(trend.trend.rawValue)
                    .font(.caption)
                    .foregroundColor(trendColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
    
    private var trendIcon: String {
        switch trend.trend {
        case .improving: return "arrow.up.circle.fill"
        case .declining: return "arrow.down.circle.fill"
        case .stable: return "minus.circle.fill"
        }
    }
    
    private var trendColor: Color {
        switch trend.trend {
        case .improving: return .green
        case .declining: return .red
        case .stable: return .blue
        }
    }
}

struct RecentPerformanceRow: View {
    let data: EnginePerformanceData
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(data.engineName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(data.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text(data.formattedProcessingTime)
                    .font(.caption)
                    .fontWeight(.medium)
                
                Text(data.success ? "Success" : "Failed")
                    .font(.caption2)
                    .foregroundColor(data.success ? .green : .red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
}

struct ComparisonMetricRow: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            
            Text(title)
                .font(.subheadline)
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
} 