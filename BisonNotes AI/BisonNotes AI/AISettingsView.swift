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
    func selectEngine(_ engineType: AIEngineType, recorderVM: AudioRecorderViewModel) {
        let oldEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "On-Device AI"
        let newEngine = engineType.rawValue

        guard oldEngine != newEngine else { return }

        // Allow selection of any engine - users need to be able to select engines to configure them
        // Note: Availability checks are used for display status only, not selection restrictions

        // Update the selected engine in UserDefaults
        UserDefaults.standard.set(newEngine, forKey: "SelectedAIEngine")

        // Auto-enable engine-specific flags when an engine is selected
        switch engineType {
        case .openAICompatible:
            UserDefaults.standard.set(true, forKey: "enableOpenAICompatible")
            print("🔧 Auto-enabled OpenAI Compatible engine")
        case .localLLM:
            UserDefaults.standard.set(true, forKey: "enableOllama")
            print("🔧 Auto-enabled Ollama engine")
        case .googleAIStudio:
            UserDefaults.standard.set(true, forKey: "enableGoogleAIStudio")
            print("🔧 Auto-enabled Google AI Studio engine")
        case .awsBedrock:
            UserDefaults.standard.set(true, forKey: "enableAWSBedrock")
            print("🔧 Auto-enabled AWS Bedrock engine")
        case .mistralAI:
            UserDefaults.standard.set(true, forKey: "enableMistralAI")
            print("🔧 Auto-enabled Mistral AI engine")
        case .openAI:
            UserDefaults.standard.set(true, forKey: "enableOpenAI")
            print("🔧 Auto-enabled OpenAI engine")
        case .onDeviceLLM:
            UserDefaults.standard.set(true, forKey: OnDeviceLLMModelInfo.SettingsKeys.enableOnDeviceLLM)
            print("🔧 Auto-enabled On-Device AI engine")
        case .appleNative:
            print("🔧 Selected Apple Native engine")
        }

        // Update the regeneration manager
        self.regenerationManager.setEngine(newEngine)
    }
}


struct AISettingsView: View {
    @StateObject private var viewModel: AISettingsViewModel
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @StateObject private var errorHandler = ErrorHandler()
    @AppStorage(SummarizationTimeouts.storageKey) private var summarizationTimeout: Double = SummarizationTimeouts.defaultTimeout

    @Environment(\.dismiss) private var dismiss
    @State private var showingOllamaSettings = false
    @State private var showingOpenAISettings = false
    @State private var showingOpenAICompatibleSettings = false
    @State private var showingGoogleAIStudioSettings = false
    @State private var showingMistralAISettings = false
    @State private var showingAWSBedrockSettings = false
    @State private var showingOnDeviceLLMSettings = false
    @State private var engineStatuses: [String: EngineAvailabilityStatus] = [:]
    @State private var isRefreshingStatus = false
    @State private var showingRegenerateConfirmation = false
    @State private var showOnDeviceEngines = true
    @State private var showCloudEngines = true
    @State private var showSelfHostedEngines = true
    
    init() {
        // Initialize with a placeholder coordinator - will be replaced by environment
        self._viewModel = StateObject(wrappedValue: AISettingsViewModel(appCoordinator: AppDataCoordinator()))
    }
    
    private var currentEngineType: AIEngineType? {
        // Note: AudioRecorderViewModel doesn't have selectedAIEngine property
        // Use the actual current engine from UserDefaults
        let currentEngineName = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "On-Device AI"
        return AIEngineType.allCases.first { $0.rawValue == currentEngineName }
    }
    
