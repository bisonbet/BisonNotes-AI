//
//  MLXWhisperSettingsView.swift
//  BisonNotes AI
//
//  Configuration view for MLX Whisper on-device transcription
//

import SwiftUI

struct MLXWhisperSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedModel: MLXWhisperModel = .whisperMedium4bit
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0.0
    @State private var showingDeleteConfirmation = false
    @State private var showingError = false
    @State private var errorMessage = ""

    init() {
        // Initialize with current settings
        let modelString = UserDefaults.standard.string(forKey: "mlxWhisperModelName") ?? MLXWhisperModel.whisperMedium4bit.rawValue
        _selectedModel = State(initialValue: MLXWhisperModel(rawValue: modelString) ?? .whisperMedium4bit)
    }

    var body: some View {
        NavigationView {
            Form {
                modelSelectionSection
                modelInfoSection
                modelManagementSection
            }
            .navigationTitle("MLX Whisper Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveConfiguration()
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") {
                    errorMessage = ""
                }
            } message: {
                Text(errorMessage)
            }
            .alert("Delete Model", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    deleteModel()
                }
            } message: {
                Text("Are you sure you want to delete this model? This will free up \(selectedModel.estimatedSize) of storage.")
            }
        }
    }

    // MARK: - View Sections

    private var modelSelectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model Selection")
                    .font(.headline)
                Text("Choose a Whisper model optimized for on-device transcription")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)

            Picker("Model", selection: $selectedModel) {
                ForEach(MLXWhisperModel.availableModels, id: \.self) { model in
                    VStack(alignment: .leading) {
                        Text(model.displayName)
                            .font(.body)
                        Text(model.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .tag(model)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Model")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Larger models provide better accuracy but take more time and storage. Medium is recommended for most users.")
                    .font(.caption)

                if !DeviceCapabilities.supportsWhisperLarge {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                        Text("Large models require 6GB+ RAM. Your device has \(DeviceCapabilities.ramDescription). Base and Medium models are available.")
                            .font(.caption)
                    }
                    .foregroundColor(.orange)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var modelInfoSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model: \(selectedModel.displayName)")
                        .font(.body)
                        .fontWeight(.medium)

                    Text("Size: \(selectedModel.estimatedSize)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if isModelDownloaded() {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Downloaded")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                                .foregroundColor(.orange)
                            Text("Not Downloaded")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
        } header: {
            Text("Status")
        }
    }

    private var modelManagementSection: some View {
        Section {
            if !isModelDownloaded() {
                Button(action: {
                    downloadModel()
                }) {
                    HStack {
                        if isDownloading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }

                        VStack(alignment: .leading) {
                            Text(isDownloading ? "Downloading..." : "Download Model")
                                .font(.body)
                                .fontWeight(.medium)

                            if isDownloading {
                                Text("Please wait, this may take several minutes")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Download from Hugging Face (\(selectedModel.estimatedSize))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .disabled(isDownloading)
            } else {
                Button(role: .destructive, action: {
                    showingDeleteConfirmation = true
                }) {
                    HStack {
                        Image(systemName: "trash")
                        VStack(alignment: .leading) {
                            Text("Delete Model")
                                .font(.body)
                                .fontWeight(.medium)

                            Text("Free up \(selectedModel.estimatedSize) of storage")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Model Management")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Models are downloaded from Hugging Face and cached locally. All transcription happens on-device with complete privacy.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Recommendations:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.top, 4)

                Text("• Base: Fast, good for short recordings and quick transcription")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("• Medium: Best balance of speed and accuracy for general use")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("• Large v3 Turbo: Highest accuracy, optimized for speed, best for long or complex audio")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helper Methods

    private func isModelDownloaded() -> Bool {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let modelPath = cachesDirectory
            .appendingPathComponent("mlx-models")
            .appendingPathComponent(selectedModel.rawValue)
            .appendingPathComponent("config.json")

        return FileManager.default.fileExists(atPath: modelPath.path)
    }

    private func saveConfiguration() {
        UserDefaults.standard.set(selectedModel.rawValue, forKey: "mlxWhisperModelName")
        UserDefaults.standard.set(true, forKey: "enableMLXWhisper")

        print("✅ MLX Whisper configuration saved - Model: \(selectedModel.displayName)")
    }

    private func downloadModel() {
        Task { @MainActor in
            isDownloading = true
            errorMessage = ""

            do {
                // Create MLX Whisper service for download
                let config = MLXWhisperConfig(
                    modelName: selectedModel.rawValue,
                    huggingFaceRepoId: selectedModel.huggingFaceRepoId
                )

                let service = MLXWhisperService(config: config)
                try await service.downloadModel()

                isDownloading = false
                print("✅ Whisper model downloaded successfully")

            } catch {
                errorMessage = "Failed to download model: \(error.localizedDescription)"
                showingError = true
                isDownloading = false

                print("❌ Whisper model download failed: \(error)")
            }
        }
    }

    private func deleteModel() {
        do {
            let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let modelPath = cachesDirectory
                .appendingPathComponent("mlx-models")
                .appendingPathComponent(selectedModel.rawValue)

            if FileManager.default.fileExists(atPath: modelPath.path) {
                try FileManager.default.removeItem(at: modelPath)
                print("✅ Whisper model deleted successfully")
            }

        } catch {
            errorMessage = "Failed to delete model: \(error.localizedDescription)"
            showingError = true
            print("❌ Whisper model deletion failed: \(error)")
        }
    }
}

#Preview {
    MLXWhisperSettingsView()
}
