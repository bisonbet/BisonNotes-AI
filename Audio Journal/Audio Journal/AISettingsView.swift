//
//  AISettingsView.swift
//  Audio Journal
//
//  AI Summarization Engine configuration view
//

import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @StateObject private var summaryManager = SummaryManager()
    @StateObject private var regenerationManager: SummaryRegenerationManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingEngineChangePrompt = false
    @State private var previousEngine = ""
    
    init() {
        let summaryManager = SummaryManager()
        let transcriptManager = TranscriptManager.shared
        _regenerationManager = StateObject(wrappedValue: SummaryRegenerationManager(summaryManager: summaryManager, transcriptManager: transcriptManager))
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    
                    // Header Section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "brain.head.profile")
                                .foregroundColor(.blue)
                                .font(.title2)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("AI Summarization Engine")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                Text("Choose the AI engine for generating summaries, extracting tasks, and identifying reminders from your recordings")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                    }
                    
                    // Current Engine Status
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Current Configuration")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 24)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "cpu")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                                
                                Text("Engine:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Text(recorderVM.selectedAIEngine)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                
                                if AIEngineType.allCases.first(where: { $0.rawValue == recorderVM.selectedAIEngine })?.isComingSoon == true {
                                    Text("(Coming Soon)")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.2))
                                        .cornerRadius(3)
                                }
                            }
                            .padding(.horizontal, 24)
                            
                            if summaryManager.enhancedSummaries.count > 0 {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .foregroundColor(.blue)
                                        .font(.caption)
                                    
                                    Text("Existing Summaries:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    Text("\(summaryManager.enhancedSummaries.count)")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                }
                                .padding(.horizontal, 24)
                            }
                        }
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.blue.opacity(0.1))
                        )
                        .padding(.horizontal, 24)
                    }
                    
                    // Engine Selection
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Available Engines")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 24)
                        
                        ForEach(AIEngineType.allCases, id: \.self) { engineType in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(engineType.rawValue)
                                                .font(.body)
                                                .foregroundColor(.primary)
                                            if engineType.isComingSoon {
                                                Text("(Coming Soon)")
                                                    .font(.caption)
                                                    .foregroundColor(.orange)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.orange.opacity(0.2))
                                                    .cornerRadius(4)
                                            }
                                        }
                                        Text(engineType.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if recorderVM.selectedAIEngine == engineType.rawValue {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                            .font(.title2)
                                    }
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.systemGray6))
                                    .opacity(recorderVM.selectedAIEngine == engineType.rawValue ? 0.3 : 0.1)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(recorderVM.selectedAIEngine == engineType.rawValue ? Color.blue : Color.clear, lineWidth: 2)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !engineType.isComingSoon {
                                    let oldEngine = recorderVM.selectedAIEngine
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        recorderVM.selectedAIEngine = engineType.rawValue
                                        summaryManager.setEngine(engineType.rawValue)
                                        regenerationManager.setEngine(engineType.rawValue)
                                    }
                                    
                                    // Check if we should prompt for regeneration
                                    if regenerationManager.shouldPromptForRegeneration(oldEngine: oldEngine, newEngine: engineType.rawValue) {
                                        previousEngine = oldEngine
                                        showingEngineChangePrompt = true
                                    }
                                }
                            }
                            .opacity(!engineType.isComingSoon ? 1.0 : 0.6)
                            .padding(.horizontal, 24)
                        }
                    }
                    
                    // Regeneration section
                    if summaryManager.enhancedSummaries.count > 0 {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Summary Management")
                                .font(.headline)
                                .foregroundColor(.primary)
                                .padding(.horizontal, 24)
                            
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Regenerate All Summaries")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text("Update all existing summaries with the current AI engine")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Button(action: {
                                        Task {
                                            await regenerationManager.regenerateAllSummaries()
                                        }
                                    }) {
                                        HStack {
                                            if regenerationManager.isRegenerating {
                                                ProgressView()
                                                    .scaleEffect(0.8)
                                            } else {
                                                Image(systemName: "arrow.clockwise")
                                            }
                                            Text(regenerationManager.isRegenerating ? "Processing..." : "Regenerate All")
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(regenerationManager.canRegenerate ? Color.blue : Color.gray)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                    }
                                    .disabled(!regenerationManager.canRegenerate)
                                }
                                
                                // Progress view
                                RegenerationProgressView(regenerationManager: regenerationManager)
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.blue.opacity(0.1))
                            )
                            .padding(.horizontal, 24)
                        }
                    }
                    
                    Spacer(minLength: 40)
                }
            }
            .navigationTitle("AI Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .alert("Engine Change", isPresented: $showingEngineChangePrompt) {
            Button("Skip") {
                // Do nothing, just dismiss
            }
            Button("Regenerate") {
                Task {
                    await regenerationManager.regenerateAllSummaries()
                }
            }
        } message: {
            Text("You've switched from \(previousEngine) to \(recorderVM.selectedAIEngine). Would you like to regenerate your \(summaryManager.enhancedSummaries.count) existing summaries with the new AI engine?")
        }
        .alert("Regeneration Complete", isPresented: $regenerationManager.showingRegenerationAlert) {
            Button("OK") {
                regenerationManager.regenerationResults = nil
            }
        } message: {
            if let results = regenerationManager.regenerationResults {
                Text(results.summary)
            }
        }
        .onAppear {
            summaryManager.setEngine(recorderVM.selectedAIEngine)
            regenerationManager.setEngine(recorderVM.selectedAIEngine)
        }
    }
}

#Preview {
    AISettingsView()
        .environmentObject(AudioRecorderViewModel())
}