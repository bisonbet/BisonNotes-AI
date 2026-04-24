//
//  MLXSwiftSettingsView.swift
//  BisonNotes AI
//
//  Settings for the experimental MLX Swift summarization engine.
//

import SwiftUI

// MARK: - Available MLX Models

struct MLXModelOption: Identifiable {
    let id: String          // HuggingFace model ID
    let displayName: String
    let description: String
    let downloadSize: String
    let parameters: String
    let contextWindow: Int
    /// Minimum device RAM in GB required to run this model
    let requiredRAM: Double

    static let available: [MLXModelOption] = [
        MLXModelOption(
            id: "prism-ml/Ternary-Bonsai-4B-mlx-2bit",
            displayName: "Ternary Bonsai 4B",
            description: "Fast, memory-efficient model for on-device summaries.",
            downloadSize: "~1.1 GB",
            parameters: "4B",
            contextWindow: 16_384,
            requiredRAM: 6.0
        ),
        MLXModelOption(
            id: "prism-ml/Ternary-Bonsai-8B-mlx-2bit",
            displayName: "Ternary Bonsai 8B",
            description: "Slower but higher quality summaries.",
            downloadSize: "~2.3 GB",
            parameters: "8B",
            contextWindow: 16_384,
            requiredRAM: 8.0
        ),
    ]
}

// MARK: - MLX Swift Settings View

struct MLXSwiftSettingsView: View {

    // MARK: - State

    @Environment(\.dismiss) private var dismiss

    @AppStorage(MLXSwiftSettingsKeys.enabled) private var isEnabled = false
    @AppStorage(MLXSwiftSettingsKeys.modelId) private var modelId = MLXSwiftSettingsKeys.defaultModelId
    @AppStorage(MLXSwiftSettingsKeys.temperature) private var temperature = MLXSwiftSettingsKeys.defaultTemperature
    @AppStorage(MLXSwiftSettingsKeys.maxTokens) private var maxTokens = MLXSwiftSettingsKeys.defaultMaxTokens
    @AppStorage(MLXSwiftSettingsKeys.topK) private var topK = MLXSwiftSettingsKeys.defaultTopK
    @AppStorage(MLXSwiftSettingsKeys.topP) private var topP = MLXSwiftSettingsKeys.defaultTopP
    @AppStorage(MLXSwiftSettingsKeys.repetitionPenalty) private var repetitionPenalty = MLXSwiftSettingsKeys.defaultRepetitionPenalty

    @StateObject private var downloadManager = MLXSwiftDownloadManager.shared

    @State private var showingDeleteConfirmation = false
    @State private var modelToDelete: MLXModelOption?
    @State private var showingAdvancedSettings = false

    // MARK: - Body

