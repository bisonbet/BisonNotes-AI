//
//  OpenAISummarizationSettingsView.swift
//  Audio Journal
//
//  Settings view for OpenAI summarization configuration
//

import SwiftUI

struct OpenAISummarizationSettingsView: View {
    @AppStorage("openAISummarizationAPIKey") private var apiKey: String = ""
    @AppStorage("openAISummarizationModel") private var selectedModel: String = OpenAISummarizationModel.gpt35Turbo.rawValue
    @AppStorage("openAISummarizationBaseURL") private var baseURL: String = "https://api.openai.com/v1"
    @AppStorage("openAISummarizationTemperature") private var temperature: Double = 0.1
    @AppStorage("openAISummarizationMaxTokens") private var maxTokens: Int = 0
    @AppStorage("enableOpenAI") private var enableOpenAI: Bool = true
    
    @State private var isTestingConnection = false
    @State private var connectionTestResult: String = ""
    @State private var showingConnectionResult = false
    @State private var isConnectionSuccessful = false
    @State private var showingAPIKeyInfo = false
    @State private var isLoadingModels = false
    @State private var availableModels: [OpenAIModel] = []
    @State private var showingModelFetchError = false
    @State private var modelFetchError = ""
    @State private var useDynamicModels = false
    
    @Environment(\.dismiss) private var dismiss
    
    var onConfigurationChanged: (() -> Void)?
    
    init(onConfigurationChanged: (() -> Void)? = nil) {
        self.onConfigurationChanged = onConfigurationChanged
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
                            Text("API key required for OpenAI")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Your API key is stored securely on your device and only used for summarization requests.")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Base URL")
                        
                        TextField("API Base URL", text: $baseURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        
                        Text("Default: https://api.openai.com/v1")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("API Configuration")
                } footer: {
                    Text("Configure the base URL for OpenAI API.")
                }
                
                Section {
                    Toggle("Fetch Available Models", isOn: $useDynamicModels)
                        .onChange(of: useDynamicModels) {
                            if useDynamicModels {
                                loadAvailableModels()
                            } else {
                                availableModels = []
                            }
                        }
                    
                    if useDynamicModels {
                        if isLoadingModels {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading models...")
                                    .font(.caption)
                            }
                        } else if !availableModels.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Available Models (\(availableModels.count))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Picker("Model", selection: $selectedModel) {
                                    ForEach(availableModels) { model in
                                        Text(model.displayName)
                                            .tag(model.id)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                            }
                        }
                        
                        if showingModelFetchError {
                            Text("Error: \(modelFetchError)")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    } else {
                        Picker("Model", selection: $selectedModel) {
                            ForEach(OpenAISummarizationModel.allCases, id: \.self) { model in
                                Text(model.displayName)
                                    .tag(model.rawValue)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                } header: {
                    Text("Model Selection")
                } footer: {
                    Text("Choose the AI model for summarization. Dynamic models are fetched from your API.")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Temperature: \(temperature, specifier: "%.2f")")
                        
                        Slider(value: $temperature, in: 0.0...1.0, step: 0.1)
                            .accentColor(.blue)
                        
                        Text("Controls randomness in responses. Lower values are more deterministic.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Generation Settings")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Max Tokens: \(maxTokens == 0 ? "Unlimited" : "\(maxTokens)")")
                        
                        HStack {
                            Slider(value: Binding(
                                get: { Double(maxTokens) },
                                set: { maxTokens = Int($0) }
                            ), in: 0...4096, step: 1)
                            .accentColor(.blue)
                            
                            Button("Reset") {
                                maxTokens = 0
                            }
                            .font(.caption)
                        }
                        
                        Text("Maximum tokens for response. 0 = unlimited")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Response Limits")
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
                            Text(isTestingConnection ? "Testing..." : "Test Connection")
                        }
                    }
                    .disabled(apiKey.isEmpty || isTestingConnection)
                } header: {
                    Text("Connection Test")
                } footer: {
                    Text("Test your API connection and model availability.")
                }
            }
            .navigationTitle("OpenAI Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onConfigurationChanged?()
                        dismiss()
                    }
                }
            }
            .alert("Connection Test Result", isPresented: $showingConnectionResult) {
                Button("OK") { }
            } message: {
                Text(connectionTestResult)
            }
            .alert("API Key Information", isPresented: $showingAPIKeyInfo) {
                Button("OK") { }
            } message: {
                Text("Get your API key from https://platform.openai.com/api-keys")
            }
        }
    }
    
    private func testConnection() {
        isTestingConnection = true
        
        Task {
            do {
                let config = OpenAISummarizationConfig(
                    apiKey: apiKey,
                    model: OpenAISummarizationModel(rawValue: selectedModel) ?? .gpt35Turbo,
                    baseURL: baseURL,
                    temperature: temperature,
                    maxTokens: maxTokens == 0 ? nil : maxTokens
                )
                
                let service = OpenAISummarizationService(config: config)
                try await service.testConnection()
                
                await MainActor.run {
                    isConnectionSuccessful = true
                    connectionTestResult = "✅ Connection successful! Your API key and configuration are working correctly."
                    showingConnectionResult = true
                    isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    isConnectionSuccessful = false
                    connectionTestResult = "❌ Connection failed: \(error.localizedDescription)"
                    showingConnectionResult = true
                    isTestingConnection = false
                }
            }
        }
    }
    
    private func loadAvailableModels() {
        guard !apiKey.isEmpty else { return }
        
        isLoadingModels = true
        modelFetchError = ""
        showingModelFetchError = false
        
        Task {
            do {
                let config = OpenAISummarizationConfig(
                    apiKey: apiKey,
                    model: .gpt35Turbo,
                    baseURL: baseURL
                )
                
                let service = OpenAISummarizationService(config: config)
                let models = try await service.fetchAvailableModels()
                
                await MainActor.run {
                    availableModels = models
                    isLoadingModels = false
                    
                    if !models.isEmpty && selectedModel.isEmpty {
                        selectedModel = models.first?.id ?? ""
                    }
                }
            } catch {
                await MainActor.run {
                    modelFetchError = error.localizedDescription
                    showingModelFetchError = true
                    isLoadingModels = false
                }
            }
        }
    }
    
    private func resetToDefaults() {
        apiKey = ""
        selectedModel = OpenAISummarizationModel.gpt35Turbo.rawValue
        baseURL = "https://api.openai.com/v1"
        temperature = 0.1
        maxTokens = 0
        useDynamicModels = false
        availableModels = []
        showingConnectionResult = false
        showingModelFetchError = false
        modelFetchError = ""
    }
}

