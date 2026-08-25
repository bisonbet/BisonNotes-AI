//
//  OpenAICompatibleSettingsView.swift
//  BisonNotes AI
//
//  Settings view for compatible API summarization configuration
//

import SwiftUI

// MARK: - Compatible API Settings View

@MainActor
struct OpenAICompatibleSettingsView: View {
    @SecureStorage(KeychainSecretStore.openAICompatibleAPIKey) private var apiKey: String = ""
    @AppStorage("openAICompatibleModel") private var selectedModel: String = ""
    @AppStorage("openAICompatibleBaseURL") private var baseURL: String = ""
    @AppStorage("openAICompatibleTemperature") private var temperature: Double = 0.1
    @AppStorage("openAICompatibleMaxTokens") private var maxTokens: Int = 2048
    @AppStorage("enableOpenAICompatible") private var enableOpenAICompatible: Bool = false
    @AppStorage("openAICompatibleManualFormatOverride") private var manualFormatOverride: Bool = false
    @AppStorage("openAICompatibleManualFormat") private var manualFormat: String = "string"
    @AppStorage(EndpointSecurityPolicy.allowInsecurePublicEndpointsKey) private var allowInsecurePublicEndpoints: Bool = false

    @State private var isTestingConnection = false
    @State private var connectionTestResult: String = ""
    @State private var showingConnectionResult = false
    @State private var isConnectionSuccessful = false
    @State private var showingAPIKeyInfo = false
    @State private var isLoadingModels = false
    @State private var availableModelIds: [String] = []
    @State private var showingModelFetchError = false
    @State private var modelFetchError = ""
    @State private var useDynamicModels = false

    @Environment(\.dismiss) private var dismiss

    var onConfigurationChanged: (() -> Void)?

    init(onConfigurationChanged: (() -> Void)? = nil) {
        self.onConfigurationChanged = onConfigurationChanged
    }

    // MARK: - Private Methods

    private func loadAvailableModels() {
        guard !apiKey.isEmpty else {
            modelFetchError = "Please enter an API key first"
            showingModelFetchError = true
            return
        }

        guard !baseURL.isEmpty else {
            modelFetchError = "Please enter a base URL first"
            showingModelFetchError = true
            return
        }

        isLoadingModels = true
        modelFetchError = ""
        showingModelFetchError = false

        let apiKey = apiKey
        let baseURL = baseURL
        let allowInsecurePublicEndpoints = allowInsecurePublicEndpoints

        Task { @MainActor in
            do {
                let modelIds = try await OpenAICompatibleService.fetchCompatibleModels(
                    apiKey: apiKey,
                    baseURL: baseURL,
                    allowInsecurePublicEndpoints: allowInsecurePublicEndpoints
                )

                availableModelIds = modelIds
                if !modelIds.isEmpty && selectedModel.isEmpty {
                    selectedModel = modelIds.first!
                }

                isLoadingModels = false

                AppLog.shared.general("Successfully loaded \(modelIds.count) models")
                if !modelIds.isEmpty {
                    AppLog.shared.general("Models: \(modelIds.prefix(5).joined(separator: ", "))\(modelIds.count > 5 ? "..." : "")", level: .debug)
                }
            } catch {
                modelFetchError = error.localizedDescription
                showingModelFetchError = true
                isLoadingModels = false
                AppLog.shared.general("Failed to load models: \(error)", level: .error)
            }
        }
    }

    private func testConnection() {
        guard !apiKey.isEmpty else { return }

        isTestingConnection = true
        showingConnectionResult = false

        let config = OpenAICompatibleConfig(
            apiKey: apiKey,
            modelID: selectedModel,
            baseURL: baseURL,
            temperature: temperature,
            maxTokens: maxTokens,
            timeout: SummarizationTimeouts.current(),
            dynamicModelId: selectedModel
        )
        let service = OpenAICompatibleService(config: config)

        Task { @MainActor in
            let success = await service.testConnection()

            connectionTestResult = success
                ? "Connection successful! API key is valid and model is accessible."
                : "Connection failed. Please check your API key and configuration."
            isConnectionSuccessful = success
            showingConnectionResult = true
            isTestingConnection = false
        }
    }