    var body: some View {
        let isSupported = DeviceCapabilities.supportsOnDeviceLLM

        return Form {
            // Info Section
            Section {
                if isSupported {
                    Text("Process transcripts locally using Apple's MLX framework. Models download from Hugging Face on first use. No internet connection required after download.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    let deviceRAM = DeviceCapabilities.totalRAMInGB
                    if deviceRAM >= 4.0 && deviceRAM < 6.0 {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Limited Memory")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.orange)
                                Text("Your device has 4-6GB RAM. The 4B model is recommended. The 8B model may not fit in memory.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                } else {
                    Text("MLX Swift requires a device with 4GB+ RAM and Apple Silicon. Your device does not meet this requirement.")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // Model Selection Section
            Section("Model") {
                ForEach(MLXModelOption.available.filter { DeviceCapabilities.totalRAMInGB >= $0.requiredRAM }) { model in
                    modelRow(for: model)
                }
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

            // Generation Settings
            Section("Generation Settings") {
                temperatureSlider
            }

            // Advanced Settings
            Section {
                DisclosureGroup("Advanced Settings", isExpanded: $showingAdvancedSettings) {
                    advancedSettingsView
                }
            }
        }
        .navigationTitle("MLX Swift")
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
                // Temporarily point the download manager at this model to delete it
                let previousId = modelId
                modelId = model.id
                downloadManager.refreshModelStatus()
                downloadManager.deleteModel()
                modelId = previousId
                downloadManager.refreshModelStatus()
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("This will delete \(model.displayName) (\(model.downloadSize)) from your device. You can re-download it later.")
        }
        .onChange(of: modelId) {
            downloadManager.refreshModelStatus()
        }
    }

    // MARK: - Model Row

    @ViewBuilder
    private func modelRow(for model: MLXModelOption) -> some View {
        let isSelected = modelId == model.id
        let isDownloaded = isModelDownloaded(model)

        Button {
            if isDownloaded && !isSelected {
                modelId = model.id
                isEnabled = true
                UserDefaults.standard.set(AIEngineType.mlxSwift.rawValue, forKey: "SelectedAIEngine")
                SummaryManager.shared.setEngine(AIEngineType.mlxSwift.rawValue)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.displayName)
                                .font(.headline)

                            if isSelected && isDownloaded {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            }
                        }

                        Text(model.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()
                }

                HStack(spacing: 16) {
                    Label(model.downloadSize, systemImage: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Label(model.parameters, systemImage: "cpu")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Label("\(model.contextWindow / 1024)k context", systemImage: "text.alignleft")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.trailing, 36)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            modelActionButton(for: model, isDownloaded: isDownloaded)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func modelActionButton(for model: MLXModelOption, isDownloaded: Bool) -> some View {
        if isDownloaded {
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
        } else if downloadManager.isDownloading && downloadManager.modelId == model.id {
            Button {
                downloadManager.cancelDownload()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.title2)
                    .foregroundColor(.red)
            }
        } else {
            Button {
                modelId = model.id
                downloadManager.refreshModelStatus()
                downloadManager.startDownload()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
            .disabled(downloadManager.isDownloading)
        }
    }

    /// Check if a specific model is downloaded (independent of the currently selected model).
    private func isModelDownloaded(_ model: MLXModelOption) -> Bool {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        // Use the download manager's check but for a specific model ID
        if model.id == downloadManager.modelId {
            return downloadManager.isModelDownloaded
        }
        // For non-selected models, check the file system directly
        return MLXSwiftDownloadManager.shared.checkModelExists(modelId: model.id)
        #else
        return false
        #endif
    }

    // MARK: - Download Progress View

    @ViewBuilder
    private var downloadProgressView: some View {
        VStack(spacing: 12) {
            Text("Downloading \(downloadManager.modelDisplayName)")
                .font(.subheadline)
                .fontWeight(.medium)

            ProgressView(value: downloadManager.downloadProgress)
                .progressViewStyle(.linear)

            Text("\(Int(downloadManager.downloadProgress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)

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
        if downloadManager.isModelDownloaded {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading) {
                    Text("Ready")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Using \(downloadManager.modelDisplayName)")
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
                    Text("Download a model to use MLX Swift processing")
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
                Text(String(format: "%.2f", temperature))
                    .foregroundColor(.secondary)
            }

            Slider(value: $temperature, in: 0.0...1.0, step: 0.05)

            Text("Lower values produce more focused output, higher values more creative")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Advanced Settings

    @ViewBuilder
    private var advancedSettingsView: some View {
        // Context Size (automatically determined by device RAM)
        HStack {
            Text("Context Size")
            Spacer()
            Text("\(DeviceCapabilities.onDeviceLLMContextSize) tokens")
                .foregroundColor(.secondary)
        }
        Text("Automatically set based on device RAM: \(DeviceCapabilities.onDeviceLLMContextSize == 8192 ? "8k" : "16k") for devices with \(DeviceCapabilities.onDeviceLLMContextSize == 8192 ? "<8GB" : "\u{2265}8GB") RAM")
            .font(.caption2)
            .foregroundColor(.secondary)

        // Max Output Tokens
        Stepper(value: $maxTokens, in: 512...4096, step: 128) {
            HStack {
                Text("Max Output")
                Spacer()
                Text("\(maxTokens) tokens")
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

        // Repeat Penalty
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Repeat Penalty")
                Spacer()
                Text(String(format: "%.2f", repetitionPenalty))
                    .foregroundColor(.secondary)
            }
            Slider(value: $repetitionPenalty, in: 1.0...2.0, step: 0.05)
        }

        // Custom model ID
        TextField("Custom Hugging Face Model ID", text: $modelId)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.callout.monospaced())

        Button("Reset to Defaults") {
            modelId = MLXSwiftSettingsKeys.defaultModelId
            temperature = MLXSwiftSettingsKeys.defaultTemperature
            maxTokens = MLXSwiftSettingsKeys.defaultMaxTokens
            topK = MLXSwiftSettingsKeys.defaultTopK
            topP = MLXSwiftSettingsKeys.defaultTopP
            repetitionPenalty = MLXSwiftSettingsKeys.defaultRepetitionPenalty
        }
        .foregroundColor(.blue)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        MLXSwiftSettingsView()
    }
}
