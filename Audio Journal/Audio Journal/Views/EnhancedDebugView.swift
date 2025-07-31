//
//  EnhancedDebugView.swift
//  Audio Journal
//
//  Debug view for enhanced error handling and logging system
//

import SwiftUI
import os.log

struct EnhancedDebugView: View {
    @StateObject private var errorHandler = EnhancedErrorHandler()
    @StateObject private var logger = EnhancedLogger.shared
    @State private var selectedTab = 0
    @State private var showingDiagnosticReport = false
    @State private var diagnosticReport: DiagnosticReport?
    
    var body: some View {
        NavigationView {
            VStack {
                Picker("Debug Section", selection: $selectedTab) {
                    Text("Error History").tag(0)
                    Text("Logging Config").tag(1)
                    Text("Performance").tag(2)
                    Text("Diagnostics").tag(3)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                TabView(selection: $selectedTab) {
                    EnhancedErrorHistoryView(errorHandler: errorHandler)
                        .tag(0)
                    
                    LoggingConfigView(logger: logger)
                        .tag(1)
                    
                    PerformanceView(logger: logger)
                        .tag(2)
                    
                    DiagnosticsView(logger: logger, diagnosticReport: $diagnosticReport)
                        .tag(3)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            }
            .navigationTitle("Debug Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Export") {
                        exportDebugData()
                    }
                }
            }
        }
        .sheet(isPresented: $showingDiagnosticReport) {
            if let report = diagnosticReport {
                DiagnosticReportView(report: report)
            }
        }
    }
    
    private func exportDebugData() {
        diagnosticReport = logger.generateDiagnosticReport()
        showingDiagnosticReport = true
    }
}

// MARK: - Enhanced Error History View

struct EnhancedErrorHistoryView: View {
    @ObservedObject var errorHandler: EnhancedErrorHandler
    @State private var selectedError: EnhancedErrorLogEntry?
    
    var body: some View {
        List {
            if errorHandler.errorHistory.isEmpty {
                Text("No errors recorded")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(errorHandler.errorHistory) { entry in
                    EnhancedErrorHistoryRow(entry: entry)
                        .onTapGesture {
                            selectedError = entry
                        }
                }
            }
        }
        .sheet(item: $selectedError) { entry in
            ErrorDetailView(entry: entry)
        }
        .refreshable {
            // Refresh error history
        }
    }
}

struct EnhancedErrorHistoryRow: View {
    let entry: EnhancedErrorLogEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.error.errorDescription ?? "Unknown Error")
                    .font(.headline)
                    .lineLimit(2)
                
                Spacer()
                
                Text(entry.formattedTimestamp)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(entry.context)
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                SeverityBadge(severity: entry.error.severity)
                
                Spacer()
                
                Text(entry.deviceInfo.model)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SeverityBadge: View {
    let severity: ErrorSeverity
    
    var body: some View {
        Text(severity.description)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(severityColor)
            .foregroundColor(.white)
            .cornerRadius(4)
    }
    
    private var severityColor: Color {
        switch severity {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        case .critical: return .purple
        }
    }
}

struct ErrorDetailView: View {
    let entry: EnhancedErrorLogEntry
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Error Information
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Error Details")
                            .font(.headline)
                        
                        Text("Description: \(entry.error.errorDescription ?? "No description")")
                            .font(.body)
                        
