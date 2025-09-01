//
//  AISettingsView.swift
//  Audio Journal
//
//  AI Summarization Engine configuration view
//

import SwiftUI
import Combine

/// A centralized location for UserDefaults keys to prevent typos and improve maintainability.
struct AppSettingsKeys {
    static let ollamaServerURL = "ollamaServerURL"
    static let ollamaPort = "ollamaPort"
    static let ollamaModelName = "ollamaModelName"
    static let enableOllama = "enableOllama"
    
    struct Defaults {
        static let ollamaServerURL = "http://localhost"
        static let ollamaPort = 11434
        static let ollamaModelName = "llama3.2"
    }
}

/// A dedicated view model to manage the state and logic for the AISettingsView.
/// This pattern resolves the "Ambiguous use of 'init'" compiler error by removing
/// the need for a custom initializer in the View struct.
@MainActor
final class AISettingsViewModel: ObservableObject {
    // The managers are now published properties of the ViewModel.
    @Published var appCoordinator: AppDataCoordinator
    @Published var regenerationManager: SummaryRegenerationManager

    private var cancellables = Set<AnyCancellable>()

    init(appCoordinator: AppDataCoordinator) {
        self.appCoordinator = appCoordinator
        self.regenerationManager = SummaryRegenerationManager(
            summaryManager: SummaryManager.shared,
            transcriptManager: TranscriptManager.shared,
            appCoordinator: appCoordinator
        )
        
        // We need to observe changes on the coordinator to republish them
        // so the view updates correctly.
        appCoordinator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        
        regenerationManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }
    
    func updateCoordinator(_ coordinator: AppDataCoordinator) {
        self.appCoordinator = coordinator
    }

    /// Moves the engine selection logic into the view model.
    func selectEngine(_ engineType: AIEngineType, recorderVM: AudioRecorderViewModel) -> (shouldPrompt: Bool, oldEngine: String, error: String?) {
        let oldEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence"
        let newEngine = engineType.rawValue

        guard oldEngine != newEngine else {
            return (shouldPrompt: false, oldEngine: "", error: nil)
        }
        
        // Allow selection of any engine - users need to be able to select engines to configure them
        // Note: Availability checks are used for display status only, not selection restrictions
        
        // Update the selected engine in UserDefaults
        UserDefaults.standard.set(newEngine, forKey: "SelectedAIEngine")
        
        // Update the regeneration manager
        self.regenerationManager.setEngine(newEngine)
        
        let shouldPrompt = self.regenerationManager.shouldPromptForRegeneration(oldEngine: oldEngine, newEngine: newEngine)
        return (shouldPrompt: shouldPrompt, oldEngine: oldEngine, error: nil)
    }
    
    private func checkEngineAvailability(_ engineType: AIEngineType) -> Bool {
        switch engineType {
        case .none:
            return true // "None" is always available
        case .enhancedAppleIntelligence:
            return true // Always available on iOS 15+
        case .openAI:
            let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
            return !apiKey.isEmpty
        case .openAICompatible:
            let apiKey = UserDefaults.standard.string(forKey: "openAICompatibleAPIKey") ?? ""
            return !apiKey.isEmpty
        case .localLLM:
            let isEnabled = UserDefaults.standard.bool(forKey: AppSettingsKeys.enableOllama)
            return isEnabled
        case .googleAIStudio:
            let apiKey = UserDefaults.standard.string(forKey: "googleAIStudioAPIKey") ?? ""
            let isEnabled = UserDefaults.standard.bool(forKey: "enableGoogleAIStudio")
            return !apiKey.isEmpty && isEnabled
        case .awsBedrock:
            let useProfile = UserDefaults.standard.bool(forKey: "awsBedrockUseProfile")
            let profileName = UserDefaults.standard.string(forKey: "awsBedrockProfileName") ?? ""
            let isEnabled = UserDefaults.standard.bool(forKey: "enableAWSBedrock")
            
            if useProfile {
                return !profileName.isEmpty && isEnabled
            } else {
                // Use unified credentials manager instead of separate UserDefaults keys
                let credentials = AWSCredentialsManager.shared.credentials
                return credentials.isValid && isEnabled
            }
        }
    }
}