    private func refreshEngineStatuses() {
        Task {
            await MainActor.run {
                isRefreshingStatus = true
            }
            
            var statuses: [String: EngineAvailabilityStatus] = [:]
            let currentEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "On-Device AI"
            
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
        case .openAI:
            let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
            return !apiKey.isEmpty
        case .openAICompatible:
            let apiKey = UserDefaults.standard.string(forKey: "openAICompatibleAPIKey") ?? ""
            return !apiKey.isEmpty
        case .mistralAI:
            let apiKey = UserDefaults.standard.string(forKey: "mistralAPIKey") ?? ""
            let isEnabled = UserDefaults.standard.bool(forKey: "enableMistralAI")
            return !apiKey.isEmpty && isEnabled
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
        case .onDeviceLLM:
            let isEnabled = UserDefaults.standard.bool(forKey: OnDeviceLLMModelInfo.SettingsKeys.enableOnDeviceLLM)
            let isModelReady = OnDeviceLLMDownloadManager.shared.isModelReady
            return isEnabled && isModelReady
        case .appleNative:
            return AppleNativeEngine.modelAvailable
        }
    }

    private func getEngineVersion(_ engineType: AIEngineType) -> String {
        switch engineType {
        case .openAI:
            let modelString = UserDefaults.standard.string(forKey: "openAISummarizationModel") ?? OpenAISummarizationModel.gpt41Mini.rawValue
            return OpenAISummarizationModel(rawValue: modelString)?.displayName ?? modelString
        case .openAICompatible:
            return "API Compatible"
        case .mistralAI:
            let modelName = UserDefaults.standard.string(forKey: "mistralModel") ?? MistralAIModel.mistralMedium2508.rawValue
            return MistralAIModel(rawValue: modelName)?.displayName ?? "Mistral"
        case .localLLM:
            let modelName = UserDefaults.standard.string(forKey: AppSettingsKeys.ollamaModelName) ?? AppSettingsKeys.Defaults.ollamaModelName
            return modelName
        case .googleAIStudio:
            let model = UserDefaults.standard.string(forKey: "googleAIStudioModel") ?? "gemini-3-flash-preview"
            return model
        case .awsBedrock:
            let storedModelName = UserDefaults.standard.string(forKey: "awsBedrockModel") ?? AWSBedrockModel.claude45Haiku.rawValue
            // Migrate legacy model identifiers
            let modelName = AWSBedrockModel.migrate(rawValue: storedModelName)
            if let model = AWSBedrockModel(rawValue: modelName) {
                return model.displayName
            }
            return "Claude 4.5 Haiku"
        case .onDeviceLLM:
            return OnDeviceLLMModelInfo.selectedModel.displayName
        case .appleNative:
            return "Foundation Models"
        }
    }
    
    var body: some View {
        NavigationView {
            Form {
                overviewSection
                engineSelectionSection
                selectedEngineConfigurationSection
                timeoutConfigurationSection
                summaryManagementSection
            }
            .navigationTitle("AI Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }

        }
        .alert("Regeneration Complete", isPresented: $viewModel.regenerationManager.showingRegenerationAlert) {
            Button("OK") { viewModel.regenerationManager.regenerationResults = nil }
        } message: {
            Text(viewModel.regenerationManager.regenerationResults?.summary ?? "Regeneration process finished.")
        }
        .alert("Regenerate All Summaries?", isPresented: $showingRegenerateConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Regenerate", role: .destructive) {
                Task { await viewModel.regenerationManager.regenerateAllSummaries() }
            }
        } message: {
            Text("This will regenerate all summaries using the current AI engine. Only summaries with existing transcripts will be processed. This may take some time depending on how many recordings you have.")
        }
        .onAppear {
            viewModel.updateCoordinator(appCoordinator)
            summarizationTimeout = SummarizationTimeouts.clamp(
                summarizationTimeout > 0 ? summarizationTimeout : SummarizationTimeouts.defaultTimeout
            )
            // Align regeneration manager with the user's currently selected engine instead of forcing OpenAI
            let currentEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ??
                AIEngineType.onDeviceLLM.rawValue
            viewModel.regenerationManager.setEngine(currentEngine)
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
        .sheet(isPresented: $showingMistralAISettings) {
            MistralAISettingsView(onConfigurationChanged: {
                Task { refreshEngineStatuses() }
            })
        }
        .sheet(isPresented: $showingAWSBedrockSettings) {
            AWSBedrockSettingsView()
        }
        .sheet(isPresented: $showingOnDeviceLLMSettings) {
            NavigationStack {
                OnDeviceLLMSettingsView()
            }
        }
    }
}


// MARK: - View Components
private extension AISettingsView {

