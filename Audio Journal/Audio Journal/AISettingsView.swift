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
        static let ollamaModelName = "llama2:7b"
    }
}

/// A dedicated view model to manage the state and logic for the AISettingsView.
/// This pattern resolves the "Ambiguous use of 'init'" compiler error by removing
/// the need for a custom initializer in the View struct.
@MainActor
final class AISettingsViewModel: ObservableObject {
    // The managers are now published properties of the ViewModel.
    @Published var summaryManager: SummaryManager
    @Published var regenerationManager: SummaryRegenerationManager

    private var cancellables = Set<AnyCancellable>()

    init() {
        let sharedSummaryManager = SummaryManager()
        self.summaryManager = sharedSummaryManager
        self.regenerationManager = SummaryRegenerationManager(
            summaryManager: sharedSummaryManager,
            transcriptManager: TranscriptManager.shared
        )
        
        // We need to observe changes on the managers to republish them
        // so the view updates correctly.
        summaryManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        
        regenerationManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    /// Moves the engine selection logic into the view model.
    func selectEngine(_ engineType: AIEngineType, recorderVM: AudioRecorderViewModel) -> (shouldPrompt: Bool, oldEngine: String, error: String?) {
        let oldEngine = recorderVM.selectedAIEngine
        let newEngine = engineType.rawValue

        guard oldEngine != newEngine else {
            return (shouldPrompt: false, oldEngine: "", error: nil)
        }
        
        // Validate engine availability before switching
        let validation = summaryManager.validateEngineAvailability(newEngine)
        guard validation.isValid else {
            return (shouldPrompt: false, oldEngine: "", error: validation.errorMessage)
        }
        
        // Allow selection even if not available - user can configure it
        // Only return error if the engine is completely invalid, not just unavailable

        recorderVM.selectedAIEngine = newEngine
        self.summaryManager.setEngine(newEngine)
        self.regenerationManager.setEngine(newEngine)
        
        let shouldPrompt = self.regenerationManager.shouldPromptForRegeneration(oldEngine: oldEngine, newEngine: newEngine)
        return (shouldPrompt: shouldPrompt, oldEngine: oldEngine, error: nil)
    }
}


struct AISettingsView: View {
    @StateObject private var viewModel = AISettingsViewModel()
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @StateObject private var errorHandler = ErrorHandler()
    
    @Environment(\.dismiss) private var dismiss
    @State private var showingEngineChangePrompt = false
    @State private var previousEngine = ""
    @State private var showingOllamaSettings = false
    @State private var showingOpenAISettings = false
    @State private var showingOpenAICompatibleSettings = false
    @State private var showingGoogleAIStudioSettings = false
    @State private var engineStatuses: [String: EngineAvailabilityStatus] = [:]
    @State private var isRefreshingStatus = false
    
    // No custom init is needed anymore, which solves the compiler error.
    
    private var currentEngineType: AIEngineType? {
        AIEngineType.allCases.first(where: { $0.rawValue == recorderVM.selectedAIEngine })
    }
    
    private func refreshEngineStatuses() {
        Task {
            await MainActor.run {
                isRefreshingStatus = true
            }
            
            // Get engine statuses from SummaryManager
            let statuses = viewModel.summaryManager.getEngineAvailabilityStatus()
            
            await MainActor.run {
                engineStatuses = statuses
                isRefreshingStatus = false
            }
        }
    }
    
