//
//  MistralTranscribeSettingsView.swift
//  Audio Journal
//
//  Settings view for Mistral AI transcription (Voxtral Mini)
//

import SwiftUI

struct MistralTranscribeSettingsView: View {
    // Reuse existing Mistral API key from summarization settings
    @SecureStorage(KeychainSecretStore.mistralAPIKey) private var apiKey: String = ""
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
        PlatformSettingsNavigationStack {
            #if os(macOS)
            nativeMacContent
            #else
            Form {
                apiConfigurationSection
                transcriptionSettingsSection
                connectionTestSection
                featuresSection
            }
            .nativeMacSettingsFormStyle()
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Mistral Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
    }

    #if os(macOS)
    private var nativeMacContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mistral Transcription")
                        .font(.largeTitle.bold())
                    Text("Configure Voxtral cloud transcription and speaker labeling.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                nativeSettingsCard(
                    title: "API Configuration",
                    systemImage: "key.fill",
                    tint: .green
                ) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Mistral API Key")
                                .fontWeight(.semibold)
                            Text("Shared with the Mistral AI summarization engine.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Label(
                            apiKey.isEmpty ? "Not Configured" : "Configured",
                            systemImage: apiKey.isEmpty
                                ? "exclamationmark.circle.fill"
                                : "checkmark.circle.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundColor(apiKey.isEmpty ? .red : .green)
                    }

                    if apiKey.isEmpty {
                        Text("Add the key in AI Settings > Mistral AI before testing this connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                nativeSettingsCard(
                    title: "Transcription Settings",
                    systemImage: "waveform.badge.mic",
                    tint: .orange
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Model")
                            .fontWeight(.semibold)
                        Text(MistralTranscribeModel.voxtralMiniLatest.displayName)
                            .foregroundStyle(.secondary)
                        Text(MistralTranscribeModel.voxtralMiniLatest.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Toggle(isOn: $enableDiarization) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Speaker Diarization")
                                .fontWeight(.semibold)
                            Text("Identify and label different speakers in the audio.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Language (Optional)")
                            .fontWeight(.semibold)
                        TextField("Auto-detect (leave empty)", text: $language)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Text("Use a language code such as en, fr, or es, or leave this empty for automatic detection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                nativeSettingsCard(
                    title: "Connection",
                    systemImage: "network",
                    tint: .blue
                ) {
                    HStack(spacing: 12) {
                        Button(action: testConnection) {
                            if isTestingConnection {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Test Connection", systemImage: "network")
                            }
                        }
                        .disabled(apiKey.isEmpty || isTestingConnection)

                        if showingConnectionResult {
                            Label(
                                connectionTestResult,
                                systemImage: isConnectionSuccessful
                                    ? "checkmark.circle.fill"
                                    : "xmark.circle.fill"
                            )
                            .font(.caption)
                            .foregroundColor(isConnectionSuccessful ? .green : .red)
                        }
                    }
                }

                nativeSettingsCard(
                    title: "Features & Limits",
                    systemImage: "list.bullet.rectangle",
                    tint: .blue
                ) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), alignment: .topLeading),
                            GridItem(.flexible(), alignment: .topLeading)
                        ],
                        alignment: .leading,
                        spacing: 16
                    ) {
                        nativeFeature(
                            icon: "doc.text",
                            title: "Supported Formats",
                            description: "MP3, MP4, M4A, WAV, FLAC, OGG, WebM"
                        )
                        nativeFeature(
                            icon: "person.2",
                            title: "Speaker Diarization",
                            description: "Identifies and labels different speakers"
                        )
                        nativeFeature(
                            icon: "globe",
                            title: "Language Support",
                            description: "Automatic detection or a specified language code"
                        )
                        nativeFeature(
                            icon: "dollarsign.circle",
                            title: "Pricing",
                            description: "$0.003 per minute of audio"
                        )
                    }
                }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(28)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func nativeSettingsCard<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private func nativeFeature(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    #endif

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

    func testConnection() {
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
