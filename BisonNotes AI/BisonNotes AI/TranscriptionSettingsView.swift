//
//  TranscriptionSettingsView.swift
//  Audio Journal
//
//  Settings view for transcription configuration
//

import SwiftUI

struct TranscriptionSettingsView: View {
    @AppStorage("showTranscriptionProgress") private var showTranscriptionProgress: Bool = true
    @AppStorage("enableLiveTranscription") private var enableLiveTranscription: Bool = false
    @AppStorage("selectedTranscriptionEngine") private var selectedTranscriptionEngine: String = TranscriptionEngine.fluidAudio.rawValue

    @StateObject private var fluidAudioManager = FluidAudioManager.shared

    @State private var showingWhisperSettings = false
    @State private var showingFluidAudioSettings = false
    @State private var showingMistralTranscribeSettings = false
#if os(macOS)
    @State private var macSelectedEngineRawValue: String?
#endif
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
#if os(macOS)
            settingsContent
#else
            settingsContent
                .navigationTitle("Transcription Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            .sheet(isPresented: $showingWhisperSettings) {
                WhisperSettingsView()
            }
            .sheet(isPresented: $showingFluidAudioSettings) {
                NavigationStack {
                    FluidAudioSettingsView()
                }
            }
            .sheet(isPresented: $showingMistralTranscribeSettings) {
                MistralTranscribeSettingsView()
            }
#endif
        }
        .onChange(of: selectedTranscriptionEngine) { _, newValue in
            handleEngineSelection(newValue)
#if os(macOS)
            macSelectedEngineRawValue = newValue
#endif
        }
        .platformSettingsNavigation()
    }

    @ViewBuilder
    private var settingsContent: some View {
#if os(macOS)
        macSettingsContent
#else
        modernSettingsContent
#endif
    }

    private var modernSettingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                modernHeader
                modernLiveTranscriptionSection
                modernFileTranscriptionSection
                modernSelectedEngineConfigurationSection
                modernDisplayOptionsSection
                modernTipsSection
                modernResetSection
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
            Text("Transcription")
                .font(.largeTitle.weight(.bold))
                .foregroundColor(.primary)

            Text("Choose how recordings and imported files become editable text.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var modernLiveTranscriptionSection: some View {
        TranscriptionSettingsCard(title: "During Recording", systemImage: "waveform", tint: .orange) {
            Toggle(isOn: $enableLiveTranscription) {
                TranscriptionSettingsLabel(
                    title: "Live Transcription",
                    subtitle: "Real-time text as you record",
                    systemImage: "waveform",
                    tint: .orange
                )
            }
            .onChange(of: enableLiveTranscription) { _, enabled in
                liveTranscriptionChanged(enabled)
            }

            if enableLiveTranscription {
                TranscriptionInlineStatus(
                    title: "Uses Apple Speech Recognition",
                    subtitle: "On-device where available",
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                )
            }

            Text("Live transcription shows text instantly while you speak.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var modernFileTranscriptionSection: some View {
        TranscriptionSettingsCard(title: "Files & Re-runs", systemImage: "doc.text", tint: .blue) {
            Text("Select the engine used for imported files, re-runs, and post-recording transcription.")
                .font(.caption)
                .foregroundColor(.secondary)

            modernEngineGroupHeader("On-Device (Private)", systemImage: "iphone", tint: .indigo)
            modernEngineOptionRow(
                engine: .fluidAudio,
                title: "Parakeet",
                subtitle: "Fast, accurate, works offline",
                isRecommended: true
            )

            Divider()

            modernEngineGroupHeader("Cloud (Higher Accuracy)", systemImage: "cloud", tint: .blue)
            modernEngineOptionRow(
                engine: .mistralAI,
                title: "Mistral AI",
                subtitle: "Enterprise, speaker diarization, cheap"
            )
            Divider()

            modernEngineGroupHeader("Local Server", systemImage: "server.rack", tint: .green)
            modernEngineOptionRow(
                engine: .whisper,
                title: "Whisper Server",
                subtitle: "Self-hosted on your network"
            )
        }
    }

    @ViewBuilder
    private var modernSelectedEngineConfigurationSection: some View {
        if let selectedEngine = TranscriptionEngine(rawValue: selectedTranscriptionEngine),
           selectedEngine.requiresConfiguration {
            TranscriptionSettingsCard(title: "Configuration", systemImage: "gear", tint: engineColor(for: selectedEngine)) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(selectedEngine.rawValue) Settings")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(configurationHint(for: selectedEngine))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        openSettings(for: selectedEngine)
                    }) {
                        Label(configurationButtonTitle(for: selectedEngine), systemImage: "gear")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(engineColor(for: selectedEngine))
                }

                modernEngineStatusView(for: selectedEngine)
            }
        }
    }

    private var modernDisplayOptionsSection: some View {
        TranscriptionSettingsCard(title: "Display Options", systemImage: "eye", tint: .purple) {
            Toggle("Show Transcription Progress", isOn: $showTranscriptionProgress)

            Text("Display real-time transcription progress.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var modernTipsSection: some View {
        TranscriptionSettingsCard(title: "Tips", systemImage: "lightbulb", tint: .yellow) {
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
        }
    }

    private var modernResetSection: some View {
        TranscriptionSettingsCard(title: "Reset", systemImage: "arrow.counterclockwise", tint: .red) {
            Button(role: .destructive) {
                resetToDefaults()
            } label: {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier(BisonNotesAccessibilityID.transcriptionResetButton)
        }
    }

    private func handleEngineSelection(_ engineRawValue: String) {
        guard let engine = TranscriptionEngine(rawValue: engineRawValue) else { return }

        if engine == .fluidAudio {
            UserDefaults.standard.set(true, forKey: FluidAudioModelInfo.SettingsKeys.enableFluidAudio)
#if !os(macOS)
            if !fluidAudioManager.isModelReady {
                showingFluidAudioSettings = true
            }
#endif
        }
    }

    private func liveTranscriptionChanged(_ enabled: Bool) {
        guard enabled else { return }

        Task {
            let granted = await LiveTranscriptionService.requestPermission()
            if !granted {
                await MainActor.run { enableLiveTranscription = false }
            }
        }
    }

}

#if os(macOS)
private extension TranscriptionSettingsView {
    private var macSettingsContent: some View {
        HSplitView {
            macEngineList
                .frame(minWidth: 210, idealWidth: 235, maxWidth: 260)

            VStack(alignment: .leading, spacing: 0) {
                macTranscriptionOptions

                Divider()

                macSelectedEngineDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 500)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: 560)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            synchronizeMacEngineSelection()
        }
        .onChange(of: macSelectedEngineRawValue) { _, newValue in
            guard let newValue,
                  TranscriptionEngine(rawValue: newValue) != nil,
                  selectedTranscriptionEngine != newValue else { return }
            selectedTranscriptionEngine = newValue
        }
    }

    private var macEngineList: some View {
        List(selection: $macSelectedEngineRawValue) {
            Section("Transcription Engines") {
                ForEach(macSelectableEngines, id: \.rawValue) { engine in
                    macEngineRow(for: engine)
                }
            }

            Section {
                Button(role: .destructive) {
                    resetToDefaults()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
                .accessibilityIdentifier(BisonNotesAccessibilityID.transcriptionResetButton)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Transcription engines")
    }

    private var macSelectableEngines: [TranscriptionEngine] {
        var engines: [TranscriptionEngine] = [.fluidAudio, .mistralAI, .whisper]
        if TranscriptionEngine(rawValue: selectedTranscriptionEngine) == .notConfigured {
            engines.insert(.notConfigured, at: 0)
        }
        return engines
    }

    private var macSelectedEngine: TranscriptionEngine {
        let rawValue = macSelectedEngineRawValue ?? selectedTranscriptionEngine
        return TranscriptionEngine(rawValue: rawValue) ?? .fluidAudio
    }

    private func macEngineRow(for engine: TranscriptionEngine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: transcriptionIcon(for: engine))
                .foregroundStyle(engineColor(for: engine))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(macEngineTitle(for: engine))
                    .font(.body.weight(.medium))
                Text(macEngineSubtitle(for: engine))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Label(
                engine.isAvailable ? "Ready" : "Needs Setup",
                systemImage: engine.isAvailable
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle.fill"
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(engine.isAvailable ? .green : .orange)
        }
        .contentShape(Rectangle())
        .tag(engine.rawValue)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(macEngineTitle(for: engine))
        .accessibilityValue(engine.isAvailable ? "Ready" : "Needs Setup")
    }

    private var macTranscriptionOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription")
                .font(.title2.weight(.semibold))

            Toggle(isOn: $enableLiveTranscription) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live Transcription")
                        .font(.headline)
                    Text("Real-time text as you record using Apple Speech Recognition.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: enableLiveTranscription) { _, enabled in
                liveTranscriptionChanged(enabled)
            }

            Toggle("Show Transcription Progress", isOn: $showTranscriptionProgress)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.windowBackgroundColor))
    }

    @ViewBuilder
    private var macSelectedEngineDetail: some View {
        switch macSelectedEngine {
        case .fluidAudio:
            FluidAudioSettingsView()
        case .mistralAI:
            MistralTranscribeSettingsView()
        case .whisper:
            WhisperSettingsView()
        case .notConfigured:
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose a transcription engine")
                    .font(.title2.weight(.semibold))
                Text("Select an engine from the list to configure transcription.")
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }

    private func synchronizeMacEngineSelection() {
        let selectedRawValue = TranscriptionEngine(rawValue: selectedTranscriptionEngine)?.rawValue
            ?? TranscriptionEngine.fluidAudio.rawValue
        macSelectedEngineRawValue = selectedRawValue
    }

    private func macEngineTitle(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .notConfigured:
            return "Not Configured"
        case .fluidAudio:
            return "Parakeet"
        case .whisper:
            return "Whisper Server"
        case .mistralAI:
            return "Mistral AI"
        }
    }

    private func macEngineSubtitle(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .notConfigured:
            return "Choose an engine to get started"
        case .fluidAudio:
            return "Private, on-device"
        case .whisper:
            return "Self-hosted server"
        case .mistralAI:
            return "Cloud with diarization"
        }
    }
}
#endif

