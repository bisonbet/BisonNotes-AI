//
//  MistralOnboardingView.swift
//  Audio Journal
//
//  Guided onboarding wizard for setting up a free Mistral AI account
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct MistralOnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("mistralAPIKey") private var mistralAPIKey: String = ""
    @AppStorage("mistralModel") private var mistralModel: String = MistralAIModel.mistralMedium2508.rawValue
    @AppStorage("mistralBaseURL") private var mistralBaseURL: String = "https://api.mistral.ai/v1"
    @AppStorage("mistralTemperature") private var mistralTemperature: Double = 0.1
    @AppStorage("mistralMaxTokens") private var mistralMaxTokens: Int = 4096
    @AppStorage("enableMistralAI") private var enableMistralAI: Bool = false
    @AppStorage("mistralSupportsJsonResponseFormat") private var supportsJsonResponseFormat: Bool = true
    @AppStorage("mistralTranscribeDiarize") private var transcribeDiarize: Bool = true

    @State private var currentStep = 0
    @State private var apiKeyInput: String = ""
    @State private var showingSafari = false
    @State private var safariURL: URL?
    @State private var isTestingConnection = false
    @State private var connectionTestPassed = false
    @State private var connectionTestFailed = false
    @State private var accountCreated = false
    @State private var keyGenerated = false

    /// Called when setup completes successfully so the parent can refresh state.
    var onSetupComplete: (() -> Void)?

    private let totalSteps = 5

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                stepIndicator
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                TabView(selection: $currentStep) {
                    welcomeStep.tag(0)
                    createAccountStep.tag(1)
                    generateKeyStep.tag(2)
                    pasteKeyStep.tag(3)
                    completeStep.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: currentStep)
            }
            .navigationTitle("Mistral AI Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingSafari) {
                if let url = safariURL {
                    #if !targetEnvironment(macCatalyst)
                    SafariView(url: url)
                    #endif
                }
            }
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { step in
                Circle()
                    .fill(step == currentStep ? Color.orange : (step < currentStep ? Color.orange.opacity(0.5) : Color(.systemGray4)))
                    .frame(width: 10, height: 10)
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "wind")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                        .padding(.bottom, 4)

                    Text("Free AI Transcription & Summaries")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Mistral AI offers a free tier with access to all their models -- no credit card required.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("What you'll get:")
                        .font(.headline)

                    benefitRow(icon: "waveform", title: "Audio Transcription", detail: "Voxtral Mini with speaker diarization")
                    benefitRow(icon: "doc.text", title: "AI Summaries", detail: "Automatic summaries, tasks, and reminders")
                    benefitRow(icon: "gift", title: "Free Tier Included", detail: "No credit card, all models, 500K tokens/min")
                    benefitRow(icon: "clock", title: "Quick Setup", detail: "About 2 minutes to get started")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Free tier limits:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text("~2 requests/second, 1B tokens/month. More than enough for personal use.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.08))
                )

                Spacer(minLength: 20)

                Button(action: { withAnimation { currentStep = 1 } }) {
                    Text("Get Started")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Step 2: Create Account

    private var createAccountStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Step 1: Create Account", systemImage: "person.badge.plus")
                        .font(.title3)
                        .fontWeight(.bold)

                    Text("Create a free Mistral AI account on their console. You'll just need an email and phone number.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Steps to follow:")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    numberedStep(number: 1, text: "Tap the button below to open Mistral's console")
                    numberedStep(number: 2, text: "Sign up with your email address")
                    numberedStep(number: 3, text: "Verify your phone number")
                    numberedStep(number: 4, text: "Create a workspace (any name works)")
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray6))
                )

                Button(action: {
                    safariURL = URL(string: "https://console.mistral.ai")
                    showingSafari = true
                }) {
                    Label("Open Mistral Console", systemImage: "safari")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                Spacer(minLength: 20)

                HStack {
                    Button(action: { withAnimation { currentStep = 0 } }) {
                        Label("Back", systemImage: "chevron.left")
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Button(action: {
                        accountCreated = true
                        withAnimation { currentStep = 2 }
                    }) {
                        Text("I've Created My Account")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(10)
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Step 3: Generate API Key

    private var generateKeyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Step 2: Generate API Key", systemImage: "key")
                        .font(.title3)
                        .fontWeight(.bold)

                    Text("Now create an API key so BisonNotes can connect to Mistral AI.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Steps to follow:")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    numberedStep(number: 1, text: "Tap the button below to open the API Keys page")
                    numberedStep(number: 2, text: "Click \"Create new key\"")
                    numberedStep(number: 3, text: "Name it \"BisonNotes\" (or anything you like)")
                    numberedStep(number: 4, text: "Copy the key — it's only shown once!")
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray6))
                )

                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Make sure to copy the key before closing the page. Mistral only shows it once.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.08))
                )

                Button(action: {
                    safariURL = URL(string: "https://console.mistral.ai/api-keys")
                    showingSafari = true
                }) {
                    Label("Open API Keys Page", systemImage: "safari")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                Spacer(minLength: 20)

                HStack {
                    Button(action: { withAnimation { currentStep = 1 } }) {
                        Label("Back", systemImage: "chevron.left")
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Button(action: {
                        keyGenerated = true
                        withAnimation { currentStep = 3 }
                    }) {
                        Text("I've Copied My Key")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(10)
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Step 4: Paste & Validate Key

    private var pasteKeyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Step 3: Enter Your API Key", systemImage: "key.fill")
                        .font(.title3)
                        .fontWeight(.bold)

                    Text("Paste the API key you just copied from Mistral's console.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SecureField("Paste your Mistral API key", text: $apiKeyInput)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.system(size: 16, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    Button(action: pasteFromClipboard) {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }

                if !apiKeyInput.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Key entered (\(apiKeyInput.count) characters)")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                Button(action: testConnection) {
                    HStack {
                        if isTestingConnection {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(.white)
                        } else {
                            Image(systemName: "network")
                        }
                        Text(isTestingConnection ? "Testing..." : "Test Connection")
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(apiKeyInput.isEmpty || isTestingConnection ? Color.gray : Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(apiKeyInput.isEmpty || isTestingConnection)

                if connectionTestPassed {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Connection successful! Your key is valid.")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green.opacity(0.1))
                    )
                }

                if connectionTestFailed {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("Connection failed. Please check your API key and try again.")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.1))
                    )
                }

                Spacer(minLength: 20)

                HStack {
                    Button(action: { withAnimation { currentStep = 2 } }) {
                        Label("Back", systemImage: "chevron.left")
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    if connectionTestPassed {
                        Button(action: {
                            applyConfiguration()
                            withAnimation { currentStep = 4 }
                        }) {
                            Text("Continue")
                                .fontWeight(.semibold)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Step 5: Complete

    private var completeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .center, spacing: 16) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.green)

                    Text("You're All Set!")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Mistral AI has been configured and is ready to use.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Configuration Summary")
                        .font(.headline)

                    configRow(label: "AI Engine", value: "Mistral AI")
                    configRow(label: "Summarization Model", value: MistralAIModel.mistralMedium2508.displayName)
                    configRow(label: "Transcription Model", value: "Voxtral Mini")
                    configRow(label: "Speaker Diarization", value: "Enabled")
                    configRow(label: "JSON Response Format", value: "Enabled")
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray6))
                )

                Text("You can adjust these settings anytime in AI Settings > Mistral AI.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer(minLength: 20)

                Button(action: {
                    onSetupComplete?()
                    dismiss()
                }) {
                    Text("Start Using Mistral AI")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Helper Views

    private func benefitRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func numberedStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Color.orange)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }

    private func configRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }

    // MARK: - Actions

    private func pasteFromClipboard() {
        #if canImport(UIKit)
        if let clipboardString = UIPasteboard.general.string, !clipboardString.isEmpty {
            apiKeyInput = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
    }

    private func testConnection() {
        guard !apiKeyInput.isEmpty else { return }

        isTestingConnection = true
        connectionTestPassed = false
        connectionTestFailed = false

        // Temporarily save the key so the engine can read it
        let previousKey = mistralAPIKey
        mistralAPIKey = apiKeyInput

        Task {
            let engine = MistralAIEngine()
            let success = await engine.testConnection()

            await MainActor.run {
                isTestingConnection = false
                if success {
                    connectionTestPassed = true
                    connectionTestFailed = false
                } else {
                    connectionTestFailed = true
                    connectionTestPassed = false
                    // Restore previous key if test failed
                    mistralAPIKey = previousKey
                }
            }
        }
    }

    private func applyConfiguration() {
        // API key is already saved from the test step
        mistralAPIKey = apiKeyInput
        mistralModel = MistralAIModel.mistralMedium2508.rawValue
        mistralBaseURL = "https://api.mistral.ai/v1"
        mistralTemperature = 0.1
        mistralMaxTokens = 4096
        enableMistralAI = true
        supportsJsonResponseFormat = true
        transcribeDiarize = true

        // Set Mistral as the selected AI engine
        UserDefaults.standard.set("Mistral AI", forKey: "SelectedAIEngine")

        // Set Mistral as the selected transcription engine
        UserDefaults.standard.set("Mistral AI", forKey: "selectedTranscriptionEngine")
    }
}

#Preview {
    MistralOnboardingView()
}
