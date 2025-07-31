//
//  EnginePerformanceView.swift
//  Audio Journal
//
//  Engine performance monitoring and statistics dashboard
//

import SwiftUI
import Charts

struct EnginePerformanceView: View {
    @StateObject private var summaryManager = SummaryManager.shared
    @StateObject private var performanceOptimizer = PerformanceOptimizer.shared
    @StateObject private var performanceMonitor = EnginePerformanceMonitor()
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Performance Monitoring Status
                    PerformanceMonitoringSection()
                    
                    // Battery and Memory Status
                    BatteryMemorySection()
                    
                    // Optimization Status
                    OptimizationStatusSection()
                    
                    // Engine Statistics
                    EngineStatisticsSection()
                    
                    // Recent Performance
                    RecentPerformanceSection()
                    
                    // Performance Trends
                    PerformanceTrendsSection()
                    
                    // Usage Analytics
                    UsageAnalyticsSection()
                }
                .padding()
            }
            .navigationTitle("Performance Monitor")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Performance Monitoring Section

struct PerformanceMonitoringSection: View {
    @StateObject private var summaryManager = SummaryManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(.blue)
                Text("Performance Monitoring")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(summaryManager.isPerformanceMonitoringEnabled() ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                Text(summaryManager.isPerformanceMonitoringEnabled() ? "Active" : "Inactive")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text("Track engine performance, memory usage, and battery efficiency")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Battery and Memory Section

struct BatteryMemorySection: View {
    @StateObject private var performanceOptimizer = PerformanceOptimizer.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "battery.100")
                    .foregroundColor(.green)
                Text("System Resources")
                    .font(.headline)
                Spacer()
            }
            
