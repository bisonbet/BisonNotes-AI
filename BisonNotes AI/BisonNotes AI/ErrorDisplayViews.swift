//
//  ErrorDisplayViews.swift
//  Audio Journal
//
//  UI components for displaying errors and validation results
//

import SwiftUI

// MARK: - Error Alert View

struct ErrorAlertView: View {
    let error: AppError
    let onDismiss: () -> Void
    let onRecoveryAction: (RecoveryAction) -> Void
    
    @StateObject private var errorHandler = ErrorHandler()
    
    var body: some View {
        VStack(spacing: 20) {
            // Error Icon and Title
            VStack(spacing: 8) {
                Image(systemName: errorIcon)
                    .font(.system(size: 40))
                    .foregroundColor(error.severity.color)
                
                Text("Error")
                    .font(.title2)
                    .fontWeight(.bold)
            }
            
            // Error Description
            VStack(spacing: 8) {
                Text(error.localizedDescription)
                    .font(.body)
                    .multilineTextAlignment(.center)
                
                if let recovery = error.recoverySuggestion {
                    Text(recovery)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            
            // Recovery Actions
            let recoveryActions = errorHandler.suggestRecoveryActions(for: error)
            if !recoveryActions.isEmpty {
                VStack(spacing: 12) {
                    Text("Suggested Actions:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(recoveryActions.prefix(4), id: \.self) { action in
                            Button(action.title) {
                                onRecoveryAction(action)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                }
            }
            
            // Dismiss Button
            Button("OK") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(radius: 10)
    }
    
    private var errorIcon: String {
        switch error.severity {
        case .low:
            return "info.circle"
        case .medium:
            return "exclamationmark.triangle"
        case .high:
            return "xmark.circle"
        case .critical:
            return "exclamationmark.octagon"
        }
    }
}

// MARK: - Validation Results View

struct ValidationResultsView: View {
    let result: ValidationResult
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Status Header
                VStack(spacing: 8) {
                    Image(systemName: result.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(result.isValid ? .green : .red)
                    
                    Text(result.summary)
                        .font(.title2)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)
                }
                
                ScrollView {
                    VStack(spacing: 16) {
                        // Issues Section
                        if !result.issues.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Issues")
                                    .font(.headline)
                                    .foregroundColor(.red)
                                
                                ForEach(result.issues, id: \.localizedDescription) { issue in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.caption)
                                        
                                        Text(issue.localizedDescription)
                                            .font(.body)
                                            .fixedSize(horizontal: false, vertical: true)
                                        
                                        Spacer()
                                    }
                                    .padding()
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                        }
                        
                        // Warnings Section
                        if !result.warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Warnings")
                                    .font(.headline)
                                    .foregroundColor(.orange)
                                
                                ForEach(result.warnings, id: \.description) { warning in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                            .font(.caption)
                                        
                                        Text(warning.description)
                                            .font(.body)
                                            .fixedSize(horizontal: false, vertical: true)
                                        
                                        Spacer()
                                    }
                                    .padding()
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                        }
                        
                        // Success Message
                        if result.isValid && result.warnings.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.green)
                                
                                Text("Content is ready for summarization")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                }
                
                Spacer()
            }
            .navigationTitle("Validation Results")
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

// MARK: - Quality Report View

struct QualityReportView: View {
    let report: SummaryQualityReport
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Quality Score Header
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .stroke(Color.gray.opacity(0.3), lineWidth: 8)
                                .frame(width: 100, height: 100)
                            
                            Circle()
                                .trim(from: 0, to: report.score)
                                .stroke(report.qualityLevel.color, lineWidth: 8)
                                .frame(width: 100, height: 100)
                                .rotationEffect(.degrees(-90))
                                .animation(.easeInOut(duration: 1.0), value: report.score)
                            
                            Text(report.formattedScore)
                                .font(.title2)
                                .fontWeight(.bold)
                        }
                        
                        Text(report.qualityLevel.description)
                            .font(.title3)
                            .fontWeight(.medium)
                            .foregroundColor(report.qualityLevel.color)
                    }
                    