    var selectedEngineName: String {
        UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? AIEngineType.onDeviceLLM.rawValue
    }

    var overviewSection: some View {
        Section("Current Engine") {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: currentEngineType ?? .onDeviceLLM))
                    .foregroundColor(engineColor(for: currentEngineType ?? .onDeviceLLM))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedEngineName)
                        .font(.body.weight(.semibold))
                    Text("Used for summaries, tasks, and reminders.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isRefreshingStatus {
                    ProgressView()
                        .controlSize(.small)
                } else if let engine = currentEngineType,
                          let status = engineStatuses[engine.rawValue] {
                    Label(status.isAvailable ? "Ready" : "Needs Setup",
                          systemImage: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(status.isAvailable ? .green : .orange)
                }
            }
            .padding(.vertical, 4)
        }
    }

    var timeoutConfigurationSection: some View {
        let effectiveTimeout = SummarizationTimeouts.clamp(
            summarizationTimeout > 0 ? summarizationTimeout : SummarizationTimeouts.defaultTimeout
        )
        let isUnlimitedEngine = currentEngineType == .onDeviceLLM || currentEngineType == .appleNative
        
        return Section("Request Timeout") {
            if isUnlimitedEngine {
                Label("No timeout — runs fully on-device.", systemImage: "infinity")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Slider(
                    value: Binding(
                        get: { effectiveTimeout },
                        set: { summarizationTimeout = SummarizationTimeouts.clamp($0) }
                    ),
                    in: SummarizationTimeouts.minimumTimeout...SummarizationTimeouts.maximumTimeout,
                    step: 10
                )

                HStack {
                    Text("\(Int(effectiveTimeout)) sec")
                    Spacer()
                    Text("\(String(format: "%.1f", effectiveTimeout / 60)) min")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            }
        }
    }

    var engineSelectionSection: some View {
        Section("Engine Library") {
            DisclosureGroup("On-Device", isExpanded: $showOnDeviceEngines) {
                ForEach(engines(in: .onDevice), id: \.self) { engine in
                    engineOptionRow(for: engine)
                }
            }

            DisclosureGroup("Cloud", isExpanded: $showCloudEngines) {
                ForEach(engines(in: .cloud), id: \.self) { engine in
                    engineOptionRow(for: engine)
                }
            }

            DisclosureGroup("Self-Hosted", isExpanded: $showSelfHostedEngines) {
                ForEach(engines(in: .selfHosted), id: \.self) { engine in
                    engineOptionRow(for: engine)
                }
            }
        }
    }

    var selectedEngineConfigurationSection: some View {
        Section("Selected Engine") {
            if let currentEngine = currentEngineType {
                let status = engineStatuses[currentEngine.rawValue]
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(currentEngine.rawValue, systemImage: iconName(for: currentEngine))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(engineColor(for: currentEngine))
                        Spacer()
                        if let status {
                            Text(status.isAvailable ? "Ready" : "Needs Setup")
                                .font(.caption)
                                .foregroundColor(status.isAvailable ? .green : .orange)
                        }
                    }

                    Text(currentEngine.description)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let version = status?.version, !version.isEmpty {
                        LabeledContent("Model", value: version)
                            .font(.caption)
                    }

                    if let requirement = currentEngine.requirements.first {
                        LabeledContent("Needs", value: requirement)
                            .font(.caption)
                    }

                    if currentEngine != .appleNative {
                        Button {
                            openSettings(for: currentEngine)
                        } label: {
                            Label("Configure \(currentEngine.rawValue)", systemImage: "gear")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(engineColor(for: currentEngine))
                    }
                }
            }
        }
    }

    var summaryManagementSection: some View {
        Section("Summary Management") {
            Button {
                showingRegenerateConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text(viewModel.regenerationManager.isRegenerating ? "Processing..." : "Regenerate All Summaries")
                }
            }
            .disabled(!viewModel.regenerationManager.canRegenerate)

            RegenerationProgressView(regenerationManager: viewModel.regenerationManager)
        }
    }
}

