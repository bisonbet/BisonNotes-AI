//
//  MistralTranscribeSettingsView.swift
//  Audio Journal
//
//  Settings view for Mistral AI transcription (Voxtral Mini)
//

import SwiftUI

struct MistralTranscribeSettingsView: View {
    // Reuse existing Mistral API key from summarization settings
    @AppStorage("mistralAPIKey") private var apiKey: String = ""
    @AppStorage("mistralBaseURL") private var baseURL: String = "https://api.mistral.ai/v1"

    // Transcription-specific settings
    @AppStorage("mistralTranscribeDiarize") private var enableDiarization: Bool = false
    @AppStorage("mistralTranscribeLanguage") private var language: String = ""

    @State private var isTestingConnection = false
    @State private var connectionTestResult: String = ""
    @State private var showingConnectionResult = false
    @State private var isConnectionSuccessful = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                apiConfigurationSection
                transcriptionSettingsSection
                connectionTestSection
                featuresSection
            }
            .navigationTitle("Mistral Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var apiConfigurationSection: some View {
        Section(header: Text("API Configuration")) {
            if !apiKey.isEmpty {
                HStack {
                    Text("API Key")
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Configured")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            } else {
                HStack {
                    Text("API Key")
                    Spacer()
                    Text("Not set")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Text("Uses the same API key as Mistral AI summarization. Configure it in AI Settings > Mistral AI.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var transcriptionSettingsSection: some View {
        Section(header: Text("Transcription Settings")) {
            HStack {
                Text("Model")
                Spacer()
                Text(MistralTranscribeModel.voxtralMiniLatest.displayName)
                    .foregroundColor(.secondary)
            }

            Text(MistralTranscribeModel.voxtralMiniLatest.description)
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Speaker Diarization", isOn: $enableDiarization)

            Text("When enabled, the transcription identifies and labels different speakers in the audio.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Language (Optional)")
                    .font(.headline)
                TextField("Auto-detect (leave empty)", text: $language)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Text("Specify a language code (e.g., 'en', 'fr', 'es') for better accuracy, or leave empty for auto-detection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var connectionTestSection: some View {
        Section(header: Text("Connection")) {
            Button(action: testConnection) {
                HStack {
                    if isTestingConnection {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "network")
                    }
                    Text("Test Connection")
                }
            }
            .disabled(apiKey.isEmpty || isTestingConnection)

            if showingConnectionResult {
                HStack {
                    Image(systemName: isConnectionSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(isConnectionSuccessful ? .green : .red)
                    Text(connectionTestResult)
                        .font(.caption)
                        .foregroundColor(isConnectionSuccessful ? .green : .red)
                }
            }
        }
    }

    private var featuresSection: some View {
        Section(header: Text("Features & Limits")) {
            FeatureRow(
                icon: "doc.text",
                title: "Supported Formats",
                description: "MP3, MP4, M4A, WAV, FLAC, OGG, WebM"
            )
            FeatureRow(
                icon: "person.2",
                title: "Speaker Diarization",
                description: "Identifies and labels different speakers"
            )
            FeatureRow(
                icon: "globe",
                title: "Language Support",
                description: "Automatic language detection or specify language code"
            )
            FeatureRow(
                icon: "dollarsign.circle",
                title: "Pricing",
                description: "$0.003 per minute of audio"
            )
        }
    }

    // MARK: - Actions

    private func testConnection() {
        guard !apiKey.isEmpty else { return }
        isTestingConnection = true
        showingConnectionResult = false

        Task {
            // Reuse the existing MistralAIEngine connection test — same API key, same endpoint
            let engine = MistralAIEngine()
            let success = await engine.testConnection()

            await MainActor.run {
                isTestingConnection = false
                if success {
                    connectionTestResult = "Connection successful! API key is valid."
                    isConnectionSuccessful = true
                } else {
                    connectionTestResult = "Connection failed. Please verify your API key in Mistral AI settings."
                    isConnectionSuccessful = false
                }
                showingConnectionResult = true
            }
        }
    }
}

#Preview {
    MistralTranscribeSettingsView()
}
