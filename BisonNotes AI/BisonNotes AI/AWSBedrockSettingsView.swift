//
//  AWSBedrockSettingsView.swift
//  Audio Journal
//
//  Settings view for AWS Bedrock AI summarization configuration
//

import SwiftUI

struct AWSBedrockSettingsView: View {
    @ObservedObject private var credentialsManager = AWSCredentialsManager.shared
    @AppStorage("awsBedrockSessionToken") private var sessionToken: String = ""
    @AppStorage("awsBedrockModel") private var selectedModel: String = AWSBedrockModel.llama4Maverick.rawValue
    @AppStorage("awsBedrockTemperature") private var temperature: Double = 0.1
    @AppStorage("awsBedrockMaxTokens") private var maxTokens: Int = 4096
    @AppStorage("awsBedrockUseProfile") private var useProfile: Bool = false
    @AppStorage("awsBedrockProfileName") private var profileName: String = ""
    @AppStorage("enableAWSBedrock") private var enableAWSBedrock: Bool = false
    
    @Environment(\.dismiss) private var dismiss
    @State private var showingCredentials = false
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var availableModels: [AWSBedrockModel] = AWSBedrockModel.allCases
    @State private var isLoadingModels = false
    
    // Local state for editing (sync with unified credentials)
    @State private var editingAccessKey: String = ""
    @State private var editingSecretKey: String = ""
    @State private var editingRegion: String = "us-east-1"
    
    private let regions = [
        "us-east-1": "US East (N. Virginia)",
        "us-east-2": "US East (Ohio)",
        "us-west-1": "US West (N. California)",
        "us-west-2": "US West (Oregon)"
    ]
    
    private var selectedModelEnum: AWSBedrockModel {
        return AWSBedrockModel(rawValue: selectedModel) ?? .llama4Maverick
    }
    