// MARK: - Helper Functions
private extension AISettingsView {

    enum EngineCategory {
        case onDevice
        case cloud
        case selfHosted
    }

    func engines(in category: EngineCategory) -> [AIEngineType] {
        AIEngineType.availableCases.filter { engine in
            switch category {
            case .onDevice:
                return [.onDeviceLLM, .appleNative].contains(engine)
            case .cloud:
                return [.openAI, .googleAIStudio, .mistralAI, .awsBedrock, .openAICompatible].contains(engine)
            case .selfHosted:
                return engine == .localLLM
            }
        }
    }

    func engineOptionRow(for engine: AIEngineType) -> some View {
        let status = engineStatuses[engine.rawValue]
        let isSelected = selectedEngineName == engine.rawValue

        return Button {
            viewModel.selectEngine(engine, recorderVM: recorderVM)
            refreshEngineStatuses()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? engineColor(for: engine) : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.rawValue)
                        .font(.subheadline)
                    Text(shortDescription(for: engine))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                engineBadge(for: engine, status: status)
            }
        }
        .buttonStyle(.plain)
    }

    func shortDescription(for engine: AIEngineType) -> String {
        switch engine {
        case .onDeviceLLM: return "Private, no internet after download"
        case .appleNative: return "Apple Foundation Models, fully on-device"
        case .openAI: return "High quality summaries"
        case .googleAIStudio: return "Gemini model support"
        case .mistralAI: return "Fast cloud summaries"
        case .awsBedrock: return "Enterprise model routing"
        case .openAICompatible: return "Works with compatible APIs"
        case .localLLM: return "Use your local Ollama server"
        }
    }

    func openSettings(for engine: AIEngineType) {
        switch engine {
        case .openAI:
            showingOpenAISettings = true
        case .openAICompatible:
            showingOpenAICompatibleSettings = true
        case .localLLM:
            showingOllamaSettings = true
        case .googleAIStudio:
            showingGoogleAIStudioSettings = true
        case .mistralAI:
            showingMistralAISettings = true
        case .awsBedrock:
            showingAWSBedrockSettings = true
        case .onDeviceLLM:
            guard DeviceCapabilities.supportsOnDeviceLLM else { return }
            showingOnDeviceLLMSettings = true
        case .appleNative:
            break // No separate settings sheet — configured via Apple Intelligence system settings
        }
    }

    func iconName(for engine: AIEngineType) -> String {
        switch engine {
        case .onDeviceLLM: return "iphone.gen3"
        case .appleNative:
            // apple.intelligence requires iOS 18.1+
            if #available(iOS 18.1, *) { return "apple.intelligence" }
            return "brain"
        case .openAI: return "sparkles"
        case .googleAIStudio: return "globe"
        case .mistralAI: return "wind"
        case .awsBedrock: return "shippingbox"
        case .openAICompatible: return "link"
        case .localLLM: return "server.rack"
        }
    }

    @ViewBuilder
    func engineBadge(for engine: AIEngineType, status: EngineAvailabilityStatus?) -> some View {
        if engine == .appleNative && !(status?.isAvailable ?? false) {
            Text("Not Supported")
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
        } else {
            Text((status?.isAvailable ?? false) ? "Ready" : "Setup")
                .font(.caption2.weight(.medium))
                .foregroundColor((status?.isAvailable ?? false) ? .green : .orange)
        }
    }

    func engineColor(for engine: AIEngineType) -> Color {
        switch engine {
        case .onDeviceLLM: return .indigo
        case .appleNative: return .mint
        case .openAI: return .blue
        case .googleAIStudio: return .purple
        case .mistralAI: return .orange
        case .awsBedrock: return .brown
        case .openAICompatible: return .green
        case .localLLM: return .teal
        }
    }
}

#Preview {
    AISettingsView()
        .environmentObject(AudioRecorderViewModel())
        .environmentObject(AppDataCoordinator())
}
