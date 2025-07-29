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
    
    @Environment(\.dismiss) private var dismiss
    
    var onConfigurationChanged: (() -> Void)?
    
    private var selectedModelEnum: OpenAISummarizationModel {
                    OpenAISummarizationModel(rawValue: selectedModel) ?? .gpt35Turbo
    }
    
    init(onConfigurationChanged: (() -> Void)? = nil) {
        self.onConfigurationChanged = onConfigurationChanged
        
        // Ensure enableOpenAI has a default value in UserDefaults
        if UserDefaults.standard.object(forKey: "enableOpenAI") == nil {
            UserDefaults.standard.set(true, forKey: "enableOpenAI")
            print("🔧 OpenAISummarizationSettingsView: Initialized enableOpenAI to true in UserDefaults")
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
                        
                        SecureField("Enter your OpenAI API key", text: $apiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        if !apiKey.isEmpty {
                            Text("API key configured (\(apiKey.count) characters)")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Text("API key required for OpenAI summarization")
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
                    Picker("Model", selection: $selectedModel) {
                        ForEach(OpenAISummarizationModel.allCases, id: \.rawValue) { model in
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
                        
                        HStack {
                            Label("Max Tokens: \(selectedModelEnum.maxTokens)", systemImage: "textformat")
                                .font(.caption)
                                .foregroundColor(.blue)
                            
                            Spacer()
                            
                            Text(selectedModelEnum.costTier)
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(costTierColor.opacity(0.2))
                                .foregroundColor(costTierColor)
                                .cornerRadius(4)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Model Selection")
                } footer: {
                    Text("GPT-4.1 provides the most comprehensive analysis. Mini offers balanced performance and cost. Nano is fastest and most economical.")
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
                            Text(maxTokens > 0 ? "\(maxTokens)" : "Auto (\(selectedModelEnum.maxTokens))")
                                .foregroundColor(.secondary)
                        }
                        
                        Stepper(value: $maxTokens, in: 0...selectedModelEnum.maxTokens, step: 256) {
                            EmptyView()
                        }
                        
                        Text("Maximum tokens for response. 0 uses model default. Higher values allow longer summaries but cost more.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Generation Parameters")
                } footer: {
                    Text("Fine-tune the AI's behavior. Lower temperature for consistent results, higher for more creative summaries.")
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
                    Toggle("Enable OpenAI Processing", isOn: $enableOpenAI)
                        .onChange(of: enableOpenAI) {
                            print("🔧 OpenAISummarizationSettingsView: enableOpenAI changed to: \(enableOpenAI)")
                            // Force UserDefaults to sync immediately
                            UserDefaults.standard.synchronize()
                            onConfigurationChanged?()
                        }
                    
                    if !enableOpenAI {
                        Text("OpenAI processing is disabled. Enable to use OpenAI for summarization.")
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
            .navigationTitle("OpenAI Summarization")
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
                Text("You can get your OpenAI API key from platform.openai.com. Go to API Keys section and create a new secret key. Make sure your account has sufficient credits for summarization usage.")
            }
        }
    }
    
    private var costTierColor: Color {
        switch selectedModelEnum.costTier {
        case "Premium":
            return .purple
        case "Standard":
            return .blue
        case "Economy":
            return .green
        default:
            return .gray
        }
    }
    
    private func testConnection() {
        guard !apiKey.isEmpty else { return }
        
        isTestingConnection = true
        showingConnectionResult = false
        
        Task {
            let config = OpenAISummarizationConfig(
                apiKey: apiKey,
                model: selectedModelEnum,
                baseURL: baseURL,
                temperature: temperature,
                maxTokens: maxTokens > 0 ? maxTokens : nil
            )
            
            let service = OpenAISummarizationService(config: config)
            
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
                        selectedModel = OpenAISummarizationModel.gpt35Turbo.rawValue
        baseURL = "https://api.openai.com/v1"
        temperature = 0.1
        maxTokens = 0
        showingConnectionResult = false
    }
}

struct OpenAISummarizationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        OpenAISummarizationSettingsView()
    }
}