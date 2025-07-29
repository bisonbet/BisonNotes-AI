//
//  SettingsView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/28/25.
//

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @StateObject private var summaryManager = SummaryManager()
    @StateObject private var transcriptManager = TranscriptManager.shared
    @StateObject private var regenerationManager: SummaryRegenerationManager
    @StateObject private var errorHandler = ErrorHandler()
    @State private var showingEngineChangePrompt = false
    @State private var previousEngine = ""
    @State private var showingTranscriptionSettings = false
    @State private var showingAISettings = false
    @State private var showingPerformanceView = false
    @State private var showingClearSummariesAlert = false
    
    init() {
        let summaryMgr = SummaryManager()
        let transcriptMgr = TranscriptManager.shared
        self._summaryManager = StateObject(wrappedValue: summaryMgr)
        self._transcriptManager = StateObject(wrappedValue: transcriptMgr)
        self._regenerationManager = StateObject(wrappedValue: SummaryRegenerationManager(summaryManager: summaryMgr, transcriptManager: transcriptMgr))
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Settings")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .padding(.top, 20)
                        .padding(.horizontal, 24)
                    
                    // Microphone Selection
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Microphone Selection")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            Button(action: {
                                recorderVM.fetchInputs()
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 24)
                        
                        if recorderVM.availableInputs.isEmpty {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("No microphones found.")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 24)
                        } else {
                            Picker("Select Microphone", selection: Binding(
                                get: { recorderVM.selectedInputUID ?? "" },
                                set: { newValue in
                                    recorderVM.selectedInputUID = newValue.isEmpty ? nil : newValue
                                    recorderVM.setPreferredInput()
                                }
                            )) {
                                ForEach(recorderVM.availableInputs, id: \.uid) { input in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(input.portName)
                                            .font(.body)
                                        Text(microphoneTypeDescription(for: input.portType))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .tag(input.uid)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.systemGray6))
                            )
                            .padding(.horizontal, 24)
                        }
                    }
                    
                    // Audio Quality
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Audio Quality")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 24)
                        
                        ForEach(AudioQuality.allCases, id: \.self) { quality in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(quality.rawValue)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text(quality.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if recorderVM.selectedQuality == quality {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                            .font(.title2)
                                    }
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                Rectangle()
                                    .fill(Color(.systemGray6))
                                    .opacity(recorderVM.selectedQuality == quality ? 0.3 : 0.1)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    recorderVM.selectedQuality = quality
                                }
                            }
                        }
                    }
                    
                    // Location Services
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Location Services")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 24)
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Enable Location Tracking")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text("Capture location data with recordings")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $recorderVM.isLocationTrackingEnabled)
                                .labelsHidden()
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Rectangle()
                                .fill(Color(.systemGray6))
                                .opacity(0.3)
                        )
                    }
                    
                    // AI Settings
                    VStack(alignment: .leading, spacing: 16) {
                        Text("AI Engine")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 24)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Current Engine:")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                Text(recorderVM.selectedAIEngine)
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                            }
                            
                            // Engine status indicator
                            HStack {
                                Text("Status:")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                
                                let engineStatus = summaryManager.getEngineAvailabilityStatus()[recorderVM.selectedAIEngine]
                                let statusColor: Color = engineStatus?.isAvailable == true ? .green : .red
                                let statusText = engineStatus?.isAvailable == true ? "Available" : "Unavailable"
                                
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(statusColor)
                                        .frame(width: 8, height: 8)
                                    Text(statusText)
                                        .font(.body)
                                        .fontWeight(.medium)
                                        .foregroundColor(statusColor)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        
                        HStack {
                            Button(action: {
                                showingAISettings = true
                            }) {
                                HStack {
                                    Text("Configure AI Engine")
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.blue.opacity(0.1))
                                )
                                .foregroundColor(.blue)
                            }
                            
                            Button(action: {
                                Task {
                                    await summaryManager.refreshEngineAvailability()
                                }
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            .padding(.horizontal, 8)
                        }
                        .padding(.horizontal, 24)
                    }
                    
                    // AI Processing Settings
                    VStack(alignment: .leading, spacing: 16) {
                        Text("AI Processing")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 24)
                        
                        HStack {
                            Text("Current AI Engine:")
                                .font(.body)
                                .foregroundColor(.secondary)
                            Text(recorderVM.selectedAIEngine)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 24)
                        
                        Button(action: {
                            showingAISettings = true
                        }) {
                            HStack {
                                Text("Configure AI Engines")
                                Spacer()
                                Image(systemName: "arrow.right")
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.blue.opacity(0.1))
                            )
                            .foregroundColor(.blue)
                        }
                        .padding(.horizontal, 24)
                        
                        Button(action: {
                            showingPerformanceView = true
                        }) {
                            HStack {
                                Text("Engine Performance")
                                Spacer()
                                Image(systemName: "chart.line.uptrend.xyaxis")
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.green.opacity(0.1))
                            )
                            .foregroundColor(.green)
                        }
                        .padding(.horizontal, 24)
                        

                    }
                    
                    // Transcription Settings
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Transcription Engine")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.horizontal, 24)
                        
                        HStack {
                            Text("Current Engine:")
                                .font(.body)
                                .foregroundColor(.secondary)
                            Text(recorderVM.selectedTranscriptionEngine.rawValue)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 24)
                        
                        Button(action: {
                            showingTranscriptionSettings = true
                        }) {
                            HStack {
                                Text("Configure Transcription")
                                Spacer()
                                Image(systemName: "arrow.right")
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.purple.opacity(0.1))
                            )
                            .foregroundColor(.purple)
                        }
                        .padding(.horizontal, 24)
                    }
                    
                    Spacer(minLength: 20)
                }
                .background(Color(.systemBackground))
            }
            .navigationTitle("Settings")
            .onAppear {
                summaryManager.setEngine(recorderVM.selectedAIEngine)
                regenerationManager.setEngine(recorderVM.selectedAIEngine)
            }
        }
        .sheet(isPresented: $showingTranscriptionSettings) {
            TranscriptionSettingsView()
                .environmentObject(recorderVM)
        }
        .sheet(isPresented: $showingAISettings) {
            AISettingsView()
                .environmentObject(recorderVM)
        }
        .sheet(isPresented: $showingPerformanceView) {
            EnginePerformanceView(summaryManager: summaryManager)
        }

        .alert("Clear All Summaries", isPresented: $showingClearSummariesAlert) {
            Button("Cancel", role: .cancel) {
                // Do nothing, just dismiss
            }
            Button("Clear All", role: .destructive) {
                clearAllSummaries()
            }
        } message: {
            let totalSummaries = summaryManager.enhancedSummaries.count + summaryManager.summaries.count
            Text("This will permanently delete all \(totalSummaries) summaries, transcripts, and extracted tasks/reminders. This action cannot be undone.")
        }
        .alert("Error", isPresented: $errorHandler.showingErrorAlert) {
            Button("OK") {
                errorHandler.clearCurrentError()
            }
        } message: {
            if let error = errorHandler.currentError {
                Text(error.localizedDescription)
            }
        }
    }
    
    private func microphoneTypeDescription(for portType: AVAudioSession.Port) -> String {
        switch portType {
        case .builtInMic:
            return "Built-in Microphone"
        case .headsetMic:
            return "Headset Microphone"
        case .bluetoothHFP:
            return "Bluetooth Hands-Free"
        case .bluetoothA2DP:
            return "Bluetooth Audio"
        case .bluetoothLE:
            return "Bluetooth Low Energy"
        case .usbAudio:
            return "USB Audio Device"
        case .carAudio:
            return "Car Audio System"
        case .airPlay:
            return "AirPlay Device"
        case .lineIn:
            return "Line Input"
        default:
            return portType.rawValue.capitalized
        }
    }
    
    private func clearAllSummaries() {
        summaryManager.clearAllSummaries()
        transcriptManager.clearAllTranscripts()
    }
}