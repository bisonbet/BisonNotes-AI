//
//  GoogleAIStudioSettingsView.swift
//  Audio Journal
//
//  Settings view for Google AI Studio configuration
//

import SwiftUI
import os.log

struct GoogleAIStudioSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("googleAIStudioAPIKey") private var apiKey: String = ""
    @AppStorage("googleAIStudioModel") private var selectedModel: String = "gemini-2.5-flash"
    @AppStorage("googleAIStudioTemperature") private var temperature: Double = 0.1
    @AppStorage("googleAIStudioMaxTokens") private var maxTokens: Int = 4096
    @AppStorage("enableGoogleAIStudio") private var isEnabled: Bool = false
    
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var isTestingConnection = false
    
    private let logger = Logger(subsystem: "com.audiojournal.app", category: "GoogleAIStudioSettings")
    
    let onConfigurationChanged: () -> Void
    
    private let availableModels = [
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-1.5-flash",
        "gemini-1.5-pro"
    ]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("API Configuration")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.headline)
                        
                        SecureField("Enter your Google AI Studio API key", text: $apiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        Text("Get your API key from [Google AI Studio](https://aistudio.google.com/)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("Model Settings")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Model")
                            .font(.headline)
                        
                        Picker("Select Model", selection: $selectedModel) {
                            ForEach(availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        
                        Text("Temperature: \(temperature, specifier: "%.1f")")
                            .font(.headline)
                        
                        Slider(value: $temperature, in: 0.0...1.0, step: 0.1)
                            .accentColor(.blue)
                        
                        Text("Controls randomness (0.0 = deterministic, 1.0 = very random)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("Max Tokens: \(maxTokens)")
                            .font(.headline)
                        
                        Stepper("", value: $maxTokens, in: 1000...8192, step: 512)
                            .labelsHidden()
                        
                        Text("Maximum number of tokens in the response")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("Status")) {
                    HStack {
                        Text("Enabled")
                        Spacer()
                        Toggle("", isOn: $isEnabled)
                            .labelsHidden()
                    }
                    
                    if !apiKey.isEmpty {
                        HStack {
                            Text("API Key")
                            Spacer()
                            Text("✓ Set")
                                .foregroundColor(.green)
                        }
                    } else {
                        HStack {
                            Text("API Key")
                            Spacer()
                            Text("Not set")
                                .foregroundColor(.red)
                        }
                    }
                    
                    HStack {
                        Text("Model")
                        Spacer()
                        Text(selectedModel)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section {
                    Button(action: testConnection) {
                        HStack {
                            if isTestingConnection {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "network")
                            }
                            Text("Test Connection")
                        }
                    }
                    .disabled(apiKey.isEmpty || isTestingConnection)
                }
            }
            .navigationTitle("Google AI Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveSettings()
                    }
                    .disabled(apiKey.isEmpty)
                }
            }
            .alert("Connection Test", isPresented: $showingAlert) {
                Button("OK") { }
            } message: {
                Text(alertMessage)
            }
        }
    }
    
    private func testConnection() {
        isTestingConnection = true
        
        Task {
            let service = GoogleAIStudioService()
            let isConnected = await service.testConnection()
            
            await MainActor.run {
                isTestingConnection = false
                alertMessage = isConnected ? "Connection successful!" : "Connection failed. Please check your API key and internet connection."
                showingAlert = true
            }
        }
    }
    
    private func saveSettings() {
        logger.info("Saving Google AI Studio settings")
        logger.info("API Key: \(apiKey.isEmpty ? "Not set" : "Set")")
        logger.info("Model: \(selectedModel)")
        logger.info("Temperature: \(temperature)")
        logger.info("Max Tokens: \(maxTokens)")
        logger.info("Enabled: \(isEnabled)")
        
        onConfigurationChanged()
        dismiss()
    }
}

#Preview {
    GoogleAIStudioSettingsView {
        // Preview callback
    }
} 