struct AISettingsView: View {
    @StateObject private var viewModel: AISettingsViewModel
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @StateObject private var errorHandler = ErrorHandler()
    
    @Environment(\.dismiss) private var dismiss
    @State private var showingEngineChangePrompt = false
    @State private var previousEngine = ""
    @State private var showingOllamaSettings = false
    @State private var showingOpenAISettings = false
    @State private var showingOpenAICompatibleSettings = false
    @State private var showingGoogleAIStudioSettings = false
    @State private var showingAWSBedrockSettings = false
    @State private var showingAppleIntelligenceSettings = false
    @State private var engineStatuses: [String: EngineAvailabilityStatus] = [:]
    @State private var isRefreshingStatus = false
    
    init() {
        // Initialize with a placeholder coordinator - will be replaced by environment
        self._viewModel = StateObject(wrappedValue: AISettingsViewModel(appCoordinator: AppDataCoordinator()))
    }
    
    private var currentEngineType: AIEngineType? {
        // Note: AudioRecorderViewModel doesn't have selectedAIEngine property
        // Use the actual current engine from UserDefaults
        let currentEngineName = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence"
        return AIEngineType.allCases.first { $0.rawValue == currentEngineName }
    }
    
    private func refreshEngineStatuses() {
        Task {
            await MainActor.run {
                isRefreshingStatus = true
            }
            
            var statuses: [String: EngineAvailabilityStatus] = [:]
            let currentEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence"
            
            // Check each engine type
            for engineType in AIEngineType.allCases {
                let isCurrent = engineType.rawValue == currentEngine
                let isAvailable = checkEngineAvailability(engineType)
                
                let status = EngineAvailabilityStatus(
                    name: engineType.rawValue,
                    description: engineType.description,
                    isAvailable: isAvailable,
                    isComingSoon: engineType.isComingSoon,
                    requirements: engineType.requirements,
                    version: getEngineVersion(engineType),
                    isCurrentEngine: isCurrent
                )
                
                statuses[engineType.rawValue] = status
            }
            
            await MainActor.run {
                engineStatuses = statuses
                isRefreshingStatus = false
            }
        }
    }
    
    private func checkEngineAvailability(_ engineType: AIEngineType) -> Bool {
        switch engineType {
        case .none:
            return true // "None" is always available
        case .enhancedAppleIntelligence:
            return true // Always available on iOS 15+
        case .openAI:
            let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
            return !apiKey.isEmpty
        case .openAICompatible:
            let apiKey = UserDefaults.standard.string(forKey: "openAICompatibleAPIKey") ?? ""
            return !apiKey.isEmpty
        case .localLLM:
            let isEnabled = UserDefaults.standard.bool(forKey: AppSettingsKeys.enableOllama)
            return isEnabled
        case .googleAIStudio:
            let apiKey = UserDefaults.standard.string(forKey: "googleAIStudioAPIKey") ?? ""
            let isEnabled = UserDefaults.standard.bool(forKey: "enableGoogleAIStudio")
            return !apiKey.isEmpty && isEnabled
        case .awsBedrock:
            let useProfile = UserDefaults.standard.bool(forKey: "awsBedrockUseProfile")
            let profileName = UserDefaults.standard.string(forKey: "awsBedrockProfileName") ?? ""
            let isEnabled = UserDefaults.standard.bool(forKey: "enableAWSBedrock")
            
            if useProfile {
                return !profileName.isEmpty && isEnabled
            } else {
                // Use unified credentials manager instead of separate UserDefaults keys
                let credentials = AWSCredentialsManager.shared.credentials
                return credentials.isValid && isEnabled
            }
        }
    }
    