    private func resetToDefaults() {
        apiKey = ""
        selectedModel = ""
        baseURL = ""
        temperature = 0.1
        maxTokens = 2048
        useDynamicModels = false
        availableModelIds = []
        showingConnectionResult = false
        showingModelFetchError = false
        modelFetchError = ""
        manualFormatOverride = false
        manualFormat = "string"
    }

    var body: some View {
        PlatformSettingsNavigationStack {
            Form {
                compatibilityGuideSection
                authenticationSection
                apiConfigurationSection
                modelSelectionSection
                generationParametersSection
                messageFormatSection
                connectionTestSection
                featuresSection
            }
            .nativeMacSettingsFormStyle()
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Compatible API")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
#if !os(macOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        // Ensure it's enabled when user is done configuring
                        let selectedEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? ""
                        if selectedEngine == "OpenAI API Compatible" {
                            UserDefaults.standard.set(true, forKey: "enableOpenAICompatible")
                        }

                        // Force refresh engine availability when settings are dismissed
                        UserDefaults.standard.synchronize()
                        onConfigurationChanged?()
                        dismiss()
                    }
                }
#endif
            }
            .alert("API Key Information", isPresented: $showingAPIKeyInfo) {
                Button("OK") { }
            } message: {
                Text("Get your API key from your provider:\n\n• OpenRouter: openrouter.ai\n• Together AI: api.together.xyz\n• Groq: console.groq.com\n• Replicate: replicate.com\n• Fireworks AI: fireworks.ai\n• Local services (LiteLLM, vLLM, LocalAI): May not require a real key, use any value like 'local'")
            }
            .onAppear {
                // Auto-enable when this is the selected engine
                let selectedEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? ""
                if selectedEngine == "OpenAI API Compatible" && !enableOpenAICompatible {
                    enableOpenAICompatible = true
                    AppLog.shared.general("OpenAICompatibleSettingsView: Auto-enabled on appear")
                }
            }
#if os(macOS)
            .onChange(of: apiKey) {
                onConfigurationChanged?()
            }
            .onChange(of: selectedModel) {
                onConfigurationChanged?()
            }
            .onChange(of: baseURL) {
                onConfigurationChanged?()
            }
            .onChange(of: temperature) {
                onConfigurationChanged?()
            }
            .onChange(of: maxTokens) {
                onConfigurationChanged?()
            }
            .onChange(of: enableOpenAICompatible) {
                onConfigurationChanged?()
            }
            .onChange(of: manualFormatOverride) {
                onConfigurationChanged?()
            }
            .onChange(of: manualFormat) {
                onConfigurationChanged?()
            }
            .onChange(of: allowInsecurePublicEndpoints) {
                onConfigurationChanged?()
            }
