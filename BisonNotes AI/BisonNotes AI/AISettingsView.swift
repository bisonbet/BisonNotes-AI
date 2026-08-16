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

#if os(macOS)
    /// Seeds the native Mac Ollama connection with its local server defaults.
    /// Existing custom values are preserved so selecting Ollama never overwrites
    /// a server the user intentionally configured.
    static func applyOllamaMacDefaultsIfNeeded(to defaults: UserDefaults = .standard) {
        let savedServerURL = defaults.string(forKey: ollamaServerURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if savedServerURL?.isEmpty != false {
            defaults.set(Defaults.ollamaServerURL, forKey: ollamaServerURL)
        }

        if defaults.integer(forKey: ollamaPort) <= 0 {
            defaults.set(Defaults.ollamaPort, forKey: ollamaPort)
        }

        let savedModelName = defaults.string(forKey: ollamaModelName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if savedModelName?.isEmpty != false {
            defaults.set(Defaults.ollamaModelName, forKey: ollamaModelName)
        }
    }
#endif
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
        guard engineType.isSupportedOnCurrentPlatform else {
            AppLog.shared.general("Ignored unsupported AI engine selection: \(engineType.rawValue)")
            return
        }

#if os(macOS)
        if engineType == .localLLM {
            AppSettingsKeys.applyOllamaMacDefaultsIfNeeded()
        }
#endif

        let oldEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? AIEngineType.mlxSwift.rawValue
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
            AppLog.shared.general("Auto-enabled Compatible API engine")
        case .localLLM:
            UserDefaults.standard.set(true, forKey: "enableOllama")
            AppLog.shared.general("Auto-enabled Ollama engine")
        case .googleAIStudio:
            UserDefaults.standard.set(true, forKey: "enableGoogleAIStudio")
            AppLog.shared.general("Auto-enabled Google AI Studio engine")
        case .mistralAI:
            UserDefaults.standard.set(true, forKey: "enableMistralAI")
            AppLog.shared.general("Auto-enabled Mistral AI engine")
        case .onDeviceLLM:
            UserDefaults.standard.set(true, forKey: OnDeviceLLMModelInfo.SettingsKeys.enableOnDeviceLLM)
            AppLog.shared.general("Auto-enabled On-Device AI engine")
        case .mlxSwift:
            UserDefaults.standard.set(true, forKey: MLXSwiftSettingsKeys.enabled)
            AppLog.shared.general("Auto-enabled MLX Swift engine")
        case .appleNative:
            AppLog.shared.general("Selected Apple Native engine")
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
    @AppStorage(SummaryDetailLevel.storageKey)
    private var summaryDetailRawValue: Int = SummaryDetailLevel.defaultLevel.rawValue
    @AppStorage(SummaryThinkingLevel.storageKey)
    private var summaryThinkingRawValue: Int = SummaryThinkingLevel.defaultLevel.rawValue
    @AppStorage(OnDeviceLLMModelInfo.SettingsKeys.enableExperimentalModels) private var enableExperimentalModels = false

    @Environment(\.dismiss) private var dismiss
    @State private var showingOllamaSettings = false
    @State private var showingOpenAICompatibleSettings = false
    @State private var showingGoogleAIStudioSettings = false
    @State private var showingMistralAISettings = false
    @State private var showingOnDeviceLLMSettings = false
    @State private var showingMLXSwiftSettings = false
    @State private var showingMistralOnboarding = false
    @State private var engineStatuses: [String: EngineAvailabilityStatus] = [:]
    @State private var isRefreshingStatus = false
    @State private var showingRegenerateConfirmation = false
    @State private var showOnDeviceEngines = true
    @State private var showCloudEngines = true

    init() {
        // Initialize with a placeholder coordinator - will be replaced by environment
        self._viewModel = StateObject(wrappedValue: AISettingsViewModel(appCoordinator: AppDataCoordinator()))
    }

    private var currentEngineType: AIEngineType? {
        // Note: AudioRecorderViewModel doesn't have selectedAIEngine property
        // Use the actual current engine from UserDefaults
        let currentEngineName = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? AIEngineType.mlxSwift.rawValue
        return AIEngineType.allCases.first {
            $0.rawValue == currentEngineName && $0.isSupportedOnCurrentPlatform
        }
    }

    private var selectedSummaryDetailLevel: SummaryDetailLevel {
        SummaryDetailLevel(rawValue: summaryDetailRawValue) ?? SummaryDetailLevel.defaultLevel
    }

    private var selectedSummaryThinkingLevel: SummaryThinkingLevel {
        SummaryThinkingLevel(rawValue: summaryThinkingRawValue) ?? SummaryThinkingLevel.defaultLevel
    }

    private var currentSummaryThinkingProfile: SummaryThinkingProfile {
        SummaryThinkingModelCatalog.currentProfile()
    }

    private func refreshEngineStatuses() {
        Task {
            await MainActor.run {
                isRefreshingStatus = true
            }

            var statuses: [String: EngineAvailabilityStatus] = [:]
            let currentEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? AIEngineType.mlxSwift.rawValue

            // Check each engine type
            for engineType in AIEngineType.allCases where engineType.isSupportedOnCurrentPlatform {
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
        case .openAICompatible:
            let apiKey = KeychainSecretStore.shared.string(forKey: KeychainSecretStore.openAICompatibleAPIKey) ?? ""
            return !apiKey.isEmpty
        case .mistralAI:
            let apiKey = KeychainSecretStore.shared.string(forKey: KeychainSecretStore.mistralAPIKey) ?? ""
            let isEnabled = UserDefaults.standard.bool(forKey: "enableMistralAI")
            return !apiKey.isEmpty && isEnabled
        case .localLLM:
            let isEnabled = UserDefaults.standard.bool(forKey: AppSettingsKeys.enableOllama)
            return isEnabled
        case .googleAIStudio:
            let apiKey = KeychainSecretStore.shared.string(forKey: KeychainSecretStore.googleAIStudioAPIKey) ?? ""
            let isEnabled = UserDefaults.standard.bool(forKey: "enableGoogleAIStudio")
            return !apiKey.isEmpty && isEnabled
        case .onDeviceLLM:
            let isEnabled = UserDefaults.standard.bool(forKey: OnDeviceLLMModelInfo.SettingsKeys.enableOnDeviceLLM)
            let isModelReady = OnDeviceLLMDownloadManager.shared.isModelReady
            return isEnabled && isModelReady
        case .mlxSwift:
            let isEnabled = UserDefaults.standard.bool(forKey: MLXSwiftSettingsKeys.enabled)
            #if targetEnvironment(simulator)
            return isEnabled
            #else
            return isEnabled && DeviceCapabilities.supportsMLX
            #endif
        case .appleNative:
            return AppleNativeEngine.modelAvailable
        }
    }

    private func getEngineVersion(_ engineType: AIEngineType) -> String {
        switch engineType {
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
        case .onDeviceLLM:
            return OnDeviceLLMModelInfo.selectedModel.displayName
        case .mlxSwift:
            let model = UserDefaults.standard.string(forKey: MLXSwiftSettingsKeys.modelId) ?? MLXSwiftSettingsKeys.defaultModelId
            return model.components(separatedBy: "/").last ?? model
        case .appleNative:
            return "Foundation Models"
        }
    }

    var body: some View {
        Group {
            settingsContent
                .navigationTitle("AI Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    #if !os(macOS)
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                    #endif
                }
        }
        .platformSettingsNavigation()
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
            // Align regeneration manager with the user's currently selected engine.
            let currentEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ??
                AIEngineType.mlxSwift.rawValue
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
        #if os(macOS)
        .navigationDestination(isPresented: $showingOllamaSettings) {
            OllamaSettingsView(onConfigurationChanged: {
                self.refreshEngineStatuses()
            })
        }
        .navigationDestination(isPresented: $showingOpenAICompatibleSettings) {
            OpenAICompatibleSettingsView(onConfigurationChanged: {
                Task { refreshEngineStatuses() }
            })
        }
        .navigationDestination(isPresented: $showingGoogleAIStudioSettings) {
            GoogleAIStudioSettingsView(onConfigurationChanged: {
                Task { refreshEngineStatuses() }
            })
        }
        .navigationDestination(isPresented: $showingMistralAISettings) {
            MistralAISettingsView(onConfigurationChanged: {
                Task { refreshEngineStatuses() }
            })
        }
        .navigationDestination(isPresented: $showingOnDeviceLLMSettings) {
            OnDeviceLLMSettingsView()
        }
        .navigationDestination(isPresented: $showingMLXSwiftSettings) {
            MLXSwiftSettingsView()
        }
        #else
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
        .sheet(isPresented: $showingOnDeviceLLMSettings) {
            NavigationStack {
                OnDeviceLLMSettingsView()
            }
        }
        .sheet(isPresented: $showingMLXSwiftSettings) {
            NavigationStack {
                MLXSwiftSettingsView()
            }
        }
        #endif
        .platformFullScreenCover(isPresented: $showingMistralOnboarding) {
            MistralOnboardingView(onSetupComplete: {
                refreshEngineStatuses()
            })
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        modernSettingsContent
    }

    private var modernSettingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                modernHeader
                modernCurrentEngineSection
                modernEngineLibrarySection
                modernTimeoutSection
                modernSummaryDetailSection
                modernSummaryThinkingSection
                modernSummaryManagementSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 36)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
    }

    private var modernHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI Settings")
                .font(.largeTitle.weight(.bold))
                .foregroundColor(.primary)

            Text("Choose the engine that turns transcripts into summaries, tasks, and reminders.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var modernCurrentEngineSection: some View {
        AISettingsCard(title: "Current Engine", systemImage: currentEngineType.map { iconName(for: $0) } ?? "sparkles", tint: currentEngineType.map { engineColor(for: $0) } ?? .accentColor) {
            if let currentEngine = currentEngineType {
                let status = engineStatuses[currentEngine.rawValue]

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentEngine.displayName)
                                .font(.headline)
                                .foregroundColor(.primary)

                            Text(currentEngine.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        AIStatusPill(
                            text: (status?.isAvailable ?? false) ? "Ready" : "Needs Setup",
                            tint: (status?.isAvailable ?? false) ? .green : .orange
                        )
                    }

                    if let version = status?.version, !version.isEmpty {
                        AIInfoRow(title: "Model", value: version)
                    }

                    if let requirement = currentEngine.requirements.first {
                        AIInfoRow(title: "Needs", value: requirement)
                    }

                    if currentEngine != .appleNative {
                        Button {
                            openSettings(for: currentEngine)
                        } label: {
                            Label("Configure \(currentEngine.displayName)", systemImage: "gear")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(engineColor(for: currentEngine))
                    }
                }
            }
        }
    }

    private var modernEngineLibrarySection: some View {
        AISettingsCard(title: "Engine Library", systemImage: "square.grid.2x2", tint: .blue) {
            VStack(alignment: .leading, spacing: 12) {
                modernEngineGroupHeader("On-Device", systemImage: "iphone")
                ForEach(engines(in: .onDevice), id: \.self) { engine in
                    modernEngineOptionRow(for: engine)
                }

                Divider()

                modernEngineGroupHeader("Cloud / Self-Hosted", systemImage: "cloud")
                ForEach(engines(in: .cloud) + engines(in: .selfHosted), id: \.self) { engine in
                    modernEngineOptionRow(for: engine)
                }
            }
        }
    }

    private var modernTimeoutSection: some View {
        let effectiveTimeout = SummarizationTimeouts.clamp(
            summarizationTimeout > 0 ? summarizationTimeout : SummarizationTimeouts.defaultTimeout
        )
        let isUnlimitedEngine = currentEngineType == .onDeviceLLM || currentEngineType == .appleNative

        return AISettingsCard(title: "Request Timeout", systemImage: "timer", tint: .orange) {
            if isUnlimitedEngine {
                Label("No timeout - runs fully on-device.", systemImage: "infinity")
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

    private var modernSummaryDetailSection: some View {
        let selectedLevel = selectedSummaryDetailLevel

        return AISettingsCard(title: "Summary Detail", systemImage: "text.alignleft", tint: .indigo) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose how much description, context, and supporting data AI summaries should include.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Slider(
                    value: Binding(
                        get: { Double(selectedLevel.rawValue) },
                        set: { newValue in
                            summaryDetailRawValue = SummaryDetailLevel(
                                rawValue: Int(newValue.rounded())
                            )?.rawValue ?? SummaryDetailLevel.defaultLevel.rawValue
                        }
                    ),
                    in: 0...2,
                    step: 1
                )
                .accessibilityLabel("Summary detail")
                .accessibilityValue(selectedLevel.displayName)
                .accessibilityHint(
                    "Brief keeps key points only. Balanced includes useful context. "
                        + "Detailed includes more supporting information."
                )

                HStack {
                    ForEach(SummaryDetailLevel.allCases) { level in
                        Text(level.displayName)
                            .font(.caption.weight(level == selectedLevel ? .semibold : .regular))
                            .foregroundColor(level == selectedLevel ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedLevel.displayName)
                        .font(.headline)
                    Text(selectedLevel.userDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(
                    "This affects the narrative summary for every AI engine. Tasks, reminders, titles, "
                        + "and content type remain grounded in transcript facts."
                )
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var modernSummaryThinkingSection: some View {
        let selectedLevel = selectedSummaryThinkingLevel
        let profile = currentSummaryThinkingProfile
        let modelName = profile.modelName.isEmpty ? "the selected model" : profile.modelName

        return AISettingsCard(title: "Summary Thinking", systemImage: "brain", tint: .teal) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Use a short reasoning pass for models that expose a safe thinking control.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Slider(
                    value: Binding(
                        get: { Double(selectedLevel.rawValue) },
                        set: { newValue in
                            summaryThinkingRawValue = SummaryThinkingLevel(
                                rawValue: Int(newValue.rounded())
                            )?.rawValue ?? SummaryThinkingLevel.defaultLevel.rawValue
                        }
                    ),
                    in: 0...1,
                    step: 1
                )
                .accessibilityLabel("Summary thinking")
                .accessibilityValue(selectedLevel.displayName)
                .accessibilityHint("Off sends no thinking override. Light requests a short reasoning pass when supported.")

                HStack {
                    ForEach(SummaryThinkingLevel.allCases) { level in
                        Text(level.displayName)
                            .font(.caption.weight(level == selectedLevel ? .semibold : .regular))
                            .foregroundColor(level == selectedLevel ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedLevel.displayName)
                        .font(.headline)
                    Text(selectedLevel.userDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                thinkingCapabilityMessage(for: profile.support, modelName: modelName)
            }
        }
    }

    @ViewBuilder
    private func thinkingCapabilityMessage(
        for support: SummaryThinkingSupport,
        modelName: String
    ) -> some View {
        switch support {
        case .unsupported:
            Label(
                "Ignored for \(modelName); no supported thinking control was found.",
                systemImage: "info.circle"
            )
        case .thinkingOnly:
            Label(
                "\(modelName) controls thinking itself. BisonNotes will not add a heavier or unsupported override.",
                systemImage: "checkmark.circle"
            )
        case .controllable:
            Label(
                "Light is available for \(modelName). Thinking traces are not included in the summary.",
                systemImage: "checkmark.circle"
            )
        }
    }

    private var modernSummaryManagementSection: some View {
        AISettingsCard(title: "Summary Management", systemImage: "arrow.clockwise", tint: .purple) {
            Button {
                showingRegenerateConfirmation = true
            } label: {
                Label(viewModel.regenerationManager.isRegenerating ? "Processing..." : "Regenerate All Summaries", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.regenerationManager.canRegenerate)

            RegenerationProgressView(regenerationManager: viewModel.regenerationManager)
        }
    }
}

// MARK: - View Components
private extension AISettingsView {

    var selectedEngineName: String {
        UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? AIEngineType.mlxSwift.rawValue
    }

    func modernEngineGroupHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.secondary)
    }

    func modernEngineOptionRow(for engine: AIEngineType) -> some View {
        let status = engineStatuses[engine.rawValue]
        let isSelected = selectedEngineName == engine.rawValue
        let tint = engineColor(for: engine)

        return Button {
            viewModel.selectEngine(engine, recorderVM: recorderVM)
            refreshEngineStatuses()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: iconName(for: engine))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)

                    Text(shortDescription(for: engine))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                engineBadge(for: engine, status: status)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? tint : .secondary)
            }
            .padding(14)
            .background(isSelected ? tint.opacity(0.12) : Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
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

            DisclosureGroup("Cloud / Self-Hosted", isExpanded: $showCloudEngines) {
                ForEach(engines(in: .cloud) + engines(in: .selfHosted), id: \.self) { engine in
                    engineOptionRow(for: engine)
                }
            }
        }
    }

    var selectedEngineConfigurationSection: some View {
        Section("Current Engine") {
            if let currentEngine = currentEngineType {
                let status = engineStatuses[currentEngine.rawValue]
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(currentEngine.displayName, systemImage: iconName(for: currentEngine))
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
                            Label("Configure \(currentEngine.displayName)", systemImage: "gear")
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
                return [.onDeviceLLM, .mlxSwift, .appleNative].contains(engine)
            case .cloud:
                return [.googleAIStudio, .mistralAI, .openAICompatible].contains(engine)
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
                    Text(engine.displayName)
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
        case .mlxSwift: return "On-device MLX summaries"
        case .appleNative: return "Apple Foundation Models, fully on-device"
        case .googleAIStudio: return "Gemini model support"
        case .mistralAI: return "Fast cloud summaries"
        case .openAICompatible: return "Works with compatible APIs"
        case .localLLM: return "Use your local Ollama server"
        }
    }

    func openSettings(for engine: AIEngineType) {
        switch engine {
        case .openAICompatible:
            showingOpenAICompatibleSettings = true
        case .localLLM:
#if os(macOS)
            showingOllamaSettings = true
#else
            break
#endif
        case .googleAIStudio:
            showingGoogleAIStudioSettings = true
        case .mistralAI:
            let mistralKey = KeychainSecretStore.shared.string(forKey: KeychainSecretStore.mistralAPIKey) ?? ""
            if mistralKey.isEmpty {
                showingMistralOnboarding = true
            } else {
                showingMistralAISettings = true
            }
        case .onDeviceLLM:
            guard DeviceCapabilities.supportsOnDeviceLLM else { return }
            showingOnDeviceLLMSettings = true
        case .mlxSwift:
            guard DeviceCapabilities.supportsMLX else { return }
            showingMLXSwiftSettings = true
        case .appleNative:
            break // No separate settings sheet — configured via Apple Intelligence system settings
        }
    }

    func iconName(for engine: AIEngineType) -> String {
        switch engine {
        case .onDeviceLLM: return "iphone.gen3"
        case .mlxSwift: return "cpu"
        case .appleNative:
            // apple.intelligence requires iOS 18.1+
            if #available(iOS 18.1, *) { return "apple.intelligence" }
            return "brain"
        case .googleAIStudio: return "globe"
        case .mistralAI: return "wind"
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
        } else if engine == .mistralAI && !(status?.isAvailable ?? false) {
            HStack(spacing: 4) {
                Text("Free")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .clipShape(Capsule())
                Text("Setup")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.orange)
            }
        } else {
            Text((status?.isAvailable ?? false) ? "Ready" : "Setup")
                .font(.caption2.weight(.medium))
                .foregroundColor((status?.isAvailable ?? false) ? .green : .orange)
        }
    }

    func engineColor(for engine: AIEngineType) -> Color {
        switch engine {
        case .onDeviceLLM: return .indigo
        case .mlxSwift: return .orange
        case .appleNative: return .mint
        case .googleAIStudio: return .purple
        case .mistralAI: return .orange
        case .openAICompatible: return .green
        case .localLLM: return .teal
        }
    }
}

private struct AISettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    init(title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct AIStatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
    }
}

private struct AIInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    AISettingsView()
        .environmentObject(AudioRecorderViewModel())
        .environmentObject(AppDataCoordinator())
}
