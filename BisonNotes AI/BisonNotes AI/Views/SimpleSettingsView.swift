//
//  SimpleSettingsView.swift
//  Audio Journal
//
//  Simplified settings view for easy first-time configuration
//

import SwiftUI
import UIKit
#if !targetEnvironment(macCatalyst)
import SafariServices
#endif

enum ProcessingOption: String, CaseIterable {
    case openai = "OpenAI"
    case mistralAI = "Mistral AI"
    case onDeviceLLM = "On-Device AI"
    case chooseLater = "Choose Later"

    var displayName: String {
        switch self {
        case .openai:
            return "OpenAI (Cloud)"
        case .mistralAI:
            return "Mistral AI (Free)"
        case .onDeviceLLM:
            return "On-Device AI"
        case .chooseLater:
            return "Advanced & Other Options"
        }
    }

    var description: String {
        switch self {
        case .openai:
            return "Cloud-based transcription and AI summaries"
        case .mistralAI:
            return "Free cloud AI -- no credit card required"
        case .onDeviceLLM:
            return "Private, on-device AI processing"
        case .chooseLater:
            return "Configure additional providers later"
        }
    }

    var iconName: String {
        switch self {
        case .openai:
            return "sparkles"
        case .mistralAI:
            return "cloud.fill"
        case .onDeviceLLM:
            return "lock.shield.fill"
        case .chooseLater:
            return "slider.horizontal.3"
        }
    }

    var tintColor: Color {
        switch self {
        case .openai:
            return .purple
        case .mistralAI:
            return .orange
        case .onDeviceLLM:
            return .green
        case .chooseLater:
            return .blue
        }
    }
}

