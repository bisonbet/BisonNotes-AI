//
//  WhisperSettingsView.swift
//  Audio Journal
//
//  Settings view for Whisper service configuration
//

import SwiftUI

struct WhisperSettingsView: View {
    @AppStorage("whisperServerURL") private var serverURL: String = "localhost"
    @AppStorage("whisperPort") private var port: Int = 9000
    @AppStorage("whisperProtocol") private var protocolString: String = WhisperProtocol.rest.rawValue
    @AppStorage("enableWhisper") private var enableWhisper: Bool = false
    
    private var selectedProtocol: WhisperProtocol {
        get { WhisperProtocol(rawValue: protocolString) ?? .rest }
        set { protocolString = newValue.rawValue }
    }
    
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var whisperService: WhisperService
    
    init() {
        // Initialize with current settings
        let serverURL = UserDefaults.standard.string(forKey: "whisperServerURL") ?? "localhost"
        let port = UserDefaults.standard.integer(forKey: "whisperPort")
        let protocolString = UserDefaults.standard.string(forKey: "whisperProtocol") ?? WhisperProtocol.rest.rawValue
        let selectedProtocol = WhisperProtocol(rawValue: protocolString) ?? .rest
        
        // Use default port if not set (UserDefaults.integer returns 0 if key doesn't exist)
        let effectivePort = port > 0 ? port : (selectedProtocol == .wyoming ? 10300 : 9000)
        
        // Ensure URL format matches protocol
        var processedServerURL = serverURL
        if selectedProtocol == .rest && !serverURL.hasPrefix("http://") && !serverURL.hasPrefix("https://") {
            processedServerURL = "http://" + serverURL
        }
        
        let config = WhisperConfig(
            serverURL: processedServerURL,
            port: effectivePort,
            whisperProtocol: selectedProtocol
        )
        
        _whisperService = State(initialValue: WhisperService(config: config, chunkingService: AudioFileChunkingService()))
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Whisper Service")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Whisper provides high-quality transcription using OpenAI's Whisper model via REST API. This service runs on your local server for privacy and performance.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("Protocol Selection")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "arrow.left.arrow.right")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Communication Protocol")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("Choose how to connect to your Whisper server")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Picker("Protocol", selection: Binding(
                            get: { selectedProtocol },
                            set: { newValue in 
                                let oldProtocol = selectedProtocol
                                protocolString = newValue.rawValue
                                
                                // Update default port when protocol changes
                                if port == 9000 || port == 10300 {
                                    port = newValue == .wyoming ? 10300 : 9000
                                }
                                
                                // Update URL format based on protocol
                                if oldProtocol != newValue {
                                    if newValue == .wyoming {
                                        // When switching to Wyoming, remove protocol schemes and use plain hostname
                                        if serverURL.hasPrefix("http://") {
                                            serverURL = String(serverURL.dropFirst(7)) // Remove "http://"
                                        } else if serverURL.hasPrefix("https://") {
                                            serverURL = String(serverURL.dropFirst(8)) // Remove "https://"
                                        } else if serverURL.hasPrefix("ws://") {
                                            serverURL = String(serverURL.dropFirst(5)) // Remove "ws://"
                                        } else if serverURL.hasPrefix("wss://") {
                                            serverURL = String(serverURL.dropFirst(6)) // Remove "wss://"
                                        }
                                        
                                        // If it was localhost, keep it as localhost
                                        if serverURL == "localhost" {
                                            serverURL = "localhost"
                                        }
                                    } else {
                                        // When switching to REST, ensure http:// prefix
                                        if !serverURL.hasPrefix("http://") && !serverURL.hasPrefix("https://") {
                                            // If it was localhost or plain hostname, add http://
                                            serverURL = "http://" + serverURL
                                        }
                                    }
                                }
                            }
                        )) {
                            ForEach(WhisperProtocol.allCases, id: \.self) { whisperProtocol in
                                Text(whisperProtocol.shortName)
                                    .tag(whisperProtocol)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        
                        // Show description for selected protocol
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Protocol Details")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            
                            Text(selectedProtocol.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.blue.opacity(0.1))
                                )
                        }
                    }
                }
                
                Section(header: Text("Server Configuration")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Local Whisper Server")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(selectedProtocol == .wyoming ? 
                                     "Connect to your Wyoming protocol Whisper service" :
                                     "Connect to your REST API-based Whisper service")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Server URL")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            TextField(selectedProtocol == .wyoming ? "localhost" : "http://localhost", text: $serverURL)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            
                            Text(selectedProtocol == .wyoming ? 
                                 "The hostname or IP address of your Wyoming server (e.g., localhost, 192.168.1.100)" :
                                 "The URL of your Whisper server (e.g., http://localhost, http://192.168.1.100)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Port")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            HStack {
                                TextField(selectedProtocol == .wyoming ? "10300" : "9000", value: $port, format: .number.grouping(.never))
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .keyboardType(.numberPad)
                                
                                Button("Default") {
                                    port = selectedProtocol == .wyoming ? 10300 : 9000
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(6)
                            }
                            
                            Text(selectedProtocol == .wyoming ? 
                                 "The port number your Wyoming server is listening on (default: 10300)" :
                                 "The port number your Whisper server is listening on (default: 9000)")
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
                        if selectedProtocol == .wyoming {
                            WhisperInstructionRow(
                                number: "1",
                                title: "Install Wyoming Whisper",
                                description: "Install the Wyoming protocol-based Whisper service on your server"
                            )
                            
                            WhisperInstructionRow(
                                number: "2",
                                title: "Start Wyoming Service",
                                description: "Run the Wyoming Whisper service on port 10300 (or your preferred port)"
                            )
                            
                            WhisperInstructionRow(
                                number: "3",
                                title: "Test WebSocket Connection",
                                description: "Use the test button above to verify your Wyoming server is accessible"
                            )
                            
                            WhisperInstructionRow(
                                number: "4",
                                title: "Start Streaming Transcription",
                                description: "Your Wyoming Whisper service is ready for real-time transcription"
                            )
                        } else {
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
                }
                
                Section {
                    if selectedProtocol == .wyoming {
                        Link("Wyoming Protocol Documentation", destination: URL(string: "https://github.com/rhasspy/wyoming-whisper")!)
                        Link("Wyoming Protocol Specification", destination: URL(string: "https://github.com/rhasspy/wyoming")!)
                    } else {
                        Link("Whisper REST API Documentation", destination: URL(string: "https://github.com/guillaumekln/faster-whisper")!)
                    }
                    Link("Whisper Model Information", destination: URL(string: "https://openai.com/research/whisper")!)
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
            .onChange(of: selectedProtocol) { _, _ in
                updateWhisperService()
            }
        }
    }
    
    private var isConfigurationValid: Bool {
        !serverURL.isEmpty && port > 0 && port <= 65535
    }
    
    private func updateWhisperService() {
        print("🔧 WhisperSettingsView - Updating service with protocol: \(selectedProtocol.rawValue)")
        let config = WhisperConfig(
            serverURL: serverURL,
            port: port,
            whisperProtocol: selectedProtocol
        )
        whisperService = WhisperService(config: config, chunkingService: AudioFileChunkingService())
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