private extension TranscriptionSettingsView {

    private func modernEngineGroupHeader(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(tint)
    }

    private func modernEngineOptionRow(
        engine: TranscriptionEngine,
        title: String,
        subtitle: String,
        isRecommended: Bool = false,
        isDeprecated: Bool = false
    ) -> some View {
        let tint = engineColor(for: engine)
        let isSelected = selectedTranscriptionEngine == engine.rawValue

        return Button(action: {
            selectedTranscriptionEngine = engine.rawValue
        }) {
            HStack(spacing: 14) {
                Image(systemName: transcriptionIcon(for: engine))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(isDeprecated ? .secondary : .primary)

                        if isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.14))
                                .clipShape(Capsule())
                        }

                        if isDeprecated {
                            Text("Legacy")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                Text(engine.isAvailable ? "Ready" : "Setup")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(engine.isAvailable ? .green : .orange)

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

}

private extension TranscriptionSettingsView {

    private func openSettings(for engine: TranscriptionEngine) {
        switch engine {
        case .notConfigured:
            break
        case .fluidAudio:
            showingFluidAudioSettings = true
        case .whisper:
            showingWhisperSettings = true
        case .mistralAI:
            showingMistralTranscribeSettings = true
        }
    }

    private func configurationHint(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .fluidAudio:
            return fluidAudioManager.isModelReady ? "Model downloaded and ready" : "Download required (~250-350 MB)"
        case .mistralAI:
            return "Requires Mistral API key"
        case .whisper:
            return "Requires local Whisper server"
        default:
            return ""
        }
    }

