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
    @AppStorage("selectedTranscriptionEngine") private var selectedTranscriptionEngine: String = TranscriptionEngine.whisperKit.rawValue
    @AppStorage(WhisperKitModelInfo.SettingsKeys.enableWhisperKit) private var enableWhisperKit = false

    @StateObject private var whisperKitManager = WhisperKitManager.shared

    @State private var showingAWSSettings = false
    @State private var showingWhisperSettings = false
    @State private var showingWhisperKitSettings = false
    @State private var showingOpenAISettings = false
    @State private var showingMistralTranscribeSettings = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                engineSection
                selectedEngineConfigurationSection
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
            .sheet(isPresented: $showingWhisperKitSettings) {
                NavigationStack {
                    WhisperKitSettingsView()
                }
            }
            .sheet(isPresented: $showingOpenAISettings) {
                OpenAISettingsView()
            }
            .sheet(isPresented: $showingMistralTranscribeSettings) {
                MistralTranscribeSettingsView()
            }
            .onChange(of: selectedTranscriptionEngine) { _, newValue in
                handleEngineSelection(newValue)
            }
        }
    }

    private func handleEngineSelection(_ engineRawValue: String) {
        guard let engine = TranscriptionEngine(rawValue: engineRawValue) else { return }

        if engine == .whisperKit {
            // Auto-enable WhisperKit when selected
            enableWhisperKit = true

            // If model not downloaded, prompt user to download
            if !whisperKitManager.isModelReady {
                showingWhisperKitSettings = true
            }
        }
    }
    
    private var engineSection: some View {
        Section(header: Text("Transcription Engine")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Select Transcription Engine")
                    .font(.body)
                    .fontWeight(.medium)
                
                Picker("Transcription Engine", selection: $selectedTranscriptionEngine) {
                    ForEach(TranscriptionEngine.availableCases.filter { $0.isAvailable }, id: \.self) { engine in
                        VStack(alignment: .leading) {
                            Text(engine.rawValue)
                                .font(.body)
                            Text(engine.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(engine.rawValue)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                
                if let selectedEngine = TranscriptionEngine(rawValue: selectedTranscriptionEngine) {
                    HStack {
                        Circle()
                            .fill(selectedEngine.isAvailable ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(selectedEngine.isAvailable ? "Available" : "Not Available")
                            .font(.caption)
                            .foregroundColor(selectedEngine.isAvailable ? .green : .red)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 8)
        }
    }
    
    private var selectedEngineConfigurationSection: some View {
        if let selectedEngine = TranscriptionEngine(rawValue: selectedTranscriptionEngine),
           selectedEngine.requiresConfiguration {
            
            return AnyView(
                Section(header: Text("\(selectedEngine.rawValue) Configuration")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(selectedEngine.rawValue) Settings")
                                    .font(.body)
                                Text(selectedEngine.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            
                            Button(action: {
                                switch selectedEngine {
                                case .notConfigured:
                                    // No settings for unconfigured state
                                    break
                                case .whisperKit:
                                    showingWhisperKitSettings = true
                                case .awsTranscribe:
                                    showingAWSSettings = true
                                case .whisper:
                                    showingWhisperSettings = true
                                case .openAI:
                                    showingOpenAISettings = true
                                case .mistralAI:
                                    showingMistralTranscribeSettings = true
                                case .openAIAPICompatible:
                                    // Coming soon - no settings yet
                                    break
                                }
                            }) {
                                HStack {
                                    Image(systemName: "gear")
                                    Text("Configure")
                                }
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(engineColor(for: selectedEngine))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                        }
                        
                        engineStatusView(for: selectedEngine)
                    }
                    .padding(.vertical, 8)
                }
            )
        } else {
            return AnyView(EmptyView())
        }
    }
    
    private func engineColor(for engine: TranscriptionEngine) -> Color {
        switch engine {
        case .notConfigured:
            return .gray
        case .whisperKit:
            return .indigo
        case .awsTranscribe:
            return .orange
        case .whisper:
            return .green
        case .openAI:
            return .blue
        case .mistralAI:
            return .purple
        case .openAIAPICompatible:
            return .gray
        }
    }
    
    private func engineStatusView(for engine: TranscriptionEngine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Status:")
                    .font(.body)
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(engine.isAvailable ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(engine.isAvailable ? "Configured" : "Needs Configuration")
                        .font(.caption)
                        .foregroundColor(engine.isAvailable ? .green : .red)
                }
            }
            
            HStack {
                Text("Type:")
                    .font(.body)
                    .foregroundColor(.secondary)
                Spacer()
                Text(engineTypeDescription(for: engine))
                    .font(.body)
                    .fontWeight(.medium)
            }
            
            if engine == .whisperKit {
                HStack {
                    Text("Privacy:")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("On-Device")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(engineColor(for: engine).opacity(0.1))
        )
    }
    
    private func engineTypeDescription(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .notConfigured:
            return "Not Configured"
        case .whisperKit:
            return "On-Device AI"
        case .awsTranscribe:
            return "Cloud-based"
        case .whisper:
            return "Local AI"
        case .openAI:
            return "Cloud AI"
        case .mistralAI:
            return "Cloud AI"
        case .openAIAPICompatible:
            return "Coming Soon"
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
        selectedTranscriptionEngine = TranscriptionEngine.whisperKit.rawValue
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
