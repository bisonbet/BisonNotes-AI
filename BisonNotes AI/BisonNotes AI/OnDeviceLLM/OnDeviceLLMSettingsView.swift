//
//  OnDeviceLLMSettingsView.swift
//  BisonNotes AI
//
//  Settings view for on-device LLM configuration
//

import SwiftUI

// MARK: - On-Device LLM Settings View

struct OnDeviceLLMSettingsView: View {

    // MARK: - State
    @Environment(\.dismiss) private var dismiss

    @AppStorage(OnDeviceLLMModelInfo.SettingsKeys.enableOnDeviceLLM) private var isEnabled = false
    @AppStorage(OnDeviceLLMModelInfo.SettingsKeys.temperature) private var temperature: Double = 0.7
    @AppStorage(OnDeviceLLMModelInfo.SettingsKeys.maxTokens) private var maxTokens = 2048
    @AppStorage(OnDeviceLLMModelInfo.SettingsKeys.topK) private var topK = 40
    @AppStorage(OnDeviceLLMModelInfo.SettingsKeys.topP) private var topP: Double = 0.95
    @AppStorage(OnDeviceLLMModelInfo.SettingsKeys.minP) private var minP: Double = 0.0
    @AppStorage(OnDeviceLLMModelInfo.SettingsKeys.repeatPenalty) private var repeatPenalty: Double = 1.1

    @StateObject private var downloadManager = OnDeviceLLMDownloadManager.shared

    @State private var showingDeleteConfirmation = false
    @State private var modelToDelete: OnDeviceLLMModelInfo?
    @State private var isTestingConnection = false
    @State private var connectionTestResult: Bool?
    @State private var showingAdvancedSettings = false

    // MARK: - Body