#endif
        }
    }

    // MARK: - View Components

    private var statusSection: some View {
        let selectedEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? ""
        let isSelectedEngine = selectedEngine == "OpenAI API Compatible"

        return Section {
            if isSelectedEngine {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Active Engine")
                        .fontWeight(.medium)
                    Spacer()
                    if enableOpenAICompatible {
                        Text("Enabled")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(8)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    Text("Not currently selected as AI engine")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("Status")
        } footer: {
            if isSelectedEngine {
                Text("This engine is currently active and will be used for AI processing. It has been automatically enabled.")
            } else {
                Text("To use this engine, select 'Compatible API' in the AI Engine settings.")
            }
        }
    }

    private var compatibilityGuideSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Main message
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model Compatibility Varies")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("Different models have different capabilities. Some trial and error may be needed.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // What works well
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Usually Work Well")
                            .font(.caption)
                            .fontWeight(.medium)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("• Larger models (70B+ parameters)")
                            .font(.caption2)
                        Text("• Models from major providers")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)
                }

                Divider()

                // May need tuning
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("May Need Adjustment")
                            .font(.caption)
                            .fontWeight(.medium)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("• Smaller models (<10B parameters)")
                            .font(.caption2)
                        Text("• Local models via Ollama/vLLM")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)
                }

                Divider()

                // Troubleshooting tips
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("Troubleshooting Tips")
                            .font(.caption)
                            .fontWeight(.medium)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("1. Test connection first")
                            .font(.caption2)
                        Text("2. Try different temperature settings")
                            .font(.caption2)
                        Text("3. Increase max tokens if output is cut off")
                            .font(.caption2)
                        Text("4. Try a different model from your provider")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Compatibility Guide")
        } footer: {
            Text("This engine supports many providers through LiteLLM, OpenRouter, and similar services. JSON output quality varies by model. Larger, more recent models generally perform better.")
        }
    }

    private var authenticationSection: some View {
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

                SecureField("sk-... or your provider's key format", text: $apiKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                if !apiKey.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("API key configured (\(apiKey.count) characters)")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("API key required to connect to your provider")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
        } header: {
            Text("Authentication")
        } footer: {
            Text("Your API key is stored securely on your device and only used for AI summarization. Some providers (like LocalAI or local LiteLLM) may not require an API key - in that case, you can use any placeholder value.")
        }

    }

    private var apiConfigurationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Base URL")

                TextField("https://api.example.com/v1", text: $baseURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)

                if !baseURL.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text(baseURL)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Enter your API endpoint URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                endpointSecurityWarning(for: baseURL)
            }
        } header: {
            Text("API Configuration")
        } footer: {
            Text("Enter the base URL for your compatible API. Examples:\n• LiteLLM: http://localhost:4000\n• vLLM: http://localhost:8000/v1\n• LocalAI: http://localhost:8080/v1\n• OpenRouter: https://openrouter.ai/api/v1\n• Together AI: https://api.together.xyz/v1")
        }

    }

    private var modelSelectionSection: some View {
        Section {
            Toggle("Fetch Available Models", isOn: $useDynamicModels)
                .onChange(of: useDynamicModels) {
                    if useDynamicModels {
                        loadAvailableModels()
                    } else {
                        availableModelIds = []
                    }
                }

            dynamicModelsContent
            manualModelContent
        } header: {
            Text("Model Selection")
        } footer: {
            if useDynamicModels {
                Text("Enable to discover models from your API endpoint automatically. If your provider supports the /models endpoint (like LiteLLM, vLLM, LocalAI), it will list all available models.")
            } else {
                Text("Enter the model ID manually. Common examples: claude-sonnet-4-5-20250929, llama-4-maverick, gemini-2.5-flash, deepseek-chat, etc.")
            }
        }
    }

    @ViewBuilder
    private var dynamicModelsContent: some View {
        if useDynamicModels {
            if isLoadingModels {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading available models...")
                }
            } else if !availableModelIds.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Found \(availableModelIds.count) Available Models")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.green)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(availableModelIds, id: \.self) { modelId in
                                Button(action: {
                                    selectedModel = modelId
                                }) {
                                    HStack {
                                        Text(modelId)
                                            .font(.subheadline)
                                            .foregroundColor(selectedModel == modelId ? .blue : .primary)
                                        Spacer()
                                        if selectedModel == modelId {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.blue)
                                                .font(.caption)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            } else if showingModelFetchError {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("Model Discovery Failed")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                    }

                    Text(modelFetchError)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("You can still enter a model ID manually below")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }

    @ViewBuilder
    private var manualModelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model ID")
                .font(.subheadline)
                .fontWeight(.medium)

            TextField("e.g., claude-sonnet-4-5, llama-4-maverick", text: $selectedModel)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)

            if !selectedModel.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("Selected: \(selectedModel)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Enter the model ID exactly as provided by your API")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var generationParametersSection: some View {
        Section {
            temperatureControl
            maxTokensControl
        } header: {
            Text("Generation Parameters")
        } footer: {
            Text("Fine-tune the AI's behavior. Lower temperature for consistent results, higher for more creative summaries.")
        }
    }

    private var temperatureControl: some View {
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
    }

    private var maxTokensControl: some View {
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

            Text("Maximum tokens for the summary itself. Higher values allow longer summaries but cost more. "
                + "Thinking models get extra room on top of this so their reasoning pass does not cut the summary short.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var messageFormatSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Auto-detected format info
                if !baseURL.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .foregroundColor(.blue)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto-Detected Format")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text(MessageFormatDetector.getDetectedFormatString(for: baseURL))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.bottom, 8)
                }

                // Manual override toggle
                Toggle("Override Format Detection", isOn: $manualFormatOverride)

                // Manual format picker (only shown when override is enabled)
                if manualFormatOverride {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Message Format")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Picker("Format", selection: $manualFormat) {
                            Text("Simple String").tag("string")
                            Text("Content Blocks").tag("blocks")
                        }
                        .pickerStyle(SegmentedPickerStyle())

                        // Format explanation
                        VStack(alignment: .leading, spacing: 4) {
                            if manualFormat == "string" {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundColor(.blue)
                                        .font(.caption)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Simple String Format")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        Text("Standard chat-completion format: {\"content\": \"text\"}")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text("Used by: Groq, OpenRouter, Together AI, and similar providers")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            } else {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundColor(.blue)
                                        .font(.caption)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Content Blocks Format")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        Text("Block-based format: {\"content\": [{\"type\": \"text\", \"text\": \"...\"}]}")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text("Used by: Nebius, Anthropic, some Fireworks models")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.top, 4)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }
        } header: {
            Text("Message Format")
        } footer: {
            if manualFormatOverride {
                Text("Using manual format override. Disable to use automatic detection based on your API provider.")
            } else {
                Text("Format is automatically detected from your base URL. Enable override only if auto-detection fails.")
            }
        }
    }

    private var connectionTestSection: some View {
        Section {
            connectionTestButton
            connectionTestResultView
        } header: {
            Text("Connection Test")
        } footer: {
            Text("Test your API connection. A successful test means the provider is reachable, but individual model performance may vary. If your model produces poor results, try a different model or adjust generation parameters.")
        }
    }

    private var connectionTestButton: some View {
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
    }

    @ViewBuilder
    private var connectionTestResultView: some View {
        if showingConnectionResult {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: isConnectionSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(isConnectionSuccessful ? .green : .red)

                    Text(connectionTestResult)
                        .font(.caption)
                        .foregroundColor(isConnectionSuccessful ? .green : .red)
                }

                if !isConnectionSuccessful {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Common Issues:")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.orange)
                        Text("• Check API key is correct")
                            .font(.caption2)
                        Text("• Verify base URL (no trailing slash)")
                            .font(.caption2)
                        Text("• Ensure model name is valid for provider")
                            .font(.caption2)
                        Text("• Check service/proxy is running")
                            .font(.caption2)
                        Text("• Review console logs for details")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }
            }
        }
    }

    private var featuresSection: some View {
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
    }

    @ViewBuilder
    private func endpointSecurityWarning(for endpoint: String) -> some View {
        if let warning = EndpointSecurityPolicy.warningMessage(for: endpoint) {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
        }

        if EndpointSecurityPolicy.validationMessage(for: endpoint, allowInsecurePublicEndpoints: false) != nil {
            Toggle("Development Mode: Allow Public HTTP", isOn: $allowInsecurePublicEndpoints)
                .font(.caption)
        }
    }

}

struct OpenAICompatibleSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        OpenAICompatibleSettingsView()
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
