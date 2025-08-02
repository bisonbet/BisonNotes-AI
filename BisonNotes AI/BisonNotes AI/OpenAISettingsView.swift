//
//  OpenAISettingsView.swift
//  Audio Journal
//
//  Settings view for OpenAI transcription configuration
//

import SwiftUI

struct OpenAISettingsView: View {
    @AppStorage("openAIAPIKey") private var apiKey: String = ""
    @AppStorage("openAIModel") private var selectedModel: String = OpenAITranscribeModel.whisper1.rawValue
    @AppStorage("openAIBaseURL") private var baseURL: String = "https://api.openai.com/v1"
    
    @State private var isTestingConnection = false
    @State private var connectionTestResult: String = ""
    @State private var showingConnectionResult = false
    @State private var isConnectionSuccessful = false
    @State private var showingAPIKeyInfo = false
    
    @Environment(\.dismiss) private var dismiss
    
    private var selectedModelEnum: OpenAITranscribeModel {
        OpenAITranscribeModel(rawValue: selectedModel) ?? .whisper1
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("API Key")
                            Spacer()
                            Button(action: { showingAPIKeyInfo = true }) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.blue)
                            }
                        }
                        
                        SecureField("Enter your OpenAI API key", text: $apiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        if !apiKey.isEmpty {
                            Text("API key configured (\(apiKey.count) characters)")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Text("API key required for OpenAI transcription")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Your API key is stored securely on your device and only used for transcription requests.")
                }
                
                Section {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(OpenAITranscribeModel.allCases, id: \.rawValue) { model in
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                Text(model.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .tag(model.rawValue)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Selected: \(selectedModelEnum.displayName)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text(selectedModelEnum.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if selectedModelEnum.supportsStreaming {
                            Label("Supports streaming", systemImage: "waveform")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Model Selection")
                } footer: {
                    Text("GPT-4o Mini is the cheapest and fastest option. GPT-4o Transcribe is the most robust. Whisper-1 is the legacy model.")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Base URL")
                        
                        TextField("API Base URL", text: $baseURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        
                        Text("Use default OpenAI URL or a compatible API endpoint")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("API Configuration")
                } footer: {
                    Text("Advanced users can use OpenAI-compatible APIs by changing the base URL.")
                }
                
                Section {
                    Button(action: testConnection) {
                        HStack {
                            if isTestingConnection {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Testing Connection...")
                            } else {
                                Image(systemName: "network")
                                Text("Test Connection")
                            }
                        }
                    }
                    .disabled(apiKey.isEmpty || isTestingConnection)
                    
                    if showingConnectionResult {
                        HStack {
                            Image(systemName: isConnectionSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(isConnectionSuccessful ? .green : .red)
                            
                            Text(connectionTestResult)
                                .font(.caption)
                                .foregroundColor(isConnectionSuccessful ? .green : .red)
                        }
                    }
                } header: {
                    Text("Connection Test")
                } footer: {
                    Text("Test your API key and connection to ensure transcription will work properly.")
                }
                
                Section {
                    FeatureRow(
                        icon: "doc.text",
                        title: "Supported Formats",
                        description: "MP3, MP4, M4A, WAV, FLAC, OGG, WebM"
                    )
                    
                    FeatureRow(
                        icon: "scalemass",
                        title: "File Size Limit",
                        description: "Maximum 25MB per file"
                    )
                    
                    FeatureRow(
                        icon: "globe",
                        title: "Language Support",
                        description: "Automatic language detection with 99+ languages"
                    )
                    
                    FeatureRow(
                        icon: "dollarsign.circle",
                        title: "Pricing",
                        description: "Pay per minute of audio transcribed"
                    )
                } header: {
                    Text("Features & Limits")
                }
                
                Section {
                    Button("Reset to Defaults") {
                        resetToDefaults()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("OpenAI Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("API Key Information", isPresented: $showingAPIKeyInfo) {
                Button("OK") { }
            } message: {
                Text("You can get your OpenAI API key from platform.openai.com. Go to API Keys section and create a new secret key. Make sure your account has sufficient credits for transcription usage.")
            }
        }
    }
    
    private func testConnection() {
        guard !apiKey.isEmpty else { return }
        
        isTestingConnection = true
        showingConnectionResult = false
        
        Task {
            do {
                let config = OpenAITranscribeConfig(
                    apiKey: apiKey,
                    model: selectedModelEnum,
                    baseURL: baseURL
                )
                
                let service = OpenAITranscribeService(config: config, chunkingService: AudioFileChunkingService())
                try await service.testConnection()
                
                await MainActor.run {
                    connectionTestResult = "Connection successful! API key is valid."
                    isConnectionSuccessful = true
                    showingConnectionResult = true
                    isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    connectionTestResult = "Connection failed: \(error.localizedDescription)"
                    isConnectionSuccessful = false
                    showingConnectionResult = true
                    isTestingConnection = false
                }
            }
        }
    }
    
    private func resetToDefaults() {
        apiKey = ""
        selectedModel = OpenAITranscribeModel.whisper1.rawValue
        baseURL = "https://api.openai.com/v1"
        showingConnectionResult = false
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.blue)
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

struct OpenAISettingsView_Previews: PreviewProvider {
    static var previews: some View {
        OpenAISettingsView()
    }
}