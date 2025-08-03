//
//  OllamaSettingsView.swift
//  Audio Journal
//
//  Settings view for Ollama local LLM configuration
//

import SwiftUI

struct OllamaSettingsView: View {
    @AppStorage("ollamaServerURL") private var serverURL: String = "http://localhost"
    @AppStorage("ollamaPort") private var port: Int = 11434
    @AppStorage("ollamaModelName") private var selectedModel: String = "llama2:7b"
    @AppStorage("ollamaMaxTokens") private var maxTokens: Int = 2048
    @AppStorage("ollamaTemperature") private var temperature: Double = 0.1
    /// Maximum context window the selected model supports
    @AppStorage("ollamaContextTokens") private var maxContextTokens: Int = 4096
    @AppStorage("enableOllama") private var enableOllama: Bool = false
    
    var onConfigurationChanged: (() -> Void)?
    
    @State private var ollamaService: OllamaService
    @State private var isTestingConnection = false
    @State private var isLoadingModels = false
    @State private var testResult: String?
    @State private var showingError = false
    @State private var errorMessage = ""
    
    @Environment(\.dismiss) private var dismiss
    
    init(onConfigurationChanged: (() -> Void)? = nil) {
        self.onConfigurationChanged = onConfigurationChanged
        
        // Initialize with current settings
        let serverURL = UserDefaults.standard.string(forKey: "ollamaServerURL") ?? "http://localhost"
        let port = UserDefaults.standard.integer(forKey: "ollamaPort")
        let modelName = UserDefaults.standard.string(forKey: "ollamaModelName") ?? "llama2:7b"
        let maxTokens = UserDefaults.standard.integer(forKey: "ollamaMaxTokens")
        let temperature = UserDefaults.standard.double(forKey: "ollamaTemperature")
        let contextTokens = UserDefaults.standard.integer(forKey: "ollamaContextTokens")
        
        // Ensure enableOllama has a default value in UserDefaults
        if UserDefaults.standard.object(forKey: "enableOllama") == nil {
            UserDefaults.standard.set(false, forKey: "enableOllama")
            print("🔧 OllamaSettingsView: Initialized enableOllama to false in UserDefaults")
        }
        
        let config = OllamaConfig(
            serverURL: serverURL,
            port: port > 0 ? port : 11434,
            modelName: modelName,
            maxTokens: maxTokens > 0 ? maxTokens : 2048,
            temperature: temperature > 0 ? temperature : 0.1,
            maxContextTokens: contextTokens > 0 ? contextTokens : 4096
        )
        
        _ollamaService = State(initialValue: OllamaService(config: config))
    }
    