                        if let recoverySuggestion = entry.error.recoverySuggestion {
                            Text("Recovery: \(recoverySuggestion)")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("Severity: \(entry.error.severity.description)")
                            .font(.body)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    
                    // Context Information
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Context")
                            .font(.headline)
                        
                        Text("Operation: \(entry.context)")
                            .font(.body)
                        
                        Text("Timestamp: \(entry.formattedTimestamp)")
                            .font(.body)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    
                    // Device Information
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Device Information")
                            .font(.headline)
                        
                        Text("Model: \(entry.deviceInfo.model)")
                            .font(.body)
                        
                        Text("iOS Version: \(entry.deviceInfo.systemVersion)")
                            .font(.body)
                        
                        Text("App Version: \(entry.deviceInfo.appVersion)")
                            .font(.body)
                        
                        Text("Memory Usage: \(entry.deviceInfo.availableMemory)")
                            .font(.body)
                        
                        Text("Storage: \(entry.deviceInfo.availableStorage)")
                            .font(.body)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                .padding()
            }
            .navigationTitle("Error Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Logging Configuration View

struct LoggingConfigView: View {
    @ObservedObject var logger: EnhancedLogger
    @State private var debugConfig = DebugConfiguration()
    
    var body: some View {
        Form {
            Section("Log Level") {
                Picker("Log Level", selection: Binding(
                    get: { logger.currentLevelValue },
                    set: { logger.setLogLevel($0) }
                )) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.description).tag(level)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            
            Section("Debug Mode") {
                Toggle("Enable Debug Mode", isOn: Binding(
                    get: { logger.debugModeValue },
                    set: { logger.setDebugMode($0) }
                ))
                
                Toggle("Performance Tracking", isOn: Binding(
                    get: { logger.performanceTrackingValue },
                    set: { logger.enablePerformanceTracking($0) }
                ))
            }
            
            Section("Logging Categories") {
                ForEach(EnhancedLogCategory.allCases, id: \.self) { category in
                    Toggle(category.rawValue, isOn: Binding(
                        get: { logger.enabledCategoriesValue.contains(category) },
                        set: { isEnabled in
                            if isEnabled {
                                logger.enableCategory(category)
                            } else {
                                logger.disableCategory(category)
                            }
                        }
                    ))
                }
            }
            
            Section("Debug Configuration") {
                Toggle("Verbose Logging", isOn: $debugConfig.enableVerboseLogging)
                Toggle("Memory Tracking", isOn: $debugConfig.enableMemoryTracking)
                Toggle("Storage Tracking", isOn: $debugConfig.enableStorageTracking)
                Toggle("Network Tracking", isOn: $debugConfig.enableNetworkTracking)
                
                Stepper("Max Log History: \(debugConfig.maxLogHistory)", value: $debugConfig.maxLogHistory, in: 100...10000, step: 100)
                Stepper("Log Retention: \(debugConfig.logRetentionDays) days", value: $debugConfig.logRetentionDays, in: 1...30)
            }
        }
        .onAppear {
            debugConfig = DebugConfiguration.load()
        }
        .onChange(of: debugConfig) {
            debugConfig.save()
        }
    }
}

// MARK: - Performance View

struct PerformanceView: View {
    @ObservedObject var logger: EnhancedLogger
    @State private var performanceResults: [PerformanceResult] = []
    
    var body: some View {
        List {
            Section("Performance Tracking") {
                Toggle("Enable Performance Tracking", isOn: Binding(
                    get: { logger.performanceTrackingValue },
                    set: { logger.enablePerformanceTracking($0) }
                ))
                
                if !performanceResults.isEmpty {
                    ForEach(performanceResults, id: \.operation) { result in
                        PerformanceResultRow(result: result)
                    }
                } else {
                    Text("No performance data available")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            }
            
            Section("Actions") {
                Button("Clear Performance Data") {
                    performanceResults.removeAll()
                }
                .foregroundColor(.red)
            }
        }
        .onAppear {
            // Load performance results
        }
    }
}

struct PerformanceResultRow: View {
    let result: PerformanceResult
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.operation)
                .font(.headline)
            
            Text(result.context)
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                Text("Duration: \(String(format: "%.2f", result.duration))s")
                    .font(.caption)
                
                Spacer()
                
                Text("Memory: \(String(format: "%.1f", result.memoryUsage))MB")
                    .font(.caption)
                
                Text("(\(String(format: "%+.1f", result.memoryDelta))MB)")
                    .font(.caption)
                    .foregroundColor(result.memoryDelta > 0 ? .red : .green)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Diagnostics View

struct DiagnosticsView: View {
    @ObservedObject var logger: EnhancedLogger
    @Binding var diagnosticReport: DiagnosticReport?
    @State private var showingReport = false
    
    var body: some View {
        List {
            Section("System Information") {
                HStack {
                    Text("Device Model")
                    Spacer()
                    Text(UIDevice.current.model)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("iOS Version")
                    Spacer()
                    Text(UIDevice.current.systemVersion)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("App Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                        .foregroundColor(.secondary)
                }
            }
            
            Section("Debug Information") {
                Button("Generate Diagnostic Report") {
                    diagnosticReport = logger.generateDiagnosticReport()
                    showingReport = true
                }
                
                Button("Export Debug Data") {
                    exportDebugData()
                }
            }
            
            Section("Logging Status") {
                HStack {
                    Text("Current Log Level")
                    Spacer()
                    Text(logger.currentLevelValue.description)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Debug Mode")
                    Spacer()
                    Text(logger.debugModeValue ? "Enabled" : "Disabled")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Performance Tracking")
                    Spacer()
                    Text(logger.performanceTrackingValue ? "Enabled" : "Disabled")
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingReport) {
            if let report = diagnosticReport {
                DiagnosticReportView(report: report)
            }
        }
    }
    
    private func exportDebugData() {
        // Implementation for exporting debug data
    }
}

// MARK: - Diagnostic Report View

struct DiagnosticReportView: View {
    let report: DiagnosticReport
    @Environment(\.dismiss) private var dismiss
    @State private var showingShareSheet = false
    @State private var reportText = ""
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(report.formattedReport)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                }
            }
            .navigationTitle("Diagnostic Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Share") {
                        reportText = report.formattedReport
                        showingShareSheet = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(activityItems: [reportText])
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Preview

struct EnhancedDebugView_Previews: PreviewProvider {
    static var previews: some View {
        EnhancedDebugView()
    }
} 