    private func configurationButtonTitle(for engine: TranscriptionEngine) -> String {
        engine == .fluidAudio ? "Configure On Device" : "Configure"
    }

    private func engineColor(for engine: TranscriptionEngine) -> Color {
        switch engine {
        case .notConfigured:
            return .gray
        case .fluidAudio:
            return .indigo
        case .whisper:
            return .green
        case .mistralAI:
            return .purple
        }
    }

    private func modernEngineStatusView(for engine: TranscriptionEngine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Status")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Label(engine.isAvailable ? "Ready" : "Needs Setup", systemImage: engine.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(engine.isAvailable ? .green : .red)
            }

            if engine == .fluidAudio {
                HStack {
                    Text("Privacy")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Label("On-Device Only", systemImage: "lock.shield.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.green)
                }
            }
        }
        .padding(12)
        .background(engineColor(for: engine).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func transcriptionIcon(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .notConfigured:
            return "circle"
        case .fluidAudio:
            return "iphone"
        case .whisper:
            return "server.rack"
        case .mistralAI:
            return "wind"
        }
    }

    private func resetToDefaults() {
        let previousMethodRaw = FluidAudioModelInfo.LocalSpeakerLabels.normalizedMethodRawValue(
            UserDefaults.standard.string(
                forKey: FluidAudioModelInfo.SettingsKeys.selectedLocalSpeakerLabelMethod
            ) ?? FluidAudioModelInfo.LocalSpeakerLabels.defaultMethodRawValue
        )
        let previousMethod = LocalDiarizationMethod(rawValue: previousMethodRaw) ?? .offlineVBx

        showTranscriptionProgress = true
        enableLiveTranscription = false
        selectedTranscriptionEngine = TranscriptionEngine.fluidAudio.rawValue
        UserDefaults.standard.set(
            FluidAudioModelInfo.LocalSpeakerLabels.defaultEnabled,
            forKey: FluidAudioModelInfo.SettingsKeys.localSpeakerLabelsEnabled
        )
        UserDefaults.standard.set(
            FluidAudioModelInfo.LocalSpeakerLabels.defaultMethodRawValue,
            forKey: FluidAudioModelInfo.SettingsKeys.selectedLocalSpeakerLabelMethod
        )

        Task {
            #if DEBUG
            guard !BisonNotesUITestSupport.usesLocalSpeakerModelStatusOverride else { return }
            #endif
            await LocalDiarizationManager.shared.cancelModelPreparation(for: previousMethod)
            await LocalDiarizationManager.shared.unloadModel(for: previousMethod)
        }
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

private struct TranscriptionSettingsCard<Content: View>: View {
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

private struct TranscriptionSettingsLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct TranscriptionInlineStatus: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundColor(tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(tint)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct TranscriptionSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TranscriptionSettingsView()
    }
}
