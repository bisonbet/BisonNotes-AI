//
//  SummaryRegenerationManager.swift
//  Audio Journal
//
//  Handles regeneration of summaries when settings change
//

import Foundation
import SwiftUI

// MARK: - Summary Regeneration Manager

@MainActor
class SummaryRegenerationManager: ObservableObject {
    
    @Published var isRegenerating = false
    @Published var regenerationProgress: Double = 0.0
    @Published var currentlyProcessing: String = ""
    @Published var regenerationResults: RegenerationResults?
    @Published var showingRegenerationAlert = false
    
    private let summaryManager: SummaryManager
    private let transcriptManager: TranscriptManager
    
    init(summaryManager: SummaryManager, transcriptManager: TranscriptManager) {
        self.summaryManager = summaryManager
        self.transcriptManager = transcriptManager
    }
    
    // MARK: - Regeneration Methods
    
    func regenerateAllSummaries() async {
        guard !isRegenerating else { return }
        
        isRegenerating = true
        regenerationProgress = 0.0
        currentlyProcessing = "Preparing..."
        
        let summariesToRegenerate = summaryManager.enhancedSummaries
        let totalCount = summariesToRegenerate.count
        
        guard totalCount > 0 else {
            completeRegeneration(with: RegenerationResults(total: 0, successful: 0, failed: 0, errors: []))
            return
        }
        
        var successful = 0
        var failed = 0
        var errors: [String] = []
        
        for (index, summary) in summariesToRegenerate.enumerated() {
            currentlyProcessing = "Processing \(summary.recordingName)..."
            regenerationProgress = Double(index) / Double(totalCount)
            
            // Get transcript for this recording
            if let transcript = transcriptManager.getTranscript(for: summary.recordingURL) {
                do {
                    _ = try await summaryManager.generateEnhancedSummary(
                        from: transcript.plainText,
                        for: summary.recordingURL,
                        recordingName: summary.recordingName,
                        recordingDate: summary.recordingDate
                    )
                    successful += 1
                } catch {
                    failed += 1
                    errors.append("\(summary.recordingName): \(error.localizedDescription)")
                }
            } else {
                failed += 1
                errors.append("\(summary.recordingName): No transcript found")
            }
            
            // Small delay to show progress
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        regenerationProgress = 1.0
        currentlyProcessing = "Complete"
        
        let results = RegenerationResults(
            total: totalCount,
            successful: successful,
            failed: failed,
            errors: errors
        )
        
        completeRegeneration(with: results)
    }
    
    func regenerateSummary(for recordingURL: URL) async -> Bool {
        guard let summary = summaryManager.getEnhancedSummary(for: recordingURL),
              let transcript = transcriptManager.getTranscript(for: recordingURL) else {
            return false
        }
        
        do {
            _ = try await summaryManager.generateEnhancedSummary(
                from: transcript.plainText,
                for: recordingURL,
                recordingName: summary.recordingName,
                recordingDate: summary.recordingDate
            )
            return true
        } catch {
            print("Failed to regenerate summary for \(summary.recordingName): \(error)")
            return false
        }
    }
    
    func shouldPromptForRegeneration(oldEngine: String, newEngine: String) -> Bool {
        return oldEngine != newEngine && summaryManager.enhancedSummaries.count > 0
    }
    
    private func completeRegeneration(with results: RegenerationResults) {
        regenerationResults = results
        isRegenerating = false
        showingRegenerationAlert = true
    }
    
    // MARK: - Progress Tracking
    
    var progressText: String {
        if isRegenerating {
            return "\(Int(regenerationProgress * 100))% - \(currentlyProcessing)"
        }
        return ""
    }
    
    var canRegenerate: Bool {
        return !isRegenerating && summaryManager.enhancedSummaries.count > 0
    }
}

// MARK: - Supporting Structures

struct RegenerationResults {
    let total: Int
    let successful: Int
    let failed: Int
    let errors: [String]
    
    var successRate: Double {
        return total > 0 ? Double(successful) / Double(total) : 0.0
    }
    
    var formattedSuccessRate: String {
        return String(format: "%.1f%%", successRate * 100)
    }
    
    var summary: String {
        if total == 0 {
            return "No summaries to regenerate"
        } else if failed == 0 {
            return "Successfully regenerated all \(total) summaries"
        } else {
            return "Regenerated \(successful) of \(total) summaries (\(failed) failed)"
        }
    }
}

// MARK: - Settings Integration Views

struct RegenerationProgressView: View {
    @ObservedObject var regenerationManager: SummaryRegenerationManager
    
    var body: some View {
        VStack(spacing: 16) {
            if regenerationManager.isRegenerating {
                VStack(spacing: 12) {
                    ProgressView(value: regenerationManager.regenerationProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                    
                    Text(regenerationManager.progressText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
        }
    }
}

struct RegenerationAlertView: View {
    let results: RegenerationResults
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Regeneration Complete")
                .font(.headline)
            
            Text(results.summary)
                .font(.body)
                .multilineTextAlignment(.center)
            
            if !results.errors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Errors:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    ForEach(results.errors.prefix(3), id: \.self) { error in
                        Text("• \(error)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    if results.errors.count > 3 {
                        Text("... and \(results.errors.count - 3) more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }
            
            Button("OK") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Engine Change Prompt

struct EngineChangePromptView: View {
    let oldEngine: String
    let newEngine: String
    let summaryCount: Int
    @Binding var isPresented: Bool
    let onRegenerate: () -> Void
    let onSkip: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Text("AI Engine Changed")
                .font(.headline)
            
            Text("You've switched from \(oldEngine) to \(newEngine).")
                .font(.body)
                .multilineTextAlignment(.center)
            
            Text("Would you like to regenerate your \(summaryCount) existing summaries with the new AI engine?")
                .font(.body)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 12) {
                Button("Skip") {
                    onSkip()
                    isPresented = false
                }
                .buttonStyle(.bordered)
                
                Button("Regenerate") {
                    onRegenerate()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}