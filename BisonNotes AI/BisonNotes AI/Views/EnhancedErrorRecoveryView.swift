//
//  EnhancedErrorRecoveryView.swift
//  Audio Journal
//
//  User-friendly error recovery view for audio processing enhancements
//

import SwiftUI
import os.log

struct EnhancedErrorRecoveryView: View {
    @StateObject private var errorHandler = EnhancedErrorHandler()
    @StateObject private var recoveryManager = EnhancedErrorRecoveryManager()
    @State private var showingRecoveryOptions = false
    @State private var selectedError: EnhancedAppError?
    @State private var showingManualRecovery = false
    
    var body: some View {
        NavigationView {
            VStack {
                if recoveryManager.isRecovering {
                    RecoveryProgressView(recoveryManager: recoveryManager)
                } else {
                    ErrorRecoveryContentView(
                        errorHandler: errorHandler,
                        recoveryManager: recoveryManager,
                        showingRecoveryOptions: $showingRecoveryOptions,
                        selectedError: $selectedError,
                        showingManualRecovery: $showingManualRecovery
                    )
                }
            }
            .navigationTitle("Error Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear History") {
                        errorHandler.clearErrorHistory()
                        recoveryManager.recoveryHistory.removeAll()
                    }
                }
            }
        }
        .sheet(isPresented: $showingRecoveryOptions) {
            if let error = selectedError {
                RecoveryOptionsView(
                    error: error,
                    recoveryManager: recoveryManager
                )
            }
        }
        .sheet(isPresented: $showingManualRecovery) {
            ManualRecoveryView(recoveryManager: recoveryManager)
        }
    }
}

// MARK: - Recovery Progress View

struct RecoveryProgressView: View {
    @ObservedObject var recoveryManager: EnhancedErrorRecoveryManager
    
    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: recoveryManager.recoveryProgress)
                .progressViewStyle(LinearProgressViewStyle())
                .scaleEffect(1.2)
            
            Text("Recovering...")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text(recoveryManager.currentRecoveryStep)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - Error Recovery Content View

struct ErrorRecoveryContentView: View {
    @ObservedObject var errorHandler: EnhancedErrorHandler
    @ObservedObject var recoveryManager: EnhancedErrorRecoveryManager
    @Binding var showingRecoveryOptions: Bool
    @Binding var selectedError: EnhancedAppError?
    @Binding var showingManualRecovery: Bool
    
