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
    private let appCoordinator: AppDataCoordinator

    init(summaryManager: SummaryManager, transcriptManager: TranscriptManager, appCoordinator: AppDataCoordinator) {
        self.summaryManager = summaryManager
        self.transcriptManager = transcriptManager
        self.appCoordinator = appCoordinator
    }

    func setEngine(_ engineName: String) {
        summaryManager.setEngine(engineName)
    }

    // MARK: - Regeneration Methods

    func regenerateAllSummaries() async {
        guard !isRegenerating else { return }

        isRegenerating = true
        regenerationProgress = 0.0
        currentlyProcessing = "Preparing..."

        // Get all recordings with summaries from Core Data
        let recordingsWithData = appCoordinator.getAllRecordingsWithData()
        let summariesToRegenerate = recordingsWithData.compactMap { $0.summary }
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

            // Get complete recording data
            guard let recordingId = summary.recordingId,
                  let recordingData = appCoordinator.getCompleteRecordingData(id: recordingId),
                  let transcript = recordingData.transcript else {
                failed += 1
                errors.append("\(summary.recordingName): No transcript found")
                continue
            }

            do {
                // Generate new summary using the current AI engine
                let newEnhancedSummary = try await summaryManager.generateEnhancedSummary(
                    from: transcript.textForSummarization,
                    for: summary.recordingURL,
                    recordingName: summary.recordingName,
                    recordingDate: summary.recordingDate
                )

                // Note: Old summary cleanup now happens in RecordingWorkflowManager.createSummary

                // Debug: Show what names we're comparing (bulk regeneration)
                AppLog.shared.summarization("Bulk regeneration name check: nameChanged=\(newEnhancedSummary.recordingName != summary.recordingName)", level: .debug)

                // Update the recording name if it changed during regeneration
                if newEnhancedSummary.recordingName != summary.recordingName {
                    AppLog.shared.summarization("Bulk regeneration: Recording name was updated by AI")
                    // Update recording name in Core Data
                    try appCoordinator.coreDataManager.updateRecordingName(
                        for: recordingId,
                        newName: newEnhancedSummary.recordingName
                    )
                } else {
                    AppLog.shared.summarization("Bulk regeneration: Recording name did not change", level: .debug)
                }

                // Create new summary entry in Core Data with the updated name
                let newSummaryId = appCoordinator.workflowManager.createSummary(
                    for: recordingId,
                    transcriptId: summary.transcriptId ?? UUID(),
                    summary: newEnhancedSummary.summary,
                    tasks: newEnhancedSummary.tasks,
                    reminders: newEnhancedSummary.reminders,
                    titles: newEnhancedSummary.titles,
                    contentType: newEnhancedSummary.contentType,
                    aiEngine: newEnhancedSummary.aiEngine,
                    aiModel: newEnhancedSummary.aiModel,
                    originalLength: newEnhancedSummary.originalLength,
                    processingTime: newEnhancedSummary.processingTime
                )

                if newSummaryId != nil {
                    successful += 1
                    AppLog.shared.summarization("Regenerated summary for recording \(recordingId)")
                } else {
                    failed += 1
                    errors.append("Recording \(recordingId): Failed to save new summary")
                }

            } catch {
                failed += 1
                errors.append("Recording \(recordingId): \(error.localizedDescription)")
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
        // Find the recording by URL
        guard let recording = appCoordinator.getRecording(url: recordingURL),
              let recordingId = recording.id,
              let recordingData = appCoordinator.getCompleteRecordingData(id: recordingId),
              let summary = recordingData.summary,
              let transcript = recordingData.transcript else {
            AppLog.shared.summarization("No summary or transcript found for recording URL", level: .error)
            return false
        }

        do {
            AppLog.shared.summarization("Regenerating summary for recording \(recordingId)")

            // Generate new summary using the current AI engine
            let newEnhancedSummary = try await summaryManager.generateEnhancedSummary(
                from: transcript.textForSummarization,
                for: recordingURL,
                recordingName: summary.recordingName,
                recordingDate: summary.recordingDate
            )

            // Note: Old summary cleanup now happens in RecordingWorkflowManager.createSummary

            AppLog.shared.summarization("Regeneration name check: nameChanged=\(newEnhancedSummary.recordingName != summary.recordingName)", level: .debug)

            // Update the recording name if it changed during regeneration
            if newEnhancedSummary.recordingName != summary.recordingName {
                AppLog.shared.summarization("Recording name was updated by AI for recording \(recordingId)")
                // Update recording name in Core Data
                try appCoordinator.coreDataManager.updateRecordingName(
                    for: recordingId,
                    newName: newEnhancedSummary.recordingName
                )
            } else {
                AppLog.shared.summarization("Recording name did not change during regeneration", level: .debug)
            }

            // Create new summary entry in Core Data with the updated name
            let newSummaryId = appCoordinator.workflowManager.createSummary(
                for: recordingId,
                transcriptId: summary.transcriptId ?? UUID(),
                summary: newEnhancedSummary.summary,
                tasks: newEnhancedSummary.tasks,
                reminders: newEnhancedSummary.reminders,
                titles: newEnhancedSummary.titles,
                contentType: newEnhancedSummary.contentType,
                aiEngine: newEnhancedSummary.aiEngine,
                aiModel: newEnhancedSummary.aiModel,
                originalLength: newEnhancedSummary.originalLength,
                processingTime: newEnhancedSummary.processingTime
            )

            if newSummaryId != nil {
                AppLog.shared.summarization("Successfully regenerated summary for recording \(recordingId)")
                return true
            } else {
                AppLog.shared.summarization("Failed to save new summary for recording \(recordingId)", level: .error)
                return false
            }

        } catch {
            AppLog.shared.summarization("Failed to regenerate summary for recording \(recordingId): \(error.localizedDescription)", level: .error)
            return false
        }
    }

    func shouldPromptForRegeneration(oldEngine: String, newEngine: String) -> Bool {
        let recordingsWithData = appCoordinator.getAllRecordingsWithData()
        let summariesCount = recordingsWithData.compactMap { $0.summary }.count
        return oldEngine != newEngine && summariesCount > 0
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
        let recordingsWithData = appCoordinator.getAllRecordingsWithData()
        let summariesCount = recordingsWithData.compactMap { $0.summary }.count
        return !isRegenerating && summariesCount > 0
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
