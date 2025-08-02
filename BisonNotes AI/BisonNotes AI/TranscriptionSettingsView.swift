//
//  TranscriptionSettingsView.swift
//  Audio Journal
//
//  Settings view for transcription configuration
//

import SwiftUI

struct TranscriptionSettingsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @AppStorage("showTranscriptionProgress") private var showTranscriptionProgress: Bool = true
    @AppStorage("selectedTranscriptionEngine") private var selectedTranscriptionEngine: String = TranscriptionEngine.appleIntelligence.rawValue
    
    @State private var showingAWSSettings = false
    @State private var showingWhisperSettings = false
    @State private var showingOpenAISettings = false
    @State private var showingAppleIntelligenceSettings = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                engineSection
                displayOptionsSection
                tipsSection
                resetSection
            }
            .navigationTitle("Transcription Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingAWSSettings) {
                AWSSettingsView()
            }
            .sheet(isPresented: $showingWhisperSettings) {
                WhisperSettingsView()
            }
            .sheet(isPresented: $showingOpenAISettings) {
                OpenAISettingsView()
            }
            .sheet(isPresented: $showingAppleIntelligenceSettings) {
                AppleIntelligenceSettingsView()
            }
        }
    }
    
    private var engineSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(engine.rawValue)
                                    .font(.body)
                                    .fontWeight(.medium)
                                
                                if !engine.isAvailable {
                                    Text("(Coming Soon)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Text(engine.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        
                        Spacer()
                        
                        if engine.isAvailable {
                            Button(action: {
                                selectedTranscriptionEngine = engine.rawValue
                            }) {
                                Image(systemName: selectedTranscriptionEngine == engine.rawValue ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedTranscriptionEngine == engine.rawValue ? .accentColor : .secondary)
                                    .font(.title2)
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            Image(systemName: "circle")
                                .foregroundColor(.secondary)
                                .font(.title2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 8)
            
            // Settings buttons for engines that require configuration
            if let selectedEngine = TranscriptionEngine(rawValue: selectedTranscriptionEngine),
               selectedEngine.requiresConfiguration {
                Divider()
                
                VStack(spacing: 8) {
                    Text("Engine Settings")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if selectedEngine == .awsTranscribe {
                        Button("AWS Settings") {
                            showingAWSSettings = true
                        }
                        .foregroundColor(.accentColor)
                    }
                    
                    if selectedEngine == .whisper {
                        Button("Whisper Settings") {
                            showingWhisperSettings = true
                        }
                        .foregroundColor(.accentColor)
                    }
                    
                    if selectedEngine == .openAI {
                        Button("OpenAI Settings") {
                            showingOpenAISettings = true
                        }
                        .foregroundColor(.accentColor)
                    }
                    
                    if selectedEngine == .appleIntelligence {
                        Button("Apple Intelligence Settings") {
                            showingAppleIntelligenceSettings = true
                        }
                        .foregroundColor(.accentColor)
                    }
                }
            }
        } header: {
            Text("Transcription Engine")
        }
    }
    

    
    private var displayOptionsSection: some View {
        Section {
            Toggle("Show Transcription Progress", isOn: $showTranscriptionProgress)
            
            Text("Display real-time transcription progress.")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("Display Options")
        }
    }
    
    private var tipsSection: some View {
        Section {
            TipRow(
                icon: "brain",
                title: "Engine selection",
                description: "Choose the engine that best fits your needs and available services."
            )
            
            TipRow(
                icon: "wifi",
                title: "Network considerations",
                description: "Cloud-based engines require internet connectivity."
            )
            
            TipRow(
                icon: "battery.100",
                title: "Battery optimization",
                description: "Local engines use more battery but work offline."
            )
        } header: {
            Text("Tips")
        }
    }
    
    private var resetSection: some View {
        Section {
            Button("Reset to Defaults") {
                resetToDefaults()
            }
            .foregroundColor(.red)
        }
    }
    

    
    private func resetToDefaults() {
        showTranscriptionProgress = true
        selectedTranscriptionEngine = TranscriptionEngine.appleIntelligence.rawValue
    }
}

struct TipRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct TranscriptionSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TranscriptionSettingsView()
            .environmentObject(AudioRecorderViewModel())
    }
}