                    // Summary Metadata
                    VStack(spacing: 8) {
                        Text("Summary Details")
                            .font(.headline)
                        
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            MetricCard(title: "Confidence", value: String(format: "%.1f%%", report.summary.confidence * 100), icon: "percent")
                            MetricCard(title: "Compression", value: report.summary.formattedCompressionRatio, icon: "arrow.down.circle")
                            MetricCard(title: "Tasks Found", value: "\(report.summary.tasks.count)", icon: "checkmark.circle")
                            MetricCard(title: "Reminders Found", value: "\(report.summary.reminders.count)", icon: "bell")
                            MetricCard(title: "Processing Time", value: report.summary.formattedProcessingTime, icon: "clock")
                            MetricCard(title: "AI Engine", value: report.summary.aiMethod, icon: "brain")
                        }
                    }
                    
                    // Issues Section
                    if !report.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Quality Issues")
                                .font(.headline)
                                .foregroundColor(.red)
                            
                            ForEach(report.issues, id: \.description) { issue in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.caption)
                                    
                                    Text(issue.description)
                                        .font(.body)
                                        .fixedSize(horizontal: false, vertical: true)
                                    
                                    Spacer()
                                }
                                .padding()
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                    }
                    
                    // Suggestions Section
                    if !report.suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Improvement Suggestions")
                                .font(.headline)
                                .foregroundColor(.blue)
                            
                            ForEach(report.suggestions, id: \.description) { suggestion in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "lightbulb.fill")
                                        .foregroundColor(.blue)
                                        .font(.caption)
                                    
                                    Text(suggestion.description)
                                        .font(.body)
                                        .fixedSize(horizontal: false, vertical: true)
                                    
                                    Spacer()
                                }
                                .padding()
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Quality Report")
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

// MARK: - Error History View

struct ErrorHistoryView: View {
    @ObservedObject var errorHandler: ErrorHandler
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            List {
                if errorHandler.errorHistory.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 50))
                            .foregroundColor(.green)
                        
                        Text("No Errors")
                            .font(.title2)
                            .fontWeight(.medium)
                        
                        Text("Your app is running smoothly!")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else {
                    ForEach(errorHandler.errorHistory) { entry in
                        ErrorHistoryRow(entry: entry)
                    }
                }
            }
            .navigationTitle("Error History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") {
                        errorHandler.clearErrorHistory()
                    }
                    .disabled(errorHandler.errorHistory.isEmpty)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

struct ErrorHistoryRow: View {
    let entry: ErrorLogEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: severityIcon)
                    .foregroundColor(entry.error.severity.color)
                    .font(.caption)
                
                Text(entry.context)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Text(entry.formattedTimestamp)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(entry.error.localizedDescription)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            
            if let recovery = entry.error.recoverySuggestion {
                Text(recovery)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
        .padding(.vertical, 4)
    }
    
    private var severityIcon: String {
        switch entry.error.severity {
        case .low: return "info.circle"
        case .medium: return "exclamationmark.triangle"
        case .high: return "xmark.circle"
        case .critical: return "exclamationmark.octagon"
        }
    }
}

// MARK: - Inline Error Display

struct InlineErrorView: View {
    let error: AppError
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Error")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
            
            VStack(spacing: 4) {
                if let onRetry = onRetry {
                    Button("Retry") {
                        onRetry()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                
                Button("Dismiss") {
                    onDismiss()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Loading with Error State

struct LoadingWithErrorView: View {
    let isLoading: Bool
    let error: AppError?
    let onRetry: () -> Void
    let onDismissError: () -> Void
    let content: () -> AnyView
    
    var body: some View {
        ZStack {
            content()
            
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    
                    Text("Processing...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(radius: 8)
            }
            
            if let error = error {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                
                ErrorAlertView(
                    error: error,
                    onDismiss: onDismissError,
                    onRecoveryAction: { action in
                        switch action {
                        case .retryOperation:
                            onRetry()
                        default:
                            onDismissError()
                        }
                    }
                )
            }
        }
    }
}