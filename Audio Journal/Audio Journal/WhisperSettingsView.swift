//
//  WhisperSettingsView.swift
//  Audio Journal
//
//  Settings view for Whisper service configuration
//

import SwiftUI

struct WhisperSettingsView: View {
    @AppStorage("whisperServerURL") private var serverURL: String = "http://localhost"
    @AppStorage("whisperPort") private var port: Int = 9000
    @AppStorage("enableWhisper") private var enableWhisper: Bool = false
    
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var whisperService: WhisperService
    
    init() {
        // Initialize with current settings
        let serverURL = UserDefaults.standard.string(forKey: "whisperServerURL") ?? "http://localhost"
        let port = UserDefaults.standard.integer(forKey: "whisperPort")
        
        // Use default port if not set (UserDefaults.integer returns 0 if key doesn't exist)
        let effectivePort = port > 0 ? port : 9000
        
        let config = WhisperConfig(
            serverURL: serverURL,
            port: effectivePort
        )
        
        _whisperService = State(initialValue: WhisperService(config: config))
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Whisper Service")) {
                    Toggle("Enable Whisper Transcription", isOn: $enableWhisper)
                    
                    if enableWhisper {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Whisper provides high-quality transcription using OpenAI's Whisper model via REST API. This service runs on your local server for privacy and performance.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                if enableWhisper {
                    Section(header: Text("Server Configuration")) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Local Whisper Server")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Connect to your REST API-based Whisper service")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Server URL")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                TextField("http://localhost", text: $serverURL)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .keyboardType(.URL)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                
                                Text("The URL of your Whisper server (e.g., http://localhost, http://192.168.1.100)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Port")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                HStack {
                                    TextField("10300", value: $port, format: .number.grouping(.never))
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .keyboardType(.numberPad)
                                    
                                    Button("Default") {
                                        port = 9000
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundColor(.blue)
                                    .cornerRadius(6)
                                }
                                
                                Text("The port number your Whisper server is listening on (default: 9000)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Section(header: Text("Connection Test")) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "network")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Test Connection")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Verify that your Whisper server is accessible")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Button(action: testConnection) {
                                HStack {
                                    if isTesting {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    Text(isTesting ? "Testing..." : "Test Connection")
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(isConfigurationValid ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                                .foregroundColor(isConfigurationValid ? .blue : .gray)
                                .cornerRadius(8)
                            }
                            .disabled(!isConfigurationValid || isTesting)
                            
                            if let testResult = testResult {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Test Result")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    
                                    Text(testResult)
                                        .font(.caption)
                                        .foregroundColor(testResult.hasPrefix("✅") ? .green : .red)
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(testResult.hasPrefix("✅") ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                                        )
                                }
                            }
                        }
                    }
                    
                    Section(header: Text("Setup Instructions")) {
                        VStack(alignment: .leading, spacing: 12) {
                            WhisperInstructionRow(
                                number: "1",
                                title: "Install Whisper Service",
                                description: "Install the REST API-based Whisper service on your server"
                            )
                            
                            WhisperInstructionRow(
                                number: "2",
                                title: "Start the Service",
                                description: "Run the Whisper service on port 9000 (or your preferred port)"
                            )
                            
                            WhisperInstructionRow(
                                number: "3",
                                title: "Test Connection",
                                description: "Use the test button above to verify your server is accessible"
                            )
                            
                            WhisperInstructionRow(
                                number: "4",
                                title: "Start Transcribing",
                                description: "Your Whisper service is ready for transcription"
                            )
                        }
                    }
                    
                    Section {
                        Link("Whisper REST API Documentation", destination: URL(string: "https://github.com/guillaumekln/faster-whisper")!)
                        Link("Whisper Model Information", destination: URL(string: "https://openai.com/research/whisper")!)
                    }
                }
            }
            .navigationTitle("Whisper Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onChange(of: serverURL) { _, _ in
                updateWhisperService()
            }
            .onChange(of: port) { _, _ in
                updateWhisperService()
            }
        }
    }
    
    private var isConfigurationValid: Bool {
        !serverURL.isEmpty && port > 0 && port <= 65535
    }
    
    private func updateWhisperService() {
        let config = WhisperConfig(
            serverURL: serverURL,
            port: port
        )
        whisperService = WhisperService(config: config)
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        Task {
            let success = await whisperService.testConnection()
            
            await MainActor.run {
                if success {
                    testResult = "✅ Connection successful! Your Whisper server is accessible."
                } else {
                    testResult = "❌ Connection failed: \(whisperService.connectionError ?? "Unknown error")"
                }
                isTesting = false
            }
        }
    }
}

struct WhisperInstructionRow: View {
    let number: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.blue))
            
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

struct WhisperSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        WhisperSettingsView()
    }
} 