    var body: some View {
        List {
            if errorHandler.errorHistory.isEmpty {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        
                        Text("No Errors")
                            .font(.headline)
                        
                        Text("Your audio processing system is running smoothly with no recent errors.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            } else {
                Section("Recent Errors") {
                    ForEach(errorHandler.errorHistory.prefix(5)) { entry in
                        EnhancedErrorHistoryRow(entry: entry)
                            .onTapGesture {
                                selectedError = entry.error
                                showingRecoveryOptions = true
                            }
                    }
                }
                
                Section("Recovery History") {
                    if recoveryManager.recoveryHistory.isEmpty {
                        Text("No recovery attempts yet")
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        ForEach(recoveryManager.recoveryHistory.prefix(5)) { attempt in
                            RecoveryHistoryRow(attempt: attempt)
                        }
                    }
                }
            }
            
            Section("Actions") {
                Button("Manual Recovery") {
                    showingManualRecovery = true
                }
                .foregroundColor(.blue)
                
                Button("Generate Diagnostic Report") {
                    generateDiagnosticReport()
                }
                .foregroundColor(.blue)
                
                Button("Test Error Recovery") {
                    testErrorRecovery()
                }
                .foregroundColor(.orange)
            }
        }
    }
    
    private func generateDiagnosticReport() {
        // Implementation for generating diagnostic report
    }
    
    private func testErrorRecovery() {
        // Create a test error to demonstrate recovery
        let testError = EnhancedAppError.audioProcessing(.audioSessionConfigurationFailed("Test error"))
        Task {
            await recoveryManager.attemptRecovery(for: testError, context: "Test Recovery")
        }
    }
}

// MARK: - Recovery Options View

struct RecoveryOptionsView: View {
    let error: EnhancedAppError
    @ObservedObject var recoveryManager: EnhancedErrorRecoveryManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Error Information
                VStack(spacing: 12) {
                    Image(systemName: errorIcon)
                        .font(.system(size: 48))
                        .foregroundColor(errorColor)
                    
                    Text(error.errorDescription ?? "Unknown Error")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    
                    if let suggestion = error.recoverySuggestion {
                        Text(suggestion)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                
                // Recovery Options
                VStack(spacing: 12) {
                    Button("Automatic Recovery") {
                        Task {
                            _ = await recoveryManager.attemptRecovery(for: error, context: "User Initiated")
                            dismiss()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    
                    Button("Manual Recovery") {
                        // Show manual recovery options
                        dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    
                    Button("Ignore Error") {
                        dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding()
                
                Spacer()
            }
            .navigationTitle("Recovery Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var errorIcon: String {
        switch error.severity {
        case .low: return "info.circle.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .high: return "xmark.circle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
    
    private var errorColor: Color {
        switch error.severity {
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        case .critical: return .purple
        }
    }
}

// MARK: - Manual Recovery View

struct ManualRecoveryView: View {
    @ObservedObject var recoveryManager: EnhancedErrorRecoveryManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRecoveryType: ManualRecoveryType = .audioSession
    
    var body: some View {
        NavigationView {
            List {
                Section("Recovery Type") {
                    Picker("Recovery Type", selection: $selectedRecoveryType) {
                        ForEach(ManualRecoveryType.allCases, id: \.self) { type in
                            Text(type.description).tag(type)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                
                Section("Recovery Steps") {
                    ForEach(selectedRecoveryType.steps, id: \.self) { step in
                        HStack {
                            Image(systemName: "circle")
                                .foregroundColor(.secondary)
                            
                            Text(step)
                                .font(.body)
                            
                            Spacer()
                        }
                    }
                }
                
                Section("Actions") {
                    Button("Start Manual Recovery") {
                        startManualRecovery()
                    }
                    .foregroundColor(.blue)
                    
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Manual Recovery")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func startManualRecovery() {
        // Implementation for manual recovery
        dismiss()
    }
}

// MARK: - Recovery History Row

struct RecoveryHistoryRow: View {
    let attempt: RecoveryAttempt
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(attempt.error.errorDescription ?? "Unknown Error")
                    .font(.headline)
                    .lineLimit(1)
                
                Spacer()
                
                RecoveryStatusBadge(status: attempt.status)
            }
            
            Text(attempt.context)
                .font(.caption)
                .foregroundColor(.secondary)
            
            if let action = attempt.recoveryAction {
                Text("Action: \(action)")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            
            if let duration = attempt.duration {
                Text("Duration: \(String(format: "%.1f", duration))s")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RecoveryStatusBadge: View {
    let status: RecoveryStatus
    
    var body: some View {
        Text(status.displayName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor)
            .foregroundColor(.white)
            .cornerRadius(4)
    }
    
    private var statusColor: Color {
        switch status {
        case .inProgress: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

extension RecoveryStatus {
    var displayName: String {
        switch self {
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

// MARK: - Manual Recovery Types

enum ManualRecoveryType: CaseIterable {
    case audioSession
    case backgroundProcessing
    case chunking
    case iCloudSync
    case fileManagement
    
    var description: String {
        switch self {
        case .audioSession: return "Audio Session"
        case .backgroundProcessing: return "Background Processing"
        case .chunking: return "File Chunking"
        case .iCloudSync: return "iCloud Sync"
        case .fileManagement: return "File Management"
        }
    }
    
    var steps: [String] {
        switch self {
        case .audioSession:
            return [
                "Check device audio settings",
                "Restart the app",
                "Test audio recording",
                "Verify microphone permissions"
            ]
        case .backgroundProcessing:
            return [
                "Check background app refresh",
                "Close other apps",
                "Restart the app",
                "Try processing in foreground"
            ]
        case .chunking:
            return [
                "Check available storage",
                "Verify file format",
                "Try shorter recording",
                "Process without chunking"
            ]
        case .iCloudSync:
            return [
                "Check internet connection",
                "Verify iCloud account",
                "Check iCloud settings",
                "Try syncing later"
            ]
        case .fileManagement:
            return [
                "Check file permissions",
                "Verify file location",
                "Re-import files",
                "Free up storage space"
            ]
        }
    }
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.systemGray5))
            .foregroundColor(.primary)
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}



// MARK: - Preview

struct EnhancedErrorRecoveryView_Previews: PreviewProvider {
    static var previews: some View {
        EnhancedErrorRecoveryView()
    }
} 