            // Battery Status
            HStack {
                Image(systemName: batteryIcon)
                    .foregroundColor(batteryColor)
                Text("Battery: \(performanceOptimizer.batteryInfo.formattedLevel)")
                    .font(.subheadline)
                Spacer()
                if performanceOptimizer.batteryInfo.isLowPowerMode {
                    Text("Low Power Mode")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            // Memory Usage
            HStack {
                Image(systemName: "memorychip")
                    .foregroundColor(memoryColor)
                Text("Memory: \(performanceOptimizer.memoryUsage.formattedUsage)")
                    .font(.subheadline)
                Spacer()
                Text(performanceOptimizer.memoryUsage.usageLevel.description)
                    .font(.caption)
                    .foregroundColor(performanceOptimizer.memoryUsage.usageLevel.color)
            }
            
            // Memory Progress Bar
            ProgressView(value: min(performanceOptimizer.memoryUsage.usedMemoryMB / 200.0, 1.0))
                .progressViewStyle(LinearProgressViewStyle(tint: memoryColor))
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private var batteryIcon: String {
        let level = performanceOptimizer.batteryInfo.level
        switch level {
        case 0.0..<0.2: return "battery.0"
        case 0.2..<0.4: return "battery.25"
        case 0.4..<0.6: return "battery.50"
        case 0.6..<0.8: return "battery.75"
        default: return "battery.100"
        }
    }
    
    private var batteryColor: Color {
        if performanceOptimizer.batteryInfo.isLowBattery {
            return .red
        } else if performanceOptimizer.batteryInfo.shouldOptimizeForBattery {
            return .orange
        } else {
            return .green
        }
    }
    
    private var memoryColor: Color {
        performanceOptimizer.memoryUsage.usageLevel.color
    }
}

// MARK: - Optimization Status Section

struct OptimizationStatusSection: View {
    @StateObject private var performanceOptimizer = PerformanceOptimizer.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gearshape.2")
                    .foregroundColor(.blue)
                Text("Optimization Status")
                    .font(.headline)
                Spacer()
            }
            
            // Current Optimization Level
            HStack {
                Image(systemName: optimizationIcon)
                    .foregroundColor(optimizationColor)
                Text("Mode: \(performanceOptimizer.optimizationLevel.description)")
                    .font(.subheadline)
                Spacer()
            }
            
            // Optimization Details
            VStack(alignment: .leading, spacing: 8) {
                Text("Current Settings:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("• Cache Size: \(cacheSizeDescription)")
                    .font(.caption)
                Text("• Processing QoS: \(qosDescription)")
                    .font(.caption)
                Text("• Sync Interval: \(syncIntervalDescription)")
                    .font(.caption)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private var optimizationIcon: String {
        switch performanceOptimizer.optimizationLevel {
        case .balanced: return "equal.circle"
        case .batteryOptimized: return "battery.25"
        case .memoryOptimized: return "memorychip"
        }
    }
    
    private var optimizationColor: Color {
        switch performanceOptimizer.optimizationLevel {
        case .balanced: return .blue
        case .batteryOptimized: return .orange
        case .memoryOptimized: return .purple
        }
    }
    
    private var cacheSizeDescription: String {
        switch performanceOptimizer.optimizationLevel {
        case .balanced: return "Standard (50 items)"
        case .batteryOptimized: return "Reduced (25 items)"
        case .memoryOptimized: return "Minimal (30 items)"
        }
    }
    
    private var qosDescription: String {
        switch performanceOptimizer.optimizationLevel {
        case .balanced: return "User Initiated"
        case .batteryOptimized: return "Utility"
        case .memoryOptimized: return "User Initiated"
        }
    }
    
    private var syncIntervalDescription: String {
        switch performanceOptimizer.optimizationLevel {
        case .balanced: return "3 minutes"
        case .batteryOptimized: return "10 minutes"
        case .memoryOptimized: return "5 minutes"
        }
    }
}

// MARK: - Engine Statistics Section

struct EngineStatisticsSection: View {
    @StateObject private var performanceMonitor = EnginePerformanceMonitor()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar")
                    .foregroundColor(.blue)
                Text("Engine Statistics")
                    .font(.headline)
                Spacer()
            }
            
            let statistics = performanceMonitor.engineStatistics
            
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
}

// MARK: - Recent Performance Section

struct RecentPerformanceSection: View {
    @StateObject private var performanceMonitor = EnginePerformanceMonitor()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.blue)
                Text("Recent Performance")
                    .font(.headline)
                Spacer()
            }
            
            let recentData = performanceMonitor.recentPerformance
            
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
}

// MARK: - Performance Trends Section

struct PerformanceTrendsSection: View {
    @StateObject private var performanceMonitor = EnginePerformanceMonitor()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(.blue)
                Text("Performance Trends")
                    .font(.headline)
                Spacer()
            }
            
            let trends = performanceMonitor.performanceTrends
            
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
}

// MARK: - Usage Analytics Section

struct UsageAnalyticsSection: View {
    @StateObject private var performanceMonitor = EnginePerformanceMonitor()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.pie")
                    .foregroundColor(.blue)
                Text("Usage Analytics")
                    .font(.headline)
                Spacer()
            }
            
            if let analytics = performanceMonitor.usageAnalytics {
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
                    Text("Success Rate:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(statistics.formattedSuccessRate)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("Avg Time:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(statistics.formattedAverageProcessingTime)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("Total Uses:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(statistics.totalRuns)")
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
    }
}

struct RecentPerformanceRow: View {
    let data: EnginePerformanceData
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(data.engineName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("Processing")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                Text(data.formattedProcessingTime)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(data.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct TrendRow: View {
    let trend: PerformanceTrend
    
    var body: some View {
        HStack {
            Image(systemName: trendIcon)
                .foregroundColor(trendColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("\(trend.engineName) - \(trend.metric)")
                    .font(.subheadline)
                
                Text("Average: \(trend.formattedAverageValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                Image(systemName: trendIcon)
                    .foregroundColor(trendColor)
                
                Text(trend.trend.rawValue)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(trendColor)
            }
        }
        .padding(.vertical, 4)
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