    private func getEngineVersion(_ engineType: AIEngineType) -> String {
        switch engineType {
        case .none:
            return "N/A"
        case .enhancedAppleIntelligence:
            return "iOS 15.0+"
        case .openAI:
            return "GPT-4"
        case .openAICompatible:
            return "API Compatible"
        case .localLLM:
            let modelName = UserDefaults.standard.string(forKey: AppSettingsKeys.ollamaModelName) ?? AppSettingsKeys.Defaults.ollamaModelName
            return modelName
        case .googleAIStudio:
            let model = UserDefaults.standard.string(forKey: "googleAIStudioModel") ?? "gemini-2.5-flash"
            return model
        case .awsBedrock:
            let modelName = UserDefaults.standard.string(forKey: "awsBedrockModel") ?? AWSBedrockModel.claude35Haiku.rawValue
            if let model = AWSBedrockModel(rawValue: modelName) {
                return model.displayName
            }
            return "Claude 3.5 Haiku"
        }
    }
    
    var body: some View {
        NavigationView {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 24) {
                    // Update the coordinator when the view appears
                    Color.clear
                        .onAppear {
                            viewModel.updateCoordinator(appCoordinator)
                        }
                    
                    headerSection
                    engineSelectionSection
                    selectedEngineConfigurationSection
                    summaryManagementSection
                    
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 16)
            }
            .navigationTitle("AI Settings")
            .navigationBarTitleDisplayMode(.inline)

        }
        .alert("Engine Change", isPresented: $showingEngineChangePrompt) {
            Button("Skip") { /* Do nothing, just dismiss */ }
            Button("Regenerate") {
                Task { await viewModel.regenerationManager.regenerateAllSummaries() }
            }
        } message: {
            Text("You've switched from \(previousEngine) to \(UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence"). Would you like to regenerate your existing summaries with the new AI engine?")
                .font(.headline)
                .padding()
            
            HStack {
                Button("Cancel") {
                    showingEngineChangePrompt = false
                }
                .buttonStyle(.bordered)
                
                Button("Regenerate") {
                    let defaultEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence"
                    // TODO: Implement setEngine with new Core Data system
                    viewModel.regenerationManager.setEngine(defaultEngine) // Use proper default instead of hardcoded "openai"
                    showingEngineChangePrompt = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .alert("Regeneration Complete", isPresented: $viewModel.regenerationManager.showingRegenerationAlert) {
            Button("OK") { viewModel.regenerationManager.regenerationResults = nil }
        } message: {
            Text(viewModel.regenerationManager.regenerationResults?.summary ?? "Regeneration process finished.")
        }
        .onAppear {
            // TODO: Implement setEngine with new Core Data system
            viewModel.regenerationManager.setEngine("OpenAI") // Use proper engine name
            self.refreshEngineStatuses()
        }
        .alert("Error", isPresented: $errorHandler.showingErrorAlert) {
            Button("OK") {
                errorHandler.clearCurrentError()
            }
        } message: {
            Text(errorHandler.currentError?.localizedDescription ?? "An unknown error occurred.")
        }
        .sheet(isPresented: $showingOllamaSettings) {
            OllamaSettingsView(onConfigurationChanged: {
                self.refreshEngineStatuses()
            })
        }
        .sheet(isPresented: $showingOpenAISettings) {
            OpenAISummarizationSettingsView(onConfigurationChanged: {
                Task { refreshEngineStatuses() }
            })
        }
        .sheet(isPresented: $showingOpenAICompatibleSettings) {
            OpenAICompatibleSettingsView(onConfigurationChanged: {
                Task { refreshEngineStatuses() }
            })
        }
        .sheet(isPresented: $showingGoogleAIStudioSettings) {
            GoogleAIStudioSettingsView(onConfigurationChanged: {
                Task { refreshEngineStatuses() }
            })
        }
        .sheet(isPresented: $showingAWSBedrockSettings) {
            AWSBedrockSettingsView()
        }
        .sheet(isPresented: $showingAppleIntelligenceSettings) {
            AppleIntelligenceSettingsView()
        }
    }
}


// MARK: - View Components
private extension AISettingsView {
    
    var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.blue)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Summarization Engine")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Choose the AI engine for generating summaries, extracting tasks, and identifying reminders from your recordings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
        }
    }
    
    
    var engineSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Engine Selection")
                .font(.headline)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Select AI Engine")
                    .font(.body)
                    .fontWeight(.medium)
                
                Picker("AI Engine", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence" },
                    set: { newValue in
                        if let engineType = AIEngineType.allCases.first(where: { $0.rawValue == newValue }) {
                            let result = self.viewModel.selectEngine(engineType, recorderVM: self.recorderVM)
                            if let error = result.error {
                                let systemError = SystemError.configurationError(message: error)
                                let appError = AppError.system(systemError)
                                self.errorHandler.handle(appError, context: "Engine Selection")
                            } else if result.shouldPrompt {
                                self.previousEngine = result.oldEngine
                                self.showingEngineChangePrompt = true
                            }
                            self.refreshEngineStatuses()
                        }
                    }
                )) {
                    ForEach(AIEngineType.allCases.filter { !$0.isComingSoon }, id: \.self) { engineType in
                        VStack(alignment: .leading) {
                            Text(engineType.rawValue)
                                .font(.body)
                            Text(engineType.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(engineType.rawValue)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                
                if let currentEngine = currentEngineType {
                    HStack {
                        Circle()
                            .fill(statusColor(for: currentEngine, status: engineStatuses[currentEngine.rawValue]))
                            .frame(width: 8, height: 8)
                        Text(statusText(for: currentEngine, status: engineStatuses[currentEngine.rawValue]))
                            .font(.caption)
                            .foregroundColor(statusColor(for: currentEngine, status: engineStatuses[currentEngine.rawValue]))
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
            )
            .padding(.horizontal, 24)
        }
    }
    
    var selectedEngineConfigurationSection: some View {
        let currentEngineName = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Enhanced Apple Intelligence"
        
        return Group {
            if let currentEngine = AIEngineType.allCases.first(where: { $0.rawValue == currentEngineName }) {
                switch currentEngine {
                case .none:
                    noneConfigurationSection
                case .enhancedAppleIntelligence:
                    appleIntelligenceConfigurationSection
                case .openAI:
                    openAIConfigurationSection
                case .openAICompatible:
                    openAICompatibleConfigurationSection
                case .localLLM:
                    ollamaConfigurationSection
                case .googleAIStudio:
                    googleAIStudioConfigurationSection
                case .awsBedrock:
                    awsBedrockConfigurationSection
                }
            }
        }
    }
    
    var noneConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("No AI Engine Selected")
                .font(.headline)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Summarization Disabled")
                            .font(.body)
                        Text("Select an AI engine above to enable summarization, task extraction, and reminder identification")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Status:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.gray)
                                .frame(width: 8, height: 8)
                            Text("Disabled")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    HStack {
                        Text("Features:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("None")
                            .font(.body)
                            .fontWeight(.medium)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))
            )
            .padding(.horizontal, 24)
        }
    }
    
    var appleIntelligenceConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apple Intelligence Configuration")
                .font(.headline)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Intelligence Settings")
                            .font(.body)
                        Text("Enhanced on-device processing using Apple's machine learning frameworks")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { showingAppleIntelligenceSettings = true }) {
                        HStack {
                            Image(systemName: "gear")
                            Text("Configure")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Status:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Available")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                    
                    HStack {
                        Text("Processing:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("On-Device")
                            .font(.body)
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("Privacy:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Fully Private")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
            )
            .padding(.horizontal, 24)
        }
    }
    
    var ollamaConfigurationSection: some View {
        // FIX: Logic moved outside the ViewBuilder closure.
        let serverURL = UserDefaults.standard.string(forKey: AppSettingsKeys.ollamaServerURL) ?? AppSettingsKeys.Defaults.ollamaServerURL
        let port = UserDefaults.standard.integer(forKey: AppSettingsKeys.ollamaPort)
        let effectivePort = port > 0 ? port : AppSettingsKeys.Defaults.ollamaPort
        let modelName = UserDefaults.standard.string(forKey: AppSettingsKeys.ollamaModelName) ?? AppSettingsKeys.Defaults.ollamaModelName
        let isEnabled = UserDefaults.standard.bool(forKey: AppSettingsKeys.enableOllama)
        
        // The return statement is now required because the property contains more than a single expression.
        return VStack(alignment: .leading, spacing: 16) {
            Text("Ollama Configuration")
                .font(.headline)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local LLM Settings")
                            .font(.body)
                        Text("Configure Ollama server connection and model selection")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { showingOllamaSettings = true }) {
                        HStack {
                            Image(systemName: "gear")
                            Text("Configure")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Server:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(serverURL):\(effectivePort)")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    HStack {
                        Text("Model:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(modelName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    HStack {
                        Text("Status:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(isEnabled ? "Enabled" : "Disabled")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(isEnabled ? .green : .red)
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(0.1))
            )
            .padding(.horizontal, 24)
        }
    }
    
    var openAIConfigurationSection: some View {
        // FIX: Logic moved outside the ViewBuilder closure.
        let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
        let modelString = UserDefaults.standard.string(forKey: "openAISummarizationModel") ?? OpenAISummarizationModel.gpt41Mini.rawValue
        let model = OpenAISummarizationModel(rawValue: modelString) ?? .gpt41Mini
        
        // The return statement is now required because the property contains more than a single expression.
        return VStack(alignment: .leading, spacing: 16) {
            Text("OpenAI Configuration")
                .font(.headline)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenAI API Settings")
                            .font(.body)
                        Text("Configure OpenAI API key and model selection for advanced summarization")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { self.showingOpenAISettings = true }) {
                        HStack {
                            Image(systemName: "gear")
                            Text("Configure")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("API Key:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(apiKey.isEmpty ? "Not configured" : "Configured (\(apiKey.count) chars)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(apiKey.isEmpty ? .red : .green)
                    }
                    HStack {
                        Text("Model:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(model.displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    HStack {
                        Text("Status:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(apiKey.isEmpty ? "Needs Configuration" : "Ready")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(apiKey.isEmpty ? .orange : .green)
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
            )
            .padding(.horizontal, 24)
        }
    }
    
    var googleAIStudioConfigurationSection: some View {
        // FIX: Logic moved outside the ViewBuilder closure.
        let apiKey = UserDefaults.standard.string(forKey: "googleAIStudioAPIKey") ?? ""
        let model = UserDefaults.standard.string(forKey: "googleAIStudioModel") ?? "gemini-2.5-flash"
        let isEnabled = UserDefaults.standard.bool(forKey: "enableGoogleAIStudio")
        
        // The return statement is now required because the property contains more than a single expression.
        return VStack(alignment: .leading, spacing: 16) {
            Text("Google AI Studio Configuration")
                .font(.headline)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Google AI Studio API Settings")
                            .font(.body)
                        Text("Configure Google AI Studio API key and model selection for advanced summarization")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { self.showingGoogleAIStudioSettings = true }) {
                        HStack {
                            Image(systemName: "gear")
                            Text("Configure")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Status:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(isEnabled && !apiKey.isEmpty ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(isEnabled && !apiKey.isEmpty ? "Configured" : "Not Configured")
                                .font(.caption)
                                .foregroundColor(isEnabled && !apiKey.isEmpty ? .green : .red)
                        }
                    }
                    
                    HStack {
                        Text("Model:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(model)
                            .font(.body)
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("API Key:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(apiKey.isEmpty ? "Not Set" : "Set")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(apiKey.isEmpty ? .red : .green)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.1))
            )
            .padding(.horizontal, 24)
        }
    }
    
    var awsBedrockConfigurationSection: some View {
        // FIX: Logic moved outside the ViewBuilder closure.
        let useProfile = UserDefaults.standard.bool(forKey: "awsBedrockUseProfile")
        let profileName = UserDefaults.standard.string(forKey: "awsBedrockProfileName") ?? ""
        let isEnabled = UserDefaults.standard.bool(forKey: "enableAWSBedrock")
        let modelName = UserDefaults.standard.string(forKey: "awsBedrockModel") ?? AWSBedrockModel.claude35Haiku.rawValue
        let model = AWSBedrockModel(rawValue: modelName) ?? .claude35Haiku
        let region = UserDefaults.standard.string(forKey: "awsBedrockRegion") ?? "us-east-1"
        
        // Use unified credentials manager for configuration validation
        let credentials = AWSCredentialsManager.shared.credentials
        
        // The return statement is now required because the property contains more than a single expression.
        return VStack(alignment: .leading, spacing: 16) {
            Text("AWS Bedrock Configuration")
                .font(.headline)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AWS Bedrock AI Settings")
                            .font(.body)
                        Text("Configure AWS Bedrock with Anthropic Claude, Amazon, and Meta models for advanced AI summarization")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { self.showingAWSBedrockSettings = true }) {
                        HStack {
                            Image(systemName: "gear")
                            Text("Configure")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Status:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            let isConfigured = isEnabled && (useProfile ? !profileName.isEmpty : credentials.isValid)
                            Circle()
                                .fill(isConfigured ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(isConfigured ? "Configured" : "Not Configured")
                                .font(.caption)
                                .foregroundColor(isConfigured ? .green : .red)
                        }
                    }
                    
                    HStack {
                        Text("Model:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(model.displayName)
                            .font(.body)
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("Region:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(region)
                            .font(.body)
                            .fontWeight(.medium)
                    }
                    
                    HStack {
                        Text("Authentication:")
                            .font(.body)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(useProfile ? "AWS Profile (\(profileName.isEmpty ? "Not Set" : profileName))" : "Access Keys")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(useProfile ? (profileName.isEmpty ? .red : .green) : (credentials.isValid ? .green : .red))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.1))
            )
            .padding(.horizontal, 24)
        }
    }
    
    var openAICompatibleConfigurationSection: some View {
        // FIX: Logic moved outside the ViewBuilder closure.
        let compatibleApiKey = UserDefaults.standard.string(forKey: "openAICompatibleAPIKey") ?? ""
        let compatibleModel = UserDefaults.standard.string(forKey: "openAICompatibleModel") ?? "gpt-3.5-turbo"
        
        // The return statement is now required because the property contains more than a single expression.
        return VStack(alignment: .leading, spacing: 16) {
            Text("OpenAI Compatible Configuration")
                .font(.headline)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenAI Compatible API Settings")
                            .font(.body)
                        Text("Configure OpenAI-compatible API providers (Azure, etc.)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { self.showingOpenAICompatibleSettings = true }) {
                        HStack {
                            Image(systemName: "gear")
                            Text("Configure")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("API Key:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(compatibleApiKey.isEmpty ? "Not configured" : "Configured (\(compatibleApiKey.count) chars)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(compatibleApiKey.isEmpty ? .red : .green)
                    }
                    HStack {
                        Text("Model:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(compatibleModel)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    HStack {
                        Text("Status:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(compatibleApiKey.isEmpty ? "Needs Configuration" : "Ready")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(compatibleApiKey.isEmpty ? .orange : .green)
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(0.1))
            )
            .padding(.horizontal, 24)
        }
    }
    
    var summaryManagementSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Summary Management")
                .font(.headline)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Regenerate All Summaries")
                            .font(.body)
                        Text("Update all existing summaries with the current AI engine")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        Task { await viewModel.regenerationManager.regenerateAllSummaries() }
                    }) {
                        HStack {
                            if viewModel.regenerationManager.isRegenerating {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(viewModel.regenerationManager.isRegenerating ? "Processing..." : "Regenerate All")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(viewModel.regenerationManager.canRegenerate ? Color.blue : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(!viewModel.regenerationManager.canRegenerate)
                }
                
                // Pass the regenerationManager from the viewModel to the progress view
                RegenerationProgressView(regenerationManager: viewModel.regenerationManager)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
            )
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Helper Functions
private extension AISettingsView {
    
    func statusColor(for engineType: AIEngineType, status: EngineAvailabilityStatus?) -> Color {
        if engineType.isComingSoon {
            return .orange
        }
        
        guard let status = status else {
            return .gray
        }
        
        if status.isCurrentEngine {
            return .green
        } else if status.isAvailable {
            return .blue
        } else {
            return .red
        }
    }
    
    func statusText(for engineType: AIEngineType, status: EngineAvailabilityStatus?) -> String {
        if engineType.isComingSoon {
            return "Coming Soon"
        }
        
        guard let status = status else {
            return "Unknown"
        }
        
        return status.statusMessage
    }
}

#Preview {
    AISettingsView()
        .environmentObject(AudioRecorderViewModel())
}
