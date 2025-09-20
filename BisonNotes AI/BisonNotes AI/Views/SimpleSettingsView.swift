//
//  SimpleSettingsView.swift
//  Audio Journal
//
//  Simplified OpenAI-only settings view for easy configuration
//

import SwiftUI
import UIKit

enum ProcessingOption: String, CaseIterable {
    case openai = "OpenAI"
    case appleIntelligence = "Apple Intelligence"
    case chooseLater = "Choose Later"

    var displayName: String {
        switch self {
        case .openai:
            return "OpenAI (Cloud)"
        case .appleIntelligence:
            return "Apple Intelligence (On-Device)"
        case .chooseLater:
            return "Choose Later"
        }
    }

    var description: String {
        switch self {
        case .openai:
            return "Cloud-based transcription and AI summaries"
        case .appleIntelligence:
            return "Private, on-device processing (limited)"
        case .chooseLater:
            return "Set up processing options later"
        }
    }
}

struct SimpleSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @EnvironmentObject var appCoordinator: AppDataCoordinator
    @State private var selectedOption: ProcessingOption = .chooseLater
    @State private var apiKey: String = ""
    @State private var showingAdvancedSettings = false
    @State private var isSaving = false
    @State private var saveMessage = ""
    @State private var showingSaveResult = false
    @State private var saveSuccessful = false
    @State private var isFirstLaunch = false
    @State private var deviceSupported = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    headerSection
                    processingOptionSection
                    if selectedOption == .openai {
                        apiKeySection
                    } else if selectedOption == .appleIntelligence {
                        appleIntelligenceInfoSection
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
            }
            .navigationBarHidden(true)
        }
        .onAppear {
            loadCurrentSettings()
            deviceSupported = DeviceCompatibility.isAppleIntelligenceSupported
            // Check if this is first launch
            isFirstLaunch = !UserDefaults.standard.bool(forKey: "hasCompletedFirstSetup")
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
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("BisonNotes AI Setup")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button("Advanced Options") {
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
                    // Only show Apple Intelligence if device is supported, always show OpenAI and Choose Later
                    option == .openai || option == .chooseLater || (option == .appleIntelligence && deviceSupported)
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
                    
                    Text("Apple Intelligence requires iPhone 16 series or newer, or newer iPads with M1+ or A17 Pro chips.")
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
                        .stroke(Color(.systemGray4), lineWidth: 0.5)
                )
        )
    }
    
    private var appleIntelligenceInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Apple Intelligence Setup")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("Private, on-device processing using Apple Intelligence. No data leaves your device.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Important Limitations:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 6) {
                    LimitationBullet(text: "Best for recordings under 5 minutes")
                    LimitationBullet(text: "Processing limited to 1-minute chunks")
                    LimitationBullet(text: "Requires Speech Recognition permission")
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

    private var chooseLaterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose Later")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("Skip initial setup and configure processing options later from the app settings.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Available Options:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 8) {
                    FeatureBullet(text: "OpenAI - Cloud-based, high accuracy")
                    FeatureBullet(text: "Google AI Studio - Advanced AI processing")
                    FeatureBullet(text: "AWS Bedrock - Enterprise-grade AI")
                    FeatureBullet(text: "Ollama - Local AI models")
                    FeatureBullet(text: "Apple Intelligence - On-device privacy")
                    FeatureBullet(text: "Local Whisper - Self-hosted transcription")
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.05))
            )

            Button(action: {
                if let url = URL(string: "https://www.bisonnetworking.com/bisonnotes-ai/") {
                    UIApplication.shared.open(url)
                }
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
                        .stroke(Color(.systemGray4), lineWidth: 0.5)
                )
        )
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("OpenAI Key")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("Enter your OpenAI API key to enable transcription and AI summaries.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 16, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                
                if !apiKey.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("API key entered (\(apiKey.count) characters)")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemBackground))
                    .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(apiKey.isEmpty ? Color(.systemGray4) : Color.blue, lineWidth: apiKey.isEmpty ? 0.5 : 2)
                    )
            )
            
            VStack(alignment: .leading, spacing: 8) {
                Text("What you'll get:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                VStack(alignment: .leading, spacing: 6) {
                    FeatureBullet(text: "Fast, accurate transcription with GPT-4o Mini")
                    FeatureBullet(text: "AI-generated summaries with GPT-4.1 Mini")
                    FeatureBullet(text: "Automatic task and reminder extraction")
                    FeatureBullet(text: "12-hour time format by default")
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.05))
            )
        }
    }
    
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
                        .fill((selectedOption == .openai && apiKey.isEmpty) ? Color.gray : Color.blue)
                )
                .foregroundColor(.white)
            }
            .disabled((selectedOption == .openai && apiKey.isEmpty) || isSaving)
            
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
            
            VStack(alignment: .leading, spacing: 8) {
                Text("💡 Need an API key?")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                Text("Visit platform.openai.com, go to API Keys, and create a new secret key. Make sure your account has credits for usage.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
            )
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
            
            Text("✨ Works on iPhone 15 Pro, iPhone 15 Pro Max, iPhone 16 series, and newer models with Action Button")
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
        apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
    }
    
    private func saveConfiguration() {
        // Only require API key for OpenAI option
        guard selectedOption != .openai || !apiKey.isEmpty else { return }

        isSaving = true
        showingSaveResult = false

        Task {
            do {
                // Set default time format to 12-hour
                UserDefaults.standard.set(TimeFormat.twelveHour.rawValue, forKey: "user_preference_time_format")
                UserPreferences.shared.timeFormat = .twelveHour

                // Configure based on selected option
                if selectedOption == .chooseLater {
                    // For "Choose later", set engines to "Not Configured"
                    UserDefaults.standard.set("Not Configured", forKey: "selectedTranscriptionEngine")
                    UserDefaults.standard.set("Not Configured", forKey: "SelectedAIEngine")

                    await MainActor.run {
                        saveMessage = "Setup completed! You can configure processing options in Settings later."
                        saveSuccessful = true
                        showingSaveResult = true
                        isSaving = false
                    }
                } else if selectedOption == .openai {
                    guard !apiKey.isEmpty else {
                        await MainActor.run {
                            saveMessage = "Please enter your OpenAI API key"
                            saveSuccessful = false
                            showingSaveResult = true
                            isSaving = false
                        }
                        return
                    }
                    
                    // Set unified OpenAI API key for both transcription and summarization
                    UserDefaults.standard.set(apiKey, forKey: "openAIAPIKey")
                    
                    // Set transcription engine to OpenAI with GPT-4o Mini Transcribe
                    UserDefaults.standard.set("gpt-4o-mini-transcribe", forKey: "openAIModel")
                    UserDefaults.standard.set("OpenAI", forKey: "selectedTranscriptionEngine")
                    
                    // Set AI engine to GPT-4.1 Mini for summaries
                    UserDefaults.standard.set("OpenAI", forKey: "SelectedAIEngine")
                    UserDefaults.standard.set("gpt-4.1-mini", forKey: "openAISummarizationModel")
                    
                    // Test the API key
                    let config = OpenAITranscribeConfig(
                        apiKey: apiKey,
                        model: .gpt4oMiniTranscribe,
                        baseURL: "https://api.openai.com/v1"
                    )
                    
                    let service = OpenAITranscribeService(config: config, chunkingService: AudioFileChunkingService())
                    try await service.testConnection()
                    
                } else {
                    // Set transcription engine to Apple Intelligence
                    UserDefaults.standard.set("Apple Intelligence (Limited)", forKey: "selectedTranscriptionEngine")
                    
                    // Set AI engine to Apple Intelligence for summaries
                    UserDefaults.standard.set("Enhanced Apple Intelligence", forKey: "SelectedAIEngine")
                    
                    // No API key testing needed for Apple Intelligence
                }
                
                await MainActor.run {
                    saveMessage = "Configuration saved successfully! Ready to start recording."
                    saveSuccessful = true
                    showingSaveResult = true
                    isSaving = false
                }
                
                // Mark first setup as complete
                UserDefaults.standard.set(true, forKey: "hasCompletedFirstSetup")
                
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