    var body: some View {
        Form {
            // Enable Section
            Section {
                Toggle("Enable On-Device LLM", isOn: $isEnabled)
            } footer: {
                Text("Process transcripts locally on your device using a downloaded AI model. No internet connection required after model download.")
            }

            if isEnabled {
                // Model Selection Section
                Section("Model") {
                    modelSelectionView
                }

                // Download Progress (if downloading)
                if downloadManager.isDownloading {
                    Section("Download Progress") {
                        downloadProgressView
                    }
                }

                // Model Status Section
                Section("Model Status") {
                    modelStatusView
                }

                // Settings Section
                Section("Generation Settings") {
                    temperatureSlider
                }

                // Advanced Settings
                Section {
                    DisclosureGroup("Advanced Settings", isExpanded: $showingAdvancedSettings) {
                        advancedSettingsView
                    }
                }

                // Connection Test
                Section {
                    connectionTestButton
                }
            }
        }
        .navigationTitle("On-Device LLM")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .alert("Delete Model?", isPresented: $showingDeleteConfirmation, presenting: modelToDelete) { model in
            Button("Delete", role: .destructive) {
                downloadManager.deleteModel(model)
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("This will delete \(model.displayName) (\(model.downloadSize)) from your device. You can re-download it later.")
        }
    }

    // MARK: - Model Selection View

    @ViewBuilder
    private var modelSelectionView: some View {
        ForEach(OnDeviceLLMModelInfo.allModels) { model in
            modelRow(for: model)
        }
    }

    @ViewBuilder
    private func modelRow(for model: OnDeviceLLMModelInfo) -> some View {
        let isRamSufficient = DeviceCapabilities.totalRAMInGB >= model.requiredRAM
        let canSelect = isRamSufficient && model.isDownloaded
        
        Button {
            if canSelect && model.id != downloadManager.selectedModel.id {
                selectModelAndApplyDefaults(model)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.displayName)
                                .font(.headline)
                                .foregroundColor(isRamSufficient ? .primary : .secondary)

                            if model.id == downloadManager.selectedModel.id && model.isDownloaded {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            }
                        }

                        Text(model.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        
                        if !isRamSufficient {
                            Text("⚠️ Requires \(String(format: "%.0f", model.requiredRAM))GB RAM (Device: \(String(format: "%.1f", DeviceCapabilities.totalRAMInGB))GB)")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }

                    Spacer()
                }

                // Model details
                HStack(spacing: 16) {
                    Label(model.downloadSize, systemImage: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Label("\(model.contextWindow) tokens", systemImage: "text.alignleft")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.trailing, 36)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            modelActionButton(for: model, isRamSufficient: isRamSufficient)
        }
        .padding(.vertical, 4)
        .opacity(isRamSufficient ? 1.0 : 0.6)
    }

    @ViewBuilder
    private func modelActionButton(for model: OnDeviceLLMModelInfo, isRamSufficient: Bool) -> some View {
        if !isRamSufficient {
            Button {
                // No action
            } label: {
                Image(systemName: "exclamationmark.circle")
                    .font(.title2)
                    .foregroundColor(.red)
            }
            .disabled(true)
        } else if model.isDownloaded {
            Menu {
                Button(role: .destructive) {
                    modelToDelete = model
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
        } else if downloadManager.currentlyDownloadingModel?.id == model.id {
            Button {
                downloadManager.cancelDownload()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.title2)
                    .foregroundColor(.red)
            }
        } else {
            Button {
                downloadManager.startDownload(for: model)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
            .disabled(downloadManager.isDownloading)
        }
    }

    /// Select a model and apply its default settings to the UI
    private func selectModelAndApplyDefaults(_ model: OnDeviceLLMModelInfo) {
        downloadManager.selectModel(model)

        // Apply model's default settings to the UI
        let defaults = model.defaultSettings
        temperature = Double(defaults.temperature)
        topK = Int(defaults.topK)
        topP = Double(defaults.topP)
        minP = Double(defaults.minP)
        repeatPenalty = Double(defaults.repeatPenalty)
    }

    // MARK: - Download Progress View

    @ViewBuilder
    private var downloadProgressView: some View {
        VStack(spacing: 12) {
            if let model = downloadManager.currentlyDownloadingModel {
                Text("Downloading \(model.displayName)")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            ProgressView(value: downloadManager.downloadProgress)
                .progressViewStyle(.linear)

            HStack {
                Text("\(formatSize(downloadManager.downloadedSize)) / \(formatSize(downloadManager.totalSize))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(downloadManager.formattedDownloadSpeed)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let timeRemaining = downloadManager.estimatedTimeRemaining {
                Text(timeRemaining)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let error = downloadManager.downloadError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button("Cancel Download") {
                downloadManager.cancelDownload()
            }
            .foregroundColor(.red)
        }
    }

    // MARK: - Model Status View

    @ViewBuilder
    private var modelStatusView: some View {
        if downloadManager.isModelReady {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading) {
                    Text("Ready")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Using \(downloadManager.selectedModel.displayName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } else {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading) {
                    Text("No Model Downloaded")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Download a model to use on-device processing")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Temperature Slider

    @ViewBuilder
    private var temperatureSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Temperature")
                Spacer()
                Text(String(format: "%.1f", temperature))
                    .foregroundColor(.secondary)
            }

            Slider(value: $temperature, in: 0.1...1.5, step: 0.1)

            Text("Lower values produce more focused output, higher values more creative")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Advanced Settings

    @ViewBuilder
    private var advancedSettingsView: some View {
        // Max Tokens
        Stepper(value: $maxTokens, in: 512...4096, step: 256) {
            HStack {
                Text("Max Tokens")
                Spacer()
                Text("\(maxTokens)")
                    .foregroundColor(.secondary)
            }
        }

        // Top-K
        Stepper(value: $topK, in: 1...100, step: 5) {
            HStack {
                Text("Top-K")
                Spacer()
                Text("\(topK)")
                    .foregroundColor(.secondary)
            }
        }

        // Top-P
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Top-P")
                Spacer()
                Text(String(format: "%.2f", topP))
                    .foregroundColor(.secondary)
            }
            Slider(value: $topP, in: 0.1...1.0, step: 0.05)
        }

        // Min-P
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Min-P")
                Spacer()
                Text(String(format: "%.2f", minP))
                    .foregroundColor(.secondary)
            }
            Slider(value: $minP, in: 0.0...0.5, step: 0.01)

            Text("Filters out low probability tokens. Set to 0 to disable.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }

        // Repeat Penalty
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Repeat Penalty")
                Spacer()
                Text(String(format: "%.1f", repeatPenalty))
                    .foregroundColor(.secondary)
            }
            Slider(value: $repeatPenalty, in: 1.0...2.0, step: 0.1)
        }

        Button("Reset to Model Defaults") {
            let defaults = downloadManager.selectedModel.defaultSettings
            temperature = Double(defaults.temperature)
            topK = Int(defaults.topK)
            topP = Double(defaults.topP)
            minP = Double(defaults.minP)
            repeatPenalty = Double(defaults.repeatPenalty)
            maxTokens = 2048
        }
        .foregroundColor(.blue)
    }

    // MARK: - Connection Test

    @ViewBuilder
    private var connectionTestButton: some View {
        Button {
            testConnection()
        } label: {
            HStack {
                if isTestingConnection {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.trailing, 4)
                    Text("Testing...")
                } else {
                    Text("Test Model")
                }

                Spacer()

                if let result = connectionTestResult {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(result ? .green : .red)
                }
            }
        }
        .disabled(isTestingConnection || !downloadManager.isModelReady)
    }

    // MARK: - Helper Methods

    private func testConnection() {
        isTestingConnection = true
        connectionTestResult = nil

        Task {
            let engine = OnDeviceLLMEngine()
            let result = await engine.testConnection()

            await MainActor.run {
                connectionTestResult = result
                isTestingConnection = false
            }
        }
    }

    private func formatSize(_ size: Int64) -> String {
        let sizeInGB = Double(size) / 1_000_000_000.0
        if sizeInGB >= 1.0 {
            return String(format: "%.2f GB", sizeInGB)
        } else {
            let sizeInMB = Double(size) / 1_000_000.0
            return String(format: "%.0f MB", sizeInMB)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        OnDeviceLLMSettingsView()
    }
}