    var body: some View {
        NavigationView {
            Form {
                headerSection
                
                if enableAWSBedrock {
                    authenticationSection
                    modelConfigurationSection
                    advancedSettingsSection
                    connectionTestSection
                    setupInstructionsSection
                    documentationSection
                }
            }
            .navigationTitle("AWS Bedrock Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // Initialize editing states with current credentials
            editingAccessKey = credentialsManager.credentials.accessKeyId
            editingSecretKey = credentialsManager.credentials.secretAccessKey
            editingRegion = credentialsManager.credentials.region
            
            // Validate and fix invalid stored model selection
            if AWSBedrockModel(rawValue: selectedModel) == nil {
                print("⚠️ Invalid stored model '\(selectedModel)', resetting to default")
                selectedModel = AWSBedrockModel.llama4Maverick.rawValue
            }
        }
    }
    
    private var headerSection: some View {
        Section(header: Text("AWS Bedrock AI")) {
            Toggle("Enable AWS Bedrock", isOn: $enableAWSBedrock)
            
            if enableAWSBedrock {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AWS Bedrock provides access to foundation models from Anthropic, Amazon, Meta, and other providers for high-quality AI summaries and content analysis.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Context Window")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(selectedModelEnum.contextWindow/1000)K tokens")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Provider")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(selectedModelEnum.provider)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cost Tier")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(selectedModelEnum.costTier)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(costTierColor(selectedModelEnum.costTier))
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray6))
                    )
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    private var authenticationSection: some View {
        Section(header: Text("Authentication")) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Authentication Method", selection: $useProfile) {
                    Text("Access Keys").tag(false)
                    Text("AWS Profile").tag(true)
                }
                .pickerStyle(SegmentedPickerStyle())
                
                if useProfile {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AWS Profile Name")
                            .font(.headline)
                        
                        TextField("Enter profile name (e.g., default)", text: $profileName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        Text("Use an AWS profile configured with the AWS CLI or SDK. The profile should have access to AWS Bedrock in the selected region.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Access Key ID")
                            Spacer()
                            Button("Show/Hide") {
                                showingCredentials.toggle()
                            }
                            .font(.caption)
                        }
                        
                        if showingCredentials {
                            TextField("Enter Access Key ID", text: $editingAccessKey)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .onChange(of: editingAccessKey) { _, newValue in
                                    credentialsManager.updateAccessKey(newValue)
                                }
                        } else {
                            SecureField("Enter Access Key ID", text: $editingAccessKey)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .onChange(of: editingAccessKey) { _, newValue in
                                    credentialsManager.updateAccessKey(newValue)
                                }
                        }
                        
                        HStack {
                            Text("Secret Access Key")
                            Spacer()
                            Button("Show/Hide") {
                                showingCredentials.toggle()
                            }
                            .font(.caption)
                        }
                        
                        if showingCredentials {
                            TextField("Enter Secret Access Key", text: $editingSecretKey)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .onChange(of: editingSecretKey) { _, newValue in
                                    credentialsManager.updateSecretKey(newValue)
                                }
                        } else {
                            SecureField("Enter Secret Access Key", text: $editingSecretKey)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .onChange(of: editingSecretKey) { _, newValue in
                                    credentialsManager.updateSecretKey(newValue)
                                }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Session Token (Optional)")
                                .font(.headline)
                            
                            if showingCredentials {
                                TextField("Enter session token", text: $sessionToken)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            } else {
                                SecureField("Enter session token", text: $sessionToken)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }
                            
                            Text("Required only for temporary credentials or assume role scenarios.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Security Note")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                    
                    Text("Your AWS credentials are stored securely on your device. Never share these credentials or commit them to version control.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    private var modelConfigurationSection: some View {
        Section(header: Text("Model Configuration")) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("AWS Region", selection: $editingRegion) {
                    ForEach(Array(regions.keys.sorted()), id: \.self) { key in
                        Text("\(key) - \(regions[key] ?? "")")
                            .tag(key)
                    }
                }
                .onChange(of: editingRegion) { _, newValue in
                    credentialsManager.updateRegion(newValue)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Model")
                            .font(.headline)
                        
                        Spacer()
                        
                        Button(action: loadAvailableModels) {
                            HStack(spacing: 4) {
                                if isLoadingModels {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("Refresh")
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                        }
                        .disabled(isLoadingModels || !isConfigurationValid)
                    }
                    
                    Picker("Model", selection: $selectedModel) {
                        ForEach(availableModels, id: \.self) { model in
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                    .font(.body)
                                Text("\(model.provider) • \(model.contextWindow/1000)K context • \(model.costTier)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .tag(model.rawValue)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    
                    // Model details
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedModelEnum.displayName)
                            .font(.body)
                            .fontWeight(.medium)
                        
                        Text(selectedModelEnum.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Context Window")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("\(selectedModelEnum.contextWindow/1000)K tokens")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Max Output")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("\(selectedModelEnum.maxTokens) tokens")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Structured Output")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(selectedModelEnum.supportsStructuredOutput ? "Yes" : "No")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(selectedModelEnum.supportsStructuredOutput ? .green : .orange)
                            }
                            
                            Spacer()
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray6))
                    )
                }
            }
        }
    }
    
    private var advancedSettingsSection: some View {
        Section(header: Text("Advanced Settings")) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Temperature")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "%.1f", temperature))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $temperature, in: 0.0...1.0, step: 0.1)
                    
                    Text("Controls randomness in responses. Lower values (0.1) are more focused and deterministic, higher values (0.9) are more creative and varied.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Max Tokens")
                            .font(.headline)
                        Spacer()
                        Text("\(maxTokens)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(maxTokens) },
                        set: { maxTokens = Int($0) }
                    ), in: 512...Double(selectedModelEnum.maxTokens), step: 256)
                    
                    Text("Maximum number of tokens in the response. Higher values allow for longer responses but may increase costs.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private var connectionTestSection: some View {
        Section(header: Text("Test Connection")) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: testConnection) {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "network")
                        }
                        Text(isTesting ? "Testing..." : "Test AWS Bedrock Connection")
                    }
                }
                .disabled(isTesting || !isConfigurationValid)
                
                if let testResult = testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundColor(testResult.contains("✅") ? .green : .red)
                }
            }
        }
    }
    
    private var setupInstructionsSection: some View {
        Section(header: Text("Setup Instructions")) {
            VStack(alignment: .leading, spacing: 12) {
                InstructionRow(
                    number: "1",
                    title: "Create AWS Account",
                    description: "Sign up for AWS if you don't have an account"
                )
                
                InstructionRow(
                    number: "2",
                    title: "Enable Bedrock Access",
                    description: "Request access to foundation models in the AWS Bedrock console"
                )
                
                InstructionRow(
                    number: "3",
                    title: "Create IAM User",
                    description: "Create an IAM user with bedrock:InvokeModel permissions"
                )
                
                InstructionRow(
                    number: "4",
                    title: "Generate Access Keys",
                    description: "Create Access Key ID and Secret Access Key for the IAM user"
                )
                
                InstructionRow(
                    number: "5",
                    title: "Configure App",
                    description: "Enter your credentials, region, and model preferences above"
                )
            }
        }
    }
    
    private var documentationSection: some View {
        Section {
            Link("AWS Bedrock Documentation", destination: URL(string: "https://docs.aws.amazon.com/bedrock/")!)
            Link("Model Access Setup Guide", destination: URL(string: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html")!)
            Link("IAM Permissions Guide", destination: URL(string: "https://docs.aws.amazon.com/bedrock/latest/userguide/security_iam_service-with-iam.html")!)
        }
    }
    
    private var isConfigurationValid: Bool {
        if useProfile {
            return !profileName.isEmpty && !credentialsManager.credentials.region.isEmpty
        } else {
            return credentialsManager.credentials.isValid
        }
    }
    
    private func costTierColor(_ tier: String) -> Color {
        switch tier {
        case "Economy":
            return .green
        case "Standard":
            return .blue
        case "Premium":
            return .orange
        default:
            return .gray
        }
    }
    
    private func loadAvailableModels() {
        guard isConfigurationValid else { return }
        
        isLoadingModels = true
        
        Task {
            do {
                let config = createConfig()
                let service = AWSBedrockService(config: config)
                let models = try await service.listAvailableModels()
                
                await MainActor.run {
                    availableModels = models
                    isLoadingModels = false
                }
            } catch {
                await MainActor.run {
                    // Fall back to predefined models if API call fails
                    availableModels = AWSBedrockModel.allCases
                    isLoadingModels = false
                }
            }
        }
    }
    
    private func testConnection() {
        guard isConfigurationValid else { return }
        
        isTesting = true
        testResult = nil
        
        Task {
            let config = createConfig()
            let service = AWSBedrockService(config: config)
            
            let success = await service.testConnection()
            
            await MainActor.run {
                if success {
                    testResult = "✅ AWS Bedrock connection successful! Model \(selectedModelEnum.displayName) is ready to use."
                } else {
                    testResult = "❌ Connection test failed. Please check your configuration."
                }
                isTesting = false
            }
        }
    }
    
    private func createConfig() -> AWSBedrockConfig {
        return AWSBedrockConfig(
            region: credentialsManager.credentials.region,
            accessKeyId: credentialsManager.credentials.accessKeyId,
            secretAccessKey: credentialsManager.credentials.secretAccessKey,
            sessionToken: sessionToken.isEmpty ? nil : sessionToken,
            model: selectedModelEnum,
            temperature: temperature,
            maxTokens: maxTokens,
            timeout: 60.0,
            useProfile: useProfile,
            profileName: profileName.isEmpty ? nil : profileName
        )
    }
}

struct AWSBedrockSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        AWSBedrockSettingsView()
    }
}