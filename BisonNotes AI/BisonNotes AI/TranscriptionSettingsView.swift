//
//  TranscriptionSettingsView.swift
//  Audio Journal
//
//  Settings view for transcription configuration
//

import SwiftUI

struct TranscriptionSettingsView: View {
    @EnvironmentObject var recorderVM: AudioRecorderViewModel
    @AppStorage("showTranscriptionProgress") private var showTranscriptionProgress: Bool = true
    @AppStorage("enableLiveTranscription") private var enableLiveTranscription: Bool = false
    @AppStorage("selectedTranscriptionEngine") private var selectedTranscriptionEngine: String = TranscriptionEngine.fluidAudio.rawValue

    @StateObject private var fluidAudioManager = FluidAudioManager.shared

    @State private var showingAWSSettings = false
    @State private var showingWhisperSettings = false
    @State private var showingFluidAudioSettings = false
    @State private var showingOpenAISettings = false
    @State private var showingMistralTranscribeSettings = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                liveTranscriptionSection
                fileTranscriptionSection
                selectedEngineConfigurationSection
                displayOptionsSection
                tipsSection
                resetSection
            }
            .navigationTitle("Transcription Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingAWSSettings) {
                AWSSettingsView()
            }
            .sheet(isPresented: $showingWhisperSettings) {
                WhisperSettingsView()
            }
            .sheet(isPresented: $showingFluidAudioSettings) {
                NavigationStack {
                    FluidAudioSettingsView()
                }
            }
            .sheet(isPresented: $showingOpenAISettings) {
                OpenAISettingsView()
            }
            .sheet(isPresented: $showingMistralTranscribeSettings) {
                MistralTranscribeSettingsView()
            }
            .onChange(of: selectedTranscriptionEngine) { _, newValue in
                handleEngineSelection(newValue)
            }
        }
    }

    private func handleEngineSelection(_ engineRawValue: String) {
        guard let engine = TranscriptionEngine(rawValue: engineRawValue) else { return }

        if engine == .fluidAudio {
            UserDefaults.standard.set(true, forKey: FluidAudioModelInfo.SettingsKeys.enableFluidAudio)
            if !fluidAudioManager.isModelReady {
                showingFluidAudioSettings = true
            }
        }
    }

    // MARK: - Live Transcription Section

    private var liveTranscriptionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundColor(.orange)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Transcription")
                            .font(.headline)
                        Text("Real-time text as you record")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $enableLiveTranscription)
                        .labelsHidden()
                        .onChange(of: enableLiveTranscription) { _, enabled in
                            if enabled {
                                Task {
                                    let granted = await LiveTranscriptionService.requestPermission()
                                    if !granted {
                                        await MainActor.run { enableLiveTranscription = false }
                                    }
                                }
                            }
                        }
                }

                if enableLiveTranscription {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Uses Apple Speech Recognition (on-device)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 40)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("During Recording")
        } footer: {
            Text("Live transcription shows text instantly while you speak. Uses Apple's on-device speech recognition for privacy.")
        }
    }

    // MARK: - File Transcription Section

    private var fileTranscriptionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Text("Select the engine used for imported files, re-runs, and post-recording transcription.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // On-Device Options
                VStack(alignment: .leading, spacing: 8) {
                    Label("On-Device (Private)", systemImage: "iphone")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.indigo)

                    engineOptionRow(
                        engine: .fluidAudio,
                        title: "Parakeet",
                        subtitle: "Fast, accurate, works offline",
                        isRecommended: true
                    )
                }

                Divider()

                // Cloud Options
                VStack(alignment: .leading, spacing: 8) {
                    Label("Cloud (Higher Accuracy)", systemImage: "cloud")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)

                    engineOptionRow(
                        engine: .awsTranscribe,
                        title: "AWS Transcribe",
                        subtitle: "Enterprise, speaker diarization, expensive"
                    )

                    engineOptionRow(
                        engine: .mistralAI,
                        title: "Mistral AI",
                        subtitle: "Enterprise, speaker diarization, cheap"
                    )

                    engineOptionRow(
                        engine: .openAI,
                        title: "OpenAI Whisper",
                        subtitle: "Requires API key"
                    )
                }

                Divider()

                // Local Server Options
                VStack(alignment: .leading, spacing: 8) {
                    Label("Local Server", systemImage: "server.rack")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)

                    engineOptionRow(
                        engine: .whisper,
                        title: "Whisper Server",
                        subtitle: "Self-hosted on your network"
                    )
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("For Files & Re-runs")
        } footer: {
            if enableLiveTranscription {
                Text("This engine is also used when live transcription isn't available (imports, re-runs).")
            }
        }
    }

    private func engineOptionRow(
        engine: TranscriptionEngine,
        title: String,
        subtitle: String,
        isRecommended: Bool = false,
        isDeprecated: Bool = false
    ) -> some View {
        Button(action: {
            selectedTranscriptionEngine = engine.rawValue
        }) {
            HStack(spacing: 12) {
                // Selection indicator
                Image(systemName: selectedTranscriptionEngine == engine.rawValue ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selectedTranscriptionEngine == engine.rawValue ? engineColor(for: engine) : .gray)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.body)
                            .foregroundColor(isDeprecated ? .secondary : .primary)

                        if isRecommended {
                            Text("Recommended")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .cornerRadius(4)
                        }

                        if isDeprecated {
                            Text("Legacy")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2))
                                .foregroundColor(.orange)
                                .cornerRadius(4)
                        }
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Status indicator
                if engine.isAvailable {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                } else {
                    Text("Setup")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedTranscriptionEngine == engine.rawValue ? engineColor(for: engine).opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Selected Engine Configuration

    private var selectedEngineConfigurationSection: some View {
        if let selectedEngine = TranscriptionEngine(rawValue: selectedTranscriptionEngine),
           selectedEngine.requiresConfiguration {

            return AnyView(
                Section(header: Text("Configuration")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(selectedEngine.rawValue) Settings")
                                    .font(.body)
                                Text(configurationHint(for: selectedEngine))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()

                            Button(action: {
                                openSettings(for: selectedEngine)
                            }) {
                                HStack {
                                    Image(systemName: "gear")
                                    Text("Configure")
                                }
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(engineColor(for: selectedEngine))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                        }

                        engineStatusView(for: selectedEngine)
                    }
                    .padding(.vertical, 8)
                }
            )
        } else {
            return AnyView(EmptyView())
        }
    }

    private func openSettings(for engine: TranscriptionEngine) {
        switch engine {
        case .notConfigured:
            break
        case .fluidAudio:
            showingFluidAudioSettings = true
        case .awsTranscribe:
            showingAWSSettings = true
        case .whisper:
            showingWhisperSettings = true
        case .openAI:
            showingOpenAISettings = true
        case .mistralAI:
            showingMistralTranscribeSettings = true
        case .openAIAPICompatible:
            break
        }
    }

    private func configurationHint(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .fluidAudio:
            return fluidAudioManager.isModelReady ? "Model downloaded and ready" : "Download required (~250-350 MB)"
        case .openAI:
            return "Requires OpenAI API key"
        case .awsTranscribe:
            return "Requires AWS credentials"
        case .mistralAI:
            return "Requires Mistral API key"
        case .whisper:
            return "Requires local Whisper server"
        default:
            return ""
        }
    }

    private func engineColor(for engine: TranscriptionEngine) -> Color {
        switch engine {
        case .notConfigured:
            return .gray
        case .fluidAudio:
            return .indigo
        case .awsTranscribe:
            return .orange
        case .whisper:
            return .green
        case .openAI:
            return .blue
        case .mistralAI:
            return .purple
        case .openAIAPICompatible:
            return .gray
        }
    }

    private func engineStatusView(for engine: TranscriptionEngine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Status:")
                    .font(.body)
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(engine.isAvailable ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(engine.isAvailable ? "Ready" : "Needs Setup")
                        .font(.caption)
                        .foregroundColor(engine.isAvailable ? .green : .red)
                }
            }

            if engine == .fluidAudio {
                HStack {
                    Text("Privacy:")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield.fill")
                            .font(.caption)
                        Text("On-Device Only")
                    }
                    .font(.caption)
                    .foregroundColor(.green)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(engineColor(for: engine).opacity(0.1))
        )
    }

    private var displayOptionsSection: some View {
        Section {
            Toggle("Show Transcription Progress", isOn: $showTranscriptionProgress)

            Text("Display real-time transcription progress.")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("Display Options")
        }
    }

    private var tipsSection: some View {
        Section {
            TipRow(
                icon: "bolt.fill",
                title: "Best for speed",
                description: "Parakeet offers the fastest on-device transcription."
            )

            TipRow(
                icon: "lock.shield.fill",
                title: "Privacy first",
                description: "On-device engines never send audio to external servers."
            )

            TipRow(
                icon: "waveform.badge.plus",
                title: "Live + File",
                description: "Enable live transcription AND set a file engine for full coverage."
            )
        } header: {
            Text("Tips")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset to Defaults") {
                resetToDefaults()
            }
            .foregroundColor(.red)
        }
    }

    private func resetToDefaults() {
        showTranscriptionProgress = true
        enableLiveTranscription = false
        selectedTranscriptionEngine = TranscriptionEngine.fluidAudio.rawValue
    }
}

struct TipRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct TranscriptionSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TranscriptionSettingsView()
            .environmentObject(AudioRecorderViewModel())
    }
}