    var body: some View {
        NavigationView {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    currentConfigurationSection
                    engineSelectionSection
                    
                    if recorderVM.selectedAIEngine == AIEngineType.localLLM.rawValue {
                        ollamaConfigurationSection
                    }
                    
                    if recorderVM.selectedAIEngine == AIEngineType.openAI.rawValue {
                        openAIConfigurationSection
                    }
                    
                    if recorderVM.selectedAIEngine == AIEngineType.openAICompatible.rawValue {
                        openAICompatibleConfigurationSection
                    }
                    
                    if recorderVM.selectedAIEngine == AIEngineType.googleAIStudio.rawValue {
                        googleAIStudioConfigurationSection
                    }
                    
                    if viewModel.summaryManager.enhancedSummaries.count > 0 {
                        summaryManagementSection
                    }
                    
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 16)
            }
            .navigationTitle("AI Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
        }
        .alert("Engine Change", isPresented: $showingEngineChangePrompt) {
            Button("Skip") { /* Do nothing, just dismiss */ }
            Button("Regenerate") {
                Task { await viewModel.regenerationManager.regenerateAllSummaries() }
            }
        } message: {
            Text("You've switched from \(previousEngine) to \(recorderVM.selectedAIEngine). Would you like to regenerate your \(viewModel.summaryManager.enhancedSummaries.count) existing summaries with the new AI engine?")
        }
        .alert("Regeneration Complete", isPresented: $viewModel.regenerationManager.showingRegenerationAlert) {
            Button("OK") { viewModel.regenerationManager.regenerationResults = nil }
        } message: {
            Text(viewModel.regenerationManager.regenerationResults?.summary ?? "Regeneration process finished.")
        }
        .onAppear {
            viewModel.summaryManager.setEngine(recorderVM.selectedAIEngine)
            viewModel.regenerationManager.setEngine(recorderVM.selectedAIEngine)
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
    
    var currentConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Configuration")
                .font(.headline)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "cpu")
                        .foregroundColor(.blue)
                        .font(.caption)
                    
                    Text("Engine:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(recorderVM.selectedAIEngine)
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    if currentEngineType?.isComingSoon == true {
                        Text("(Coming Soon)")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(3)
                    }
                }
                .padding(.horizontal, 24)
                
                if viewModel.summaryManager.enhancedSummaries.count > 0 {
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundColor(.blue)
                            .font(.caption)
                        
                        Text("Existing Summaries:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("\(viewModel.summaryManager.enhancedSummaries.count)")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
            )
            .padding(.horizontal, 24)
        }
    }
    
    var engineSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Available Engines")
                    .font(.headline)
                
                Spacer()
                
                Button(action: { self.refreshEngineStatuses() }) {
                    HStack(spacing: 4) {
                        if isRefreshingStatus {
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
                .disabled(isRefreshingStatus)
            }
            .padding(.horizontal, 24)
            
            ForEach(AIEngineType.allCases, id: \.self) { engineType in
                engineRow(for: engineType)
            }
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
        let apiKey = UserDefaults.standard.string(forKey: "openAISummarizationAPIKey") ?? ""
        let modelString = UserDefaults.standard.string(forKey: "openAISummarizationModel") ?? OpenAISummarizationModel.gpt35Turbo.rawValue
        let model = OpenAISummarizationModel(rawValue: modelString) ?? .gpt35Turbo
        
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
    @ViewBuilder
    func engineRow(for engineType: AIEngineType) -> some View {
        let engineStatus = self.engineStatuses[engineType.rawValue]
        let isCurrentEngine = self.recorderVM.selectedAIEngine == engineType.rawValue
        
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(engineType.rawValue)
                            .font(.body)
                        
                        // Status indicator
                        HStack(spacing: 2) {
                            Circle()
                                .fill(statusColor(for: engineType, status: engineStatus))
                                .frame(width: 8, height: 8)
                            
                            Text(statusText(for: engineType, status: engineStatus))
                                .font(.caption2)
                                .foregroundColor(statusColor(for: engineType, status: engineStatus))
                        }
                        
                        if engineType.isComingSoon {
                            Text("(Coming Soon)")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                    Text(engineType.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Requirements if not available
                    if let status = engineStatus, !status.isAvailable && !engineType.isComingSoon {
                        Text("Requirements: \(status.requirements.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    if isCurrentEngine {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                            .font(.title2)
                    }
                    
                    if let status = engineStatus {
                        Text(status.version)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
                .opacity(isCurrentEngine ? 0.3 : 0.1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrentEngine ? Color.blue : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !engineType.isComingSoon {
                withAnimation(.easeInOut(duration: 0.2)) {
                    let result = self.viewModel.selectEngine(engineType, recorderVM: self.recorderVM)
                    if let error = result.error {
                        // Show error from validation
                        let systemError = SystemError.configurationError(message: error)
                        let appError = AppError.system(systemError)
                        self.errorHandler.handle(appError, context: "Engine Selection")
                    } else if result.shouldPrompt {
                        self.previousEngine = result.oldEngine
                        self.showingEngineChangePrompt = true
                    }
                }
            }
        }
        .opacity(engineType.isComingSoon ? 0.6 : 1.0)
        .padding(.horizontal, 24)
    }
    
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