struct SimpleSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @State private var selectedOption: ProcessingOption = .chooseLater
    @State private var showingAdvancedSettings = false
    @State private var isSaving = false
    @State private var saveMessage = ""
    @State private var showingSaveResult = false
    @State private var saveSuccessful = false
    @State private var isFirstLaunch = false
    @State private var deviceSupported = false
    @State private var showingOnDeviceLLMSettings = false
    @State private var showingHelpDocumentation = false
    @State private var showingOnDeviceAIDownload = false
    @State private var showingMistralOnboarding = false

    var body: some View {
        AdaptiveNavigationWrapper {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    processingOptionSection
                    if selectedOption == .mistralAI {
                        mistralAIInfoSection
                    } else if selectedOption == .onDeviceLLM {
                        onDeviceAIInfoSection
                    } else if selectedOption == .chooseLater {
                        chooseLaterSection
                    }
                    saveSection

                    if !isFirstLaunch && DeviceCapabilities.supportsActionButton {
                        actionButtonSection
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 96)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemGroupedBackground))
            .accessibilityIdentifier(BisonNotesAccessibilityID.setupScroll)
            .navigationBarHidden(true)
        }
        .onAppear {
            loadCurrentSettings()
            // Check if device supports MLX on-device AI (requires 6GB+ RAM)
            deviceSupported = DeviceCapabilities.supportsMLX
            // Check if this is first launch
            isFirstLaunch = !UserDefaults.standard.bool(forKey: "hasCompletedFirstSetup")
        }
        .onChange(of: showingAdvancedSettings) { oldValue, newValue in
            // When advanced settings sheet is dismissed, reload settings to check if we need to switch options
            if oldValue == true && newValue == false {
                loadCurrentSettings()
            }
        }
        .onChange(of: showingOnDeviceAIDownload) { oldValue, newValue in
            // Once the user has acknowledged the download sheet (Start Download
            // or Cancel), advance into the app immediately on first launch.
            // Downloads keep running in the background; OnDeviceAIDownloadMonitor
            // surfaces the completion alert when both models finish.
            if oldValue == true && newValue == false,
               isFirstLaunch, selectedOption == .onDeviceLLM {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    NotificationCenter.default.post(name: NSNotification.Name("FirstSetupCompleted"), object: nil)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    NotificationCenter.default.post(name: NSNotification.Name("RequestLocationPermission"), object: nil)
                }
            }
        }
        .sheet(isPresented: $showingAdvancedSettings) {
            // SettingsView provides its own NavigationStack and Done toolbar.
            SettingsView()
                .environmentObject(recorderVM)
                .environmentObject(appCoordinator)
        }
        .sheet(isPresented: $showingOnDeviceLLMSettings) {
            NavigationStack {
                OnDeviceLLMSettingsView()
            }
        }
        .sheet(isPresented: $showingHelpDocumentation) {
            #if !targetEnvironment(macCatalyst)
            if let url = URL(string: "https://www.bisonnetworking.com/bisonnotes-ai/#simple-vs-advanced-settings") {
                SafariView(url: url)
            }
            #endif
        }
        .onChange(of: showingHelpDocumentation) { _, isShowing in
            #if targetEnvironment(macCatalyst)
            if isShowing, let url = URL(string: "https://www.bisonnetworking.com/bisonnotes-ai/#simple-vs-advanced-settings") {
                UIApplication.shared.open(url)
                showingHelpDocumentation = false
            }
            #endif
        }
        .sheet(isPresented: $showingOnDeviceAIDownload) {
            OnDeviceAIDownloadView(
                isPresented: $showingOnDeviceAIDownload,
                onCancel: {
                    // Cancel goes back to simple settings
                    showingOnDeviceAIDownload = false
                }
            )
        }
        .fullScreenCover(isPresented: $showingMistralOnboarding) {
            MistralOnboardingView(onSetupComplete: {
                // Mistral onboarding completed — mark first setup done and navigate
                UserDefaults.standard.set(true, forKey: "hasCompletedFirstSetup")
                if isFirstLaunch {
                    NotificationCenter.default.post(name: NSNotification.Name("FirstSetupCompleted"), object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        NotificationCenter.default.post(name: NSNotification.Name("RequestLocationPermission"), object: nil)
                    }
                }
            })
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.accentColor.gradient)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("BisonNotes AI")
                    .font(.largeTitle.weight(.bold))
                    .foregroundColor(.primary)

                Text("Choose how recordings become transcripts, summaries, tasks, and reminders.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: {
                showingAdvancedSettings = true
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Additional Settings")
            .accessibilityIdentifier(BisonNotesAccessibilityID.setupAdditionalSettingsButton)
        }
    }

    /// Options offered on this page: Mistral AI (free cloud), On-Device (if
    /// supported), and Advanced. OpenAI is available under Advanced & Other Options.
    private var availableProcessingOptions: [ProcessingOption] {
        ProcessingOption.allCases.filter { option in
            option == .mistralAI || option == .chooseLater || (option == .onDeviceLLM && deviceSupported)
        }
    }

    private var processingOptionSection: some View {
        SetupCard(spacing: 14) {
            sectionTitle("Processing Method", subtitle: "Pick the default path for new audio notes.")

            Menu {
                ForEach(availableProcessingOptions, id: \.self) { option in
                    Button {
                        selectedOption = option
                    } label: {
                        Label(
                            option.displayName,
                            systemImage: selectedOption == option ? "checkmark" : option.iconName
                        )
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedOption.iconName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(selectedOption.tintColor)
                        .frame(width: 38, height: 38)
                        .background(
                            selectedOption.tintColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 11)
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedOption.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)

                        Text(selectedOption.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(12)
                .background(
                    Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Processing Method: \(selectedOption.displayName)")
            .accessibilityValue(selectedOption.description)
            .accessibilityHint("Opens processing method choices.")
            .accessibilityIdentifier(BisonNotesAccessibilityID.setupProcessingMethod)

            if !deviceSupported {
                InlineNotice(
                    title: "Device Compatibility",
                    systemImage: "info.circle.fill",
                    tint: .blue
                ) {
                    Text("On-Device AI requires 6GB+ RAM. Your device has \(String(format: "%.1f", DeviceCapabilities.totalRAMInGB))GB RAM.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var onDeviceAIInfoSection: some View {
        SetupCard {
            SectionHeader(
                title: "On-Device AI Setup",
                subtitle: "Private processing for users who want recordings and summaries to stay local.",
                systemImage: "lock.shield.fill",
                tint: .green
            )

            DetailGroup(title: "Setup Process", tint: .blue) {
                VStack(alignment: .leading, spacing: 8) {
                    FeatureBullet(text: "Step 1: Download transcription model (150-520MB)")
                    FeatureBullet(text: "Step 2: Download AI summary model (2-3GB)")
                    FeatureBullet(text: "Total storage needed: ~3.5GB")
                }
            }

            DetailGroup(title: "Important Notes", tint: .orange) {
                VStack(alignment: .leading, spacing: 8) {
                    LimitationBullet(text: "Best for recordings under 60 minutes")
                    LimitationBullet(text: "May be less accurate than cloud services")
                }
            }
        }
    }

    private var mistralAIInfoSection: some View {
        SetupCard {
            SectionHeader(
                title: "Mistral AI Setup",
                subtitle: "Free cloud AI with transcription and summaries. No credit card required -- just create an account.",
                systemImage: "cloud.fill",
                tint: .orange,
                badge: "Free"
            )

            DetailGroup(title: "What You'll Get", tint: .orange) {
                VStack(alignment: .leading, spacing: 8) {
                    FeatureBullet(text: "Audio transcription with Voxtral Mini")
                    FeatureBullet(text: "AI summaries with Mistral Medium")
                    FeatureBullet(text: "Speaker diarization support")
                    FeatureBullet(text: "All models included on free tier")
                }
            }

            DetailGroup(title: "Setup Process", tint: .blue) {
                VStack(alignment: .leading, spacing: 8) {
                    FeatureBullet(text: "Step 1: Create free Mistral account (~1 min)")
                    FeatureBullet(text: "Step 2: Generate an API key (~30 sec)")
                    FeatureBullet(text: "Step 3: Paste key into app")
                }
            }
        }
    }

    private var chooseLaterSection: some View {
        SetupCard {
            SectionHeader(
                title: "Advanced & Other Options",
                subtitle: "Configure providers manually from app settings. Existing provider configuration is preserved.",
                systemImage: "slider.horizontal.3",
                tint: .blue
            )

            DetailGroup(title: "Available Options", tint: .blue) {
                VStack(alignment: .leading, spacing: 8) {
                    FeatureBullet(text: "OpenAI - GPT-4.1 Mini transcription and summaries")
                    FeatureBullet(text: "OpenAI Compatible - Use LiteLLM, vLLM, or similar proxies")
                    FeatureBullet(text: "Google AI Studio - Advanced Gemini AI processing")
                    FeatureBullet(text: "AWS Bedrock - Enterprise-grade Claude AI")
                    FeatureBullet(text: "Mistral AI - Free and paid cloud AI processing")
                }
            }

            Button(action: {
                showingHelpDocumentation = true
            }) {
                Label {
                    Text("Learn More About Processing Options")
                } icon: {
                    Image(systemName: "safari")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // OpenAI setup has been moved to Advanced & Other Options.
    // Existing OpenAI users keep their configuration; they see "Advanced" selected on this page.

    private var saveSection: some View {
        VStack(spacing: 16) {
            Button(action: saveConfiguration) {
                HStack {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark")
                    }
                    Text(isSaving ? "Saving..." : "Save & Configure")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(isSaving ? Color.gray : Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .foregroundColor(.white)
            }
            .disabled(isSaving)
            .accessibilityLabel(isSaving ? "Saving Configuration" : "Save and Configure")
            .accessibilityValue(selectedOption.displayName)
            .accessibilityIdentifier(BisonNotesAccessibilityID.setupSaveButton)

            // For Mistral, the save button launches the onboarding wizard instead
            .onChange(of: selectedOption) { _, _ in
                // Reset save result when switching options
                showingSaveResult = false
            }

            if showingSaveResult {
                HStack {
                    Image(systemName: saveSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(saveSuccessful ? .green : .red)
                        .accessibilityHidden(true)

                    Text(saveMessage)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background((saveSuccessful ? Color.green : Color.red).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

        }
    }

    private var actionButtonSection: some View {
        SetupCard {
            SectionHeader(
                title: "Action Button Setup",
                subtitle: "Start recording quickly from supported iPhone models.",
                systemImage: "button.programmable",
                tint: .purple
            )

            DetailGroup(title: "How to Configure", tint: .purple) {
                VStack(alignment: .leading, spacing: 8) {
                    FeatureBullet(text: "1. Open Settings app on your iPhone")
                    FeatureBullet(text: "2. Go to Action Button")
                    FeatureBullet(text: "3. Select \"Shortcut\"")
                    FeatureBullet(text: "4. Choose \"Start Recording\" from BisonNotes AI")
                    FeatureBullet(text: "5. Press Action Button to launch app and start recording!")
                }
            }

            Text("Works on iPhone models that include an Action Button.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func loadCurrentSettings() {
        // Determine which option should be selected based on current configuration
        let transcriptionEngine = UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? "Not Configured"
        let aiEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Not Configured"

        // Check if Mistral AI is selected
        if aiEngine == "Mistral AI" {
            selectedOption = .mistralAI
        }
        // MLX Swift is an on-device summary engine, so show the main on-device setup option.
        else if aiEngine == AIEngineType.mlxSwift.rawValue {
            selectedOption = .onDeviceLLM
        }
        // Check if On-Device AI is selected for AI and on-device transcription (FluidAudio/Parakeet)
        else if transcriptionEngine == TranscriptionEngine.fluidAudio.rawValue && aiEngine == AIEngineType.onDeviceLLM.rawValue {
            selectedOption = .onDeviceLLM
        }
        // Check if Apple Native (Foundation Models) is selected — also fully on-device
        else if transcriptionEngine == TranscriptionEngine.fluidAudio.rawValue && aiEngine == AIEngineType.appleNative.rawValue {
            selectedOption = .onDeviceLLM
        }
        // Any other permutation should show Advanced & Other Options
        else {
            selectedOption = .chooseLater
        }
    }

    private func saveConfiguration() {
        // For Mistral, launch the onboarding wizard only if no API key exists yet
        if selectedOption == .mistralAI {
            let existingKey = KeychainSecretStore.shared.string(forKey: KeychainSecretStore.mistralAPIKey) ?? ""
            if existingKey.isEmpty {
                showingMistralOnboarding = true
                return
            }
            // Key already exists — activate Mistral and continue normally
        }

        isSaving = true
        showingSaveResult = false

        Task {
            do {
                // Set default time format to 12-hour
                UserDefaults.standard.set(TimeFormat.twelveHour.rawValue, forKey: "user_preference_time_format")
                UserPreferences.shared.timeFormat = .twelveHour

                // Configure based on selected option
                if selectedOption == .chooseLater {
                    // For "Advanced & Other Options", preserve current settings instead of resetting
                    // Only set to "Not Configured" if this is truly a first-time setup
                    let currentTranscription = UserDefaults.standard.string(forKey: "selectedTranscriptionEngine")
                    let currentAI = UserDefaults.standard.string(forKey: "SelectedAIEngine")

                    // Only set to "Not Configured" if nothing is currently configured
                    if currentTranscription == nil || currentTranscription == "Not Configured" {
                        UserDefaults.standard.set("Not Configured", forKey: "selectedTranscriptionEngine")
                    }
                    if currentAI == nil || currentAI == "Not Configured" {
                        UserDefaults.standard.set("Not Configured", forKey: "SelectedAIEngine")
                    }
                    // Otherwise, keep the existing settings as-is

                    await MainActor.run {
                        saveMessage = "Setup completed! Opening advanced settings..."
                        saveSuccessful = true
                        showingSaveResult = true
                        isSaving = false
                    }

                    // Mark first setup as complete
                    UserDefaults.standard.set(true, forKey: "hasCompletedFirstSetup")

                    // Immediately open the advanced settings page
                    try await Task.sleep(nanoseconds: 500_000_000) // Brief delay to show message
                    await MainActor.run {
                        showingAdvancedSettings = true
                    }
                } else if selectedOption == .mistralAI {
                    // Mistral AI with existing key — activate as the selected engine
                    UserDefaults.standard.set(true, forKey: "enableMistralAI")
                    UserDefaults.standard.set("Mistral AI", forKey: "SelectedAIEngine")
                    UserDefaults.standard.set("Mistral AI", forKey: "selectedTranscriptionEngine")
                    UserDefaults.standard.set(true, forKey: "mistralTranscribeDiarize")

                } else {
                    // Set transcription engine to FluidAudio (On Device) for transcription
                    UserDefaults.standard.set(TranscriptionEngine.fluidAudio.rawValue, forKey: "selectedTranscriptionEngine")
                    UserDefaults.standard.set(true, forKey: FluidAudioModelInfo.SettingsKeys.enableFluidAudio)

                    // Honor any local AI engine the user has already chosen (MLX,
                    // legacy On-Device LLM, or Apple Intelligence) along with its
                    // selected model. Only fall back to MLX + 4B if none is set.
                    let currentAI = UserDefaults.standard.string(forKey: "SelectedAIEngine")
                    let localEngines: Set<String> = [
                        AIEngineType.onDeviceLLM.rawValue,
                        AIEngineType.mlxSwift.rawValue,
                        AIEngineType.appleNative.rawValue
                    ]

                    if let currentAI, localEngines.contains(currentAI) {
                        if currentAI == AIEngineType.mlxSwift.rawValue {
                            UserDefaults.standard.set(true, forKey: MLXSwiftSettingsKeys.enabled)
                        } else if currentAI == AIEngineType.onDeviceLLM.rawValue {
                            UserDefaults.standard.set(true, forKey: OnDeviceLLMModelInfo.SettingsKeys.enableOnDeviceLLM)
                        }
                    } else {
                        UserDefaults.standard.set(AIEngineType.mlxSwift.rawValue, forKey: "SelectedAIEngine")
                        UserDefaults.standard.set(true, forKey: MLXSwiftSettingsKeys.enabled)
                        UserDefaults.standard.set(MLXSwiftSettingsKeys.defaultModelId, forKey: MLXSwiftSettingsKeys.modelId)
                    }
                }

                await MainActor.run {
                    saveMessage = "Configuration saved successfully! Ready to start recording."
                    saveSuccessful = true
                    showingSaveResult = true
                    isSaving = false
                }

                // Mark first setup as complete
                UserDefaults.standard.set(true, forKey: "hasCompletedFirstSetup")

                // If On-Device AI was selected, show download confirmation dialog
                if selectedOption == .onDeviceLLM {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // Wait 1 second to show success message

                    // Check if models are already downloaded
                    let fluidAudioReady = FluidAudioManager.shared.isModelReady
                    MLXSwiftDownloadManager.shared.refreshModelStatus()
                    let onDeviceAIReady = MLXSwiftDownloadManager.shared.isModelDownloaded

                    await MainActor.run {
                        if fluidAudioReady && onDeviceAIReady {
                            // Both models already downloaded, skip download view
                            if isFirstLaunch {
                                // Post notification to complete first setup
                                NotificationCenter.default.post(name: NSNotification.Name("FirstSetupCompleted"), object: nil)
                                // Also request location permission after setup
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    NotificationCenter.default.post(name: NSNotification.Name("RequestLocationPermission"), object: nil)
                                }
                            }
                        } else {
                            // Show the download confirmation and progress view
                            showingOnDeviceAIDownload = true
                        }
                    }
                } else {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run {
                        if isFirstLaunch {
                            // For first launch, we need to trigger a complete app refresh
                            NotificationCenter.default.post(name: NSNotification.Name("FirstSetupCompleted"), object: nil)
                            // Also request location permission after setup
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                NotificationCenter.default.post(name: NSNotification.Name("RequestLocationPermission"), object: nil)
                            }
                        } else {
                            dismiss()
                        }
                    }
                }

            } catch {
                await MainActor.run {
                    saveMessage = "Configuration saved, but API key test failed: \(error.localizedDescription)"
                    saveSuccessful = false
                    showingSaveResult = true
                    isSaving = false
                }
            }
        }
    }
}

private struct SetupCard<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var badge: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .foregroundColor(tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DetailGroup<Content: View>: View {
    let title: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(tint)

            content
        }
        .padding(.top, 4)
    }
}

private struct InlineNotice<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundColor(tint)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(tint)

                content
            }
        }
        .padding(12)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct FeatureBullet: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.blue)
                .padding(.top, 2)
                .accessibilityHidden(true)

            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

struct LimitationBullet: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
                .padding(.top, 2)
                .accessibilityHidden(true)

            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SimpleSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SimpleSettingsView()
            .environmentObject(AudioRecorderViewModel())
            .environmentObject(AppDataCoordinator())
    }
}