// MARK: - OpenAI API Compatible Settings View

struct OpenAICompatibleSettingsView: View {
    @AppStorage("openAICompatibleAPIKey") private var apiKey: String = ""
    @AppStorage("openAICompatibleModel") private var selectedModel: String = "gpt-3.5-turbo"
    @AppStorage("openAICompatibleBaseURL") private var baseURL: String = "https://api.openai.com/v1"
    @AppStorage("openAICompatibleTemperature") private var temperature: Double = 0.1
    @AppStorage("openAICompatibleMaxTokens") private var maxTokens: Int = 2048
    @AppStorage("enableOpenAICompatible") private var enableOpenAICompatible: Bool = false
    
    @State private var isTestingConnection = false
    @State private var connectionTestResult: String = ""
    @State private var showingConnectionResult = false
    @State private var isConnectionSuccessful = false
    @State private var showingAPIKeyInfo = false
    @State private var isLoadingModels = false
    @State private var availableModels: [OpenAIModel] = []
    @State private var showingModelFetchError = false
    @State private var modelFetchError = ""
    @State private var useDynamicModels = false
    
    @Environment(\.dismiss) private var dismiss
    
    var onConfigurationChanged: (() -> Void)?
    
    init(onConfigurationChanged: (() -> Void)? = nil) {
        self.onConfigurationChanged = onConfigurationChanged
        
        // Ensure enableOpenAICompatible has a default value in UserDefaults
        if UserDefaults.standard.object(forKey: "enableOpenAICompatible") == nil {
            UserDefaults.standard.set(false, forKey: "enableOpenAICompatible")
            print("🔧 OpenAICompatibleSettingsView: Initialized enableOpenAICompatible to false in UserDefaults")
        }
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
                        
                        SecureField("Enter your API key", text: $apiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        if !apiKey.isEmpty {
                            Text("API key configured (\(apiKey.count) characters)")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Text("API key required for OpenAI compatible API")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Your API key is stored securely on your device and only used for summarization requests.")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Base URL")
                        
                        TextField("API Base URL", text: $baseURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        
                        Text("Use your OpenAI-compatible API endpoint")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("API Configuration")
                } footer: {
                    Text("Configure the base URL for your OpenAI-compatible API provider.")
                }
                
                Section {
                    Toggle("Fetch Available Models", isOn: $useDynamicModels)
                        .onChange(of: useDynamicModels) {
                            if useDynamicModels {
                                loadAvailableModels()
                            } else {
                                availableModels = []
                            }
                        }
                    
                    if useDynamicModels {
                        if isLoadingModels {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading available models...")
                            }
                        } else if !availableModels.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Available Models")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                ForEach(availableModels.prefix(5)) { model in
                                    HStack {
                                        Text(model.displayName)
                                            .font(.caption)
                                        Spacer()
                                        Text(model.id)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                if availableModels.count > 5 {
                                    Text("... and \(availableModels.count - 5) more")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else if showingModelFetchError {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("Failed to load models: \(modelFetchError)")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    
                    if !useDynamicModels || availableModels.isEmpty {
                        TextField("Model ID", text: $selectedModel)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Selected: \(selectedModel)")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            Text("Enter the model ID for your API provider")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        // Dynamic model selection
                        Picker("Model", selection: $selectedModel) {
                            ForEach(availableModels, id: \.id) { model in
                                Text(model.displayName)
                                    .tag(model.id)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        
                        if let selectedModelInfo = availableModels.first(where: { $0.id == selectedModel }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Selected: \(selectedModelInfo.displayName)")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Text("Model ID: \(selectedModelInfo.id)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Model Selection")
                } footer: {
                    if useDynamicModels {
                        Text("Fetch models from your API endpoint to see available options.")
                    } else {
                        Text("Enter the model ID (e.g., gpt-3.5-turbo, gpt-4, claude-3-sonnet) for your API provider.")
                    }
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(String(format: "%.1f", temperature))
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $temperature, in: 0.0...1.0, step: 0.1)
                        
                        Text("Controls randomness: 0.0 = focused and deterministic, 1.0 = creative and varied")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Max Tokens")
                            Spacer()
                            Text("\(maxTokens)")
                                .foregroundColor(.secondary)
                        }
                        
                        Stepper(value: $maxTokens, in: 256...8192, step: 256) {
                            EmptyView()
                        }
                        
                        Text("Maximum tokens for response. Higher values allow longer summaries but cost more.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Generation Parameters")
                } footer: {
                    Text("Fine-tune the AI's behavior. Lower temperature for consistent results, higher for more creative summaries.")
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
                    Text("Test your API key and connection to ensure summarization will work properly.")
                }
                
                Section {
                    FeatureRow(
                        icon: "brain.head.profile",
                        title: "Advanced AI Analysis",
                        description: "Comprehensive summaries with task and reminder extraction"
                    )
                    
                    FeatureRow(
                        icon: "list.bullet.clipboard",
                        title: "Smart Task Detection",
                        description: "Automatically identifies actionable items with priorities"
                    )
                    
                    FeatureRow(
                        icon: "bell.badge",
                        title: "Reminder Extraction",
                        description: "Finds time-sensitive items and deadlines"
                    )
                    
                    FeatureRow(
                        icon: "doc.text.magnifyingglass",
                        title: "Content Classification",
                        description: "Automatically categorizes content type for better analysis"
                    )
                    
                    FeatureRow(
                        icon: "textformat.size",
                        title: "Chunked Processing",
                        description: "Handles large transcripts by intelligent text splitting"
                    )
                    
                    FeatureRow(
                        icon: "dollarsign.circle",
                        title: "Usage-Based Pricing",
                        description: "Pay only for tokens used in summarization"
                    )
                } header: {
                    Text("Features & Capabilities")
                }
                
                Section {
                    Toggle("Enable OpenAI Compatible Processing", isOn: $enableOpenAICompatible)
                        .onChange(of: enableOpenAICompatible) {
                            print("🔧 OpenAICompatibleSettingsView: enableOpenAICompatible changed to: \(enableOpenAICompatible)")
                            // Force UserDefaults to sync immediately
                            UserDefaults.standard.synchronize()
                            onConfigurationChanged?()
                        }
                    
                    if !enableOpenAICompatible {
                        Text("OpenAI Compatible processing is disabled. Enable to use compatible APIs for summarization.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Enable/Disable")
                }
                
                Section {
                    Button("Reset to Defaults") {
                        resetToDefaults()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("OpenAI Compatible")
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
            .alert("API Key Information", isPresented: $showingAPIKeyInfo) {
                Button("OK") { }
            } message: {
                Text("You can get your API key from your OpenAI-compatible API provider. This could be OpenAI, Azure OpenAI, or any other compatible service.")
            }
        }
    }
    
    private func loadAvailableModels() {
        isLoadingModels = true
        availableModels = []
        modelFetchError = ""
        
        Task {
            do {
                let models = try await OpenAICompatibleService.fetchModels(apiKey: apiKey, baseURL: baseURL)
                await MainActor.run {
                    availableModels = models
                    isLoadingModels = false
                }
            } catch {
                await MainActor.run {
                    modelFetchError = error.localizedDescription
                    showingModelFetchError = true
                    isLoadingModels = false
                }
            }
        }
    }
    
    private func testConnection() {
        guard !apiKey.isEmpty else { return }
        
        isTestingConnection = true
        showingConnectionResult = false
        
        Task {
            let config = OpenAICompatibleConfig(
                apiKey: apiKey,
                modelId: selectedModel,
                baseURL: baseURL,
                temperature: temperature,
                maxTokens: maxTokens
            )
            
            let service = OpenAICompatibleService(config: config)
            
            do {
                try await service.testConnection()
                
                await MainActor.run {
                    connectionTestResult = "Connection successful! API key is valid and model is accessible."
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
        selectedModel = "gpt-3.5-turbo"
        baseURL = "https://api.openai.com/v1"
        temperature = 0.1
        maxTokens = 2048
        useDynamicModels = false
        availableModels = []
        showingConnectionResult = false
        showingModelFetchError = false
        modelFetchError = ""
    }
}

struct OpenAICompatibleSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        OpenAICompatibleSettingsView()
    }
}