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
                VStack(alignment: .leading, spacing: 32) {
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
                    
                    if !isFirstLaunch {
                        actionButtonSection
                    }
                    
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .navigationBarHidden(true)
        }
        .onAppear {
            loadCurrentSettings()
            // Check if device supports On-Device LLM (requires 6GB+ RAM)
            deviceSupported = DeviceCapabilities.supportsOnDeviceLLM
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
            // When download view is dismissed, check if both models are ready and complete setup
            if oldValue == true && newValue == false {
                Task { @MainActor in
                    let fluidAudioReady = FluidAudioManager.shared.isModelReady
                    OnDeviceLLMDownloadManager.shared.refreshModelStatus()
                    let onDeviceAIReady = OnDeviceLLMDownloadManager.shared.isModelReady

                    // If both models are ready and this is first launch, complete the setup
                    if fluidAudioReady && onDeviceAIReady && isFirstLaunch && selectedOption == .onDeviceLLM {
                        // Post notification to complete first setup and navigate to recording page
                        try? await Task.sleep(nanoseconds: 500_000_000) // Wait 0.5 seconds
                        NotificationCenter.default.post(name: NSNotification.Name("FirstSetupCompleted"), object: nil)
                        // Also request location permission after setup
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // Wait 1 second
                        NotificationCenter.default.post(name: NSNotification.Name("RequestLocationPermission"), object: nil)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAdvancedSettings) {
            NavigationView {
                SettingsView()
                    .environmentObject(recorderVM)
                    .environmentObject(appCoordinator)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showingAdvancedSettings = false
                            }
                        }
                    }
            }
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("BisonNotes AI Setup")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button("Additional Settings") {
                    showingAdvancedSettings = true
                }
                .font(.caption)
                .foregroundColor(.blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.1))
                )
            }
            .padding(.top, 20)
            
            Text("Choose your preferred transcription method and get started.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    private var processingOptionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Processing Method")
                .font(.headline)
                .foregroundColor(.primary)
            
            VStack(spacing: 12) {
                ForEach(ProcessingOption.allCases.filter { option in
                    // Show Mistral AI (free cloud), On-Device (if supported), and Advanced
                    // OpenAI is available under Advanced & Other Options
                    option == .mistralAI || option == .chooseLater || (option == .onDeviceLLM && deviceSupported)
                }, id: \.self) { option in
                    Button(action: {
                        selectedOption = option
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.displayName)
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                
                                Text(option.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: selectedOption == option ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedOption == option ? .blue : .gray)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedOption == option ? Color.blue.opacity(0.1) : Color(.systemGray6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedOption == option ? Color.blue : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            
            if !deviceSupported {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("Device Compatibility")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                    }
                    
                    Text("On-Device AI requires 6GB+ RAM. Your device has \(String(format: "%.1f", DeviceCapabilities.totalRAMInGB))GB RAM.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.05))
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: 1)
                )
        )
    }
    
    private var onDeviceAIInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("On-Device AI Setup")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("Private, on-device AI processing. No data leaves your device.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Setup Process:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading, spacing: 6) {
                    FeatureBullet(text: "Step 1: Download transcription model (150-520MB)")
                    FeatureBullet(text: "Step 2: Download AI summary model (2-3GB)")
                    FeatureBullet(text: "Total storage needed: ~3.5GB")
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.05))
            )
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Important Notes:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 6) {
                    LimitationBullet(text: "Best for recordings under 60 minutes")
                    LimitationBullet(text: "May be less accurate than cloud services")
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.05))
            )
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green, lineWidth: 1)
                )
        )
    }

    private var mistralAIInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Mistral AI Setup")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Text("Free")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange)
                        .clipShape(Capsule())
                }

                Text("Free cloud AI with transcription and summaries. No credit card required -- just create an account.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What you'll get:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 6) {
                    FeatureBullet(text: "Audio transcription with Voxtral Mini")
                    FeatureBullet(text: "AI summaries with Mistral Medium")
                    FeatureBullet(text: "Speaker diarization support")
                    FeatureBullet(text: "All models included on free tier")
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.05))
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Setup Process:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 6) {
                    FeatureBullet(text: "Step 1: Create free Mistral account (~1 min)")
                    FeatureBullet(text: "Step 2: Generate an API key (~30 sec)")
                    FeatureBullet(text: "Step 3: Paste key into app")
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.05))
            )
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange, lineWidth: 1)
                )
        )
    }

    private var chooseLaterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Advanced & Other Options")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("Configure processing providers manually from the app settings. If you already have an AI provider set up, your existing configuration is preserved.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Available Options:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 8) {
                    FeatureBullet(text: "OpenAI - GPT-4.1 Mini transcription and summaries")
                    FeatureBullet(text: "OpenAI Compatible - Use LiteLLM, vLLM, or similar proxies")
                    FeatureBullet(text: "Google AI Studio - Advanced Gemini AI processing")
                    FeatureBullet(text: "AWS Bedrock - Enterprise-grade Claude AI")
                    FeatureBullet(text: "Mistral AI - Free and paid cloud AI processing")
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.05))
            )

            Button(action: {
                showingHelpDocumentation = true
            }) {
                HStack {
                    Image(systemName: "safari")
                    Text("Learn More About Processing Options")
                        .fontWeight(.medium)
                }
                .foregroundColor(.blue)
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.blue, lineWidth: 1)
                        )
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: 1)
                )
        )
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
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSaving ? Color.gray : Color.blue)
                )
                .foregroundColor(.white)
            }
            .disabled(isSaving)

            // For Mistral, the save button launches the onboarding wizard instead
            .onChange(of: selectedOption) { _, newValue in
                // Reset save result when switching options
                showingSaveResult = false
            }
            
            if showingSaveResult {
                HStack {
                    Image(systemName: saveSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(saveSuccessful ? .green : .red)
                    
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundColor(saveSuccessful ? .green : .red)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill((saveSuccessful ? Color.green : Color.red).opacity(0.1))
                )
            }
            
        }
    }
    
    private var actionButtonSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("🎯 Action Button Setup")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("Set up your iPhone's Action Button to quickly start recording with BisonNotes AI.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text("How to Configure:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                VStack(alignment: .leading, spacing: 8) {
                    FeatureBullet(text: "1. Open Settings app on your iPhone")
                    FeatureBullet(text: "2. Go to Action Button")
                    FeatureBullet(text: "3. Select \"Shortcut\"")
                    FeatureBullet(text: "4. Choose \"Start Recording\" from BisonNotes AI")
                    FeatureBullet(text: "5. Press Action Button to launch app and start recording!")
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.05))
            )
            
            Text("✨ Works on iPhone models that include an Action Button.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: 1)
                )
        )
    }
    
    private func loadCurrentSettings() {
        // Determine which option should be selected based on current configuration
        let transcriptionEngine = UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? "Not Configured"
        let aiEngine = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "Not Configured"
        
        // Check if Mistral AI is selected
        if aiEngine == "Mistral AI" {
            selectedOption = .mistralAI
        }
        // Check if On-Device AI is selected for AI and on-device transcription (FluidAudio/Parakeet)
        else if transcriptionEngine == TranscriptionEngine.fluidAudio.rawValue && aiEngine == "On-Device AI" {
            selectedOption = .onDeviceLLM
        }
        // Check if Apple Native (Foundation Models) is selected — also fully on-device
        else if transcriptionEngine == TranscriptionEngine.fluidAudio.rawValue && aiEngine == "Apple Native" {
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
            let existingKey = UserDefaults.standard.string(forKey: "mistralAPIKey") ?? ""
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
                    
                    // Set AI engine to On-Device AI for summaries
                    UserDefaults.standard.set("On-Device AI", forKey: "SelectedAIEngine")
                    
                    // Enable On-Device LLM
                    UserDefaults.standard.set(true, forKey: OnDeviceLLMModelInfo.SettingsKeys.enableOnDeviceLLM)
                    
                    // Set On-Device LLM to use Granite Micro (recommended for 6GB+ devices)
                    // This prevents migration warnings when selectedModel is accessed
                    let deviceRAM = DeviceCapabilities.totalRAMInGB
                    if deviceRAM >= 6.0 {
                        UserDefaults.standard.set(OnDeviceLLMModelInfo.granite4Micro.id, forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId)
                    } else if deviceRAM >= 8.0 {
                        UserDefaults.standard.set(OnDeviceLLMModelInfo.granite4H.id, forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId)
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
                    OnDeviceLLMDownloadManager.shared.refreshModelStatus()
                    let onDeviceAIReady = OnDeviceLLMDownloadManager.shared.isModelReady

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

struct FeatureBullet: View {
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.blue)
                .padding(.top, 2)
            
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