    var body: some View {
        NavigationView {
            Form {
                headerSection
                serverConfigurationSection
                if ollamaService.isConnected {
                    modelConfigurationSection
                }
                enableToggleSection
                helpSection
            }
            .navigationTitle("Ollama Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        // Force refresh engine availability when settings are dismissed
                        UserDefaults.standard.synchronize()
                        onConfigurationChanged?()
                        dismiss()
                    }
                }
            }
            .onAppear {
                let userDefaultsValue = UserDefaults.standard.bool(forKey: "enableOllama")
                print("🔧 OllamaSettingsView: onAppear - enableOllama value: \(enableOllama)")
                print("🔧 OllamaSettingsView: UserDefaults value for enableOllama: \(userDefaultsValue)")
                loadModelsIfConnected()
            }
            .onChange(of: serverURL) {
                resetConnection()
            }
            .onChange(of: port) {
                resetConnection()
            }
            .onChange(of: selectedModel) {
                onConfigurationChanged?()
            }
            .onChange(of: maxTokens) {
                onConfigurationChanged?()
            }
            .onChange(of: maxContextTokens) {
                onConfigurationChanged?()
            }
            .onChange(of: temperature) {
                onConfigurationChanged?()
            }
            .onChange(of: enableOllama) {
                print("🔧 OllamaSettingsView: enableOllama changed to: \(enableOllama)")
                // Force UserDefaults to sync immediately
                UserDefaults.standard.synchronize()
                onConfigurationChanged?()
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    // MARK: - View Sections
    
    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "server.rack")
                        .foregroundColor(.green)
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ollama Local LLM")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        Text("Connect to your local Ollama server for privacy-focused AI processing")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Privacy Note")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                    
                    Text("All processing happens on your local machine. No data is sent to external servers.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    private var serverConfigurationSection: some View {
        Section(header: Text("Server Configuration")) {
            serverURLConfiguration
            portConfiguration
            connectionTestButton
            connectionTestResult
        }
    }
    
    private var serverURLConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server URL")
                .font(.headline)
            
            TextField("Server URL", text: $serverURL)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            Text("Enter the URL of your Ollama server (e.g., http://localhost)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var portConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Port")
                .font(.headline)
            
            TextField("Port", value: $port, format: .number.grouping(.never))
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
            
            Text("Default Ollama port is 11434")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var connectionTestButton: some View {
        Button(action: testConnection) {
            HStack {
                if isTestingConnection {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "network")
                }
                Text(isTestingConnection ? "Testing Connection..." : "Test Connection")
            }
        }
        .disabled(isTestingConnection || serverURL.isEmpty)
        .foregroundColor(.blue)
    }
    
    @ViewBuilder
    private var connectionTestResult: some View {
        if let testResult = testResult {
            Text(testResult)
                .font(.caption)
                .foregroundColor(testResult.contains("✅") ? .green : .red)
                .padding(.top, 4)
        }
    }
    
    private var modelConfigurationSection: some View {
        Section(header: Text("Model Configuration")) {
            modelSelectionView
            maxTokensConfiguration
            contextWindowConfiguration
            temperatureConfiguration
        }
    }
    
    private var modelSelectionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Available Models")
                .font(.headline)
            
            if isLoadingModels {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading models...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if ollamaService.availableModels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No models found on server")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Install a model using: ollama pull llama3.2")
                        .font(.caption.monospaced())
                        .foregroundColor(.orange)
                }
            } else {
                Picker("Select Model", selection: $selectedModel) {
                    ForEach(ollamaService.availableModels, id: \.name) { model in
                        VStack(alignment: .leading) {
                            Text(model.displayName)
                                .font(.subheadline)
                            Text("Size: \(formatFileSize(model.size))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(model.name)
                    }
                }
                .pickerStyle(MenuPickerStyle())
            }
        }
    }
    
    private var maxTokensConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Max Tokens")
                .font(.headline)
            
            HStack {
                Slider(value: Binding(
                    get: { Double(maxTokens) },
                    set: { maxTokens = Int($0) }
                ), in: 512...4096, step: 256)
                
                Text("\(maxTokens)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 60)
            }
            
            Text("Maximum number of tokens in the response")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var contextWindowConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context Window")
                .font(.headline)

            HStack {
                Slider(value: Binding(
                    get: { Double(maxContextTokens) },
                    set: { maxContextTokens = Int($0) }
                ), in: 1024...32768, step: 1024)

                Text("\(maxContextTokens)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 60)
            }

            Text("Maximum tokens the model can process at once")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var temperatureConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Temperature")
                .font(.headline)
            
            HStack {
                Slider(value: $temperature, in: 0.0...1.0, step: 0.1)
                
                Text(String(format: "%.1f", temperature))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 40)
            }
            
            Text("Lower values = more focused, Higher values = more creative")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var enableToggleSection: some View {
        Section {
            Toggle("Enable Ollama Processing", isOn: $enableOllama)
                .disabled(!ollamaService.isConnected)
            
            if !ollamaService.isConnected {
                Text("Connect to Ollama server first to enable processing")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var helpSection: some View {
        Section(header: Text("Help")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Getting Started")
                    .font(.headline)
                
                Text("1. Install Ollama from https://ollama.ai")
                    .font(.caption)
                Text("2. Pull a model: ollama pull llama3.2")
                    .font(.caption.monospaced())
                Text("3. Start the server: ollama serve")
                    .font(.caption)
                Text("4. Configure the connection above")
                    .font(.caption)
            }
            .padding(.vertical, 4)
            
            Link("Ollama Documentation", destination: URL(string: "https://ollama.ai/docs")!)
            Link("Available Models", destination: URL(string: "https://ollama.ai/library")!)
        }
    }
    
    // MARK: - Methods
    
    private func testConnection() {
        isTestingConnection = true
        testResult = nil
        
        // Update the ollamaService with current configuration
        updateOllamaServiceConfiguration()
        
        Task {
            let success = await ollamaService.testConnection()
            
            await MainActor.run {
                isTestingConnection = false
                
                if success {
                    testResult = "✅ Connection successful! Server is reachable."
                    loadModelsIfConnected()
                } else {
                    testResult = "❌ Connection failed: \(ollamaService.connectionError ?? "Unknown error")"
                }
            }
        }
    }
    
    private func loadModelsIfConnected() {
        guard ollamaService.isConnected else { return }
        
        isLoadingModels = true
        
        Task {
            do {
                _ = try await ollamaService.loadAvailableModels()
                await MainActor.run {
                    isLoadingModels = false
                }
            } catch {
                await MainActor.run {
                    isLoadingModels = false
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
    
    private func resetConnection() {
        // Update the ollamaService with current configuration
        updateOllamaServiceConfiguration()
        
        ollamaService.isConnected = false
        ollamaService.availableModels = []
        testResult = nil
    }
    
    private func updateOllamaServiceConfiguration() {
        let config = OllamaConfig(
            serverURL: serverURL,
            port: port,
            modelName: selectedModel,
            maxTokens: maxTokens,
            temperature: temperature,
            maxContextTokens: maxContextTokens
        )
        
        // Create a new OllamaService instance with the updated configuration
        ollamaService = OllamaService(config: config)
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct OllamaSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        OllamaSettingsView()
    }
} 