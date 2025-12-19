//
//  MLXSettingsView.swift
//  BisonNotes AI
//
//  Configuration view for MLX local on-device models
//

import SwiftUI

struct MLXSettingsView: View {
    @StateObject private var mlxService: MLXService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedModel: MLXModel = .qwen317B4bit
    @State private var maxTokens: Int = 1024
    @State private var maxContext: Int = 8192
    @State private var temperature: Float = 0.1
    @State private var topP: Float = 0.9
    @State private var showAdvancedSettings = false
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0.0
    @State private var showingDeleteConfirmation = false
    @State private var showingError = false
    @State private var errorMessage = ""

    var onConfigurationChanged: (() -> Void)?

    init(onConfigurationChanged: (() -> Void)? = nil) {
        self.onConfigurationChanged = onConfigurationChanged

        // Initialize with current settings
        let modelString = UserDefaults.standard.string(forKey: "mlxModelName") ?? MLXModel.qwen317B4bit.rawValue
        let model = MLXModel(rawValue: modelString) ?? .qwen317B4bit

        // Calculate intelligent defaults based on device RAM and model
        let defaultMaxContext = Self.calculateDefaultMaxContext(for: model)

        let config = MLXConfig(
            modelName: model.rawValue,
            huggingFaceRepoId: model.huggingFaceRepoId,
            maxTokens: UserDefaults.standard.integer(forKey: "mlxMaxTokens") > 0 ?
                UserDefaults.standard.integer(forKey: "mlxMaxTokens") : 1024, // Reduced from 2048 for better memory efficiency
            temperature: UserDefaults.standard.float(forKey: "mlxTemperature") > 0 ?
                UserDefaults.standard.float(forKey: "mlxTemperature") : 0.1,
            topP: UserDefaults.standard.float(forKey: "mlxTopP") > 0 ?
                UserDefaults.standard.float(forKey: "mlxTopP") : 0.9
        )

        _mlxService = StateObject(wrappedValue: MLXService(config: config))
        _selectedModel = State(initialValue: model)
        _maxTokens = State(initialValue: config.maxTokens)
        _maxContext = State(initialValue: UserDefaults.standard.integer(forKey: "mlxMaxContext") > 0 ?
            UserDefaults.standard.integer(forKey: "mlxMaxContext") : defaultMaxContext)
        _temperature = State(initialValue: config.temperature)
        _topP = State(initialValue: config.topP)
    }

    /// Calculate intelligent max context based on device RAM and model size
    private static func calculateDefaultMaxContext(for model: MLXModel) -> Int {
        let deviceRAM = DeviceCapabilities.totalRAMInGB

        switch model {
        case .qwen317B4bit:
            // 1.7B model - ultra-compact
            if deviceRAM >= 8.0 {
                return 16384 // 16K context for 8GB+ devices
            } else if deviceRAM >= 6.0 {
                return 12288 // 12K context for 6GB devices
            } else {
                return 8192  // 8K context for 4GB devices
            }

        case .gemma34B4bitDWQ, .qwen34B4bit2507:
            // 4B models
            if deviceRAM >= 8.0 {
                return 16384 // 16K context for 8GB+ devices
            } else if deviceRAM >= 6.0 {
                return 8192  // 8K context for 6GB devices
            } else {
                return 4096  // 4K context for lower RAM
            }

        case .qwen38B4bit:
            // 8B model (requires 8GB+ RAM anyway)
            if deviceRAM >= 12.0 {
                return 16384 // 16K context for 12GB+ devices
            } else {
                return 8192  // 8K context for 8GB devices
            }
        }
    }

    var body: some View {
        NavigationView {
            Form {
                modelSelectionSection
                modelStatusSection
                parametersSection
                modelManagementSection
            }
            .navigationTitle("Local MLX Settings")
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
                        onConfigurationChanged?()
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
                Text("Choose a model optimized for on-device inference")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)

            Picker("Model", selection: $selectedModel) {
                ForEach(MLXModel.availableModels, id: \.self) { model in
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
                Text("Gemma 3 4B provides the best reasoning quality. Qwen 3 4B is faster for quick tasks. Qwen 3 8B offers the highest quality for devices with 8GB+ RAM.")
                    .font(.caption)

                if !DeviceCapabilities.supports8GBModels {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                        Text("Qwen 3 8B requires 8GB+ RAM. Your device has \(DeviceCapabilities.ramDescription). Gemma 3 4B and Qwen 3 4B models are available.")
                            .font(.caption)
                    }
                    .foregroundColor(.orange)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var modelStatusSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model: \(selectedModel.displayName)")
                        .font(.body)
                        .fontWeight(.medium)

                    Text("Size: \(selectedModel.estimatedSize)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if mlxService.isModelDownloaded() {
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

                    if mlxService.isModelLoaded {
                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                                .foregroundColor(.blue)
                            Text("Loaded in Memory")
                                .font(.caption)
                                .foregroundColor(.blue)
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

    private var parametersSection: some View {
        Section {
            // Advanced Settings Toggle
            Button(action: {
                withAnimation {
                    showAdvancedSettings.toggle()
                }
            }) {
                HStack {
                    Image(systemName: showAdvancedSettings ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Advanced Settings")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)

                        Text("Model parameters - adjust only if you know what you're doing")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if showAdvancedSettings {
                VStack(alignment: .leading, spacing: 16) {
                    // Max Context Window
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Max Context Window")
                                .font(.body)
                            Spacer()
                            Text("\(maxContext)")
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                        }

                        Slider(value: Binding(
                            get: { Double(maxContext) },
                            set: { maxContext = Int($0) }
                        ), in: 2048...32768, step: 2048)

                        Text("Maximum context size for processing. Higher values use more memory. Recommended: \(Self.calculateDefaultMaxContext(for: selectedModel))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Max Output Tokens
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Max Output Tokens")
                                .font(.body)
                            Spacer()
                            Text("\(maxTokens)")
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                        }

                        Slider(value: Binding(
                            get: { Double(maxTokens) },
                            set: { maxTokens = Int($0) }
                        ), in: 512...4096, step: 256)

                        Text("Maximum number of tokens to generate in responses")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Temperature
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Temperature")
                                .font(.body)
                            Spacer()
                            Text(String(format: "%.2f", temperature))
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                        }

                        Slider(value: $temperature, in: 0.0...1.0, step: 0.05)

                        Text("Lower = more focused and deterministic, Higher = more creative")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Top-P
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Top-P (Nucleus Sampling)")
                                .font(.body)
                            Spacer()
                            Text(String(format: "%.2f", topP))
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                        }

                        Slider(value: $topP, in: 0.1...1.0, step: 0.05)

                        Text("Controls diversity. Lower = more focused, Higher = more diverse. Recommended: 0.9")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 8)
            }
        } header: {
            Text("Configuration")
        } footer: {
            if showAdvancedSettings {
                VStack(alignment: .leading, spacing: 4) {
                    Text("⚠️ Advanced users only")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)

                    Text("Defaults are optimized for your device's \(DeviceCapabilities.ramDescription) of RAM. Increasing context window may cause out-of-memory errors on lower-RAM devices.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var modelManagementSection: some View {
        Section {
            if !mlxService.isModelDownloaded() {
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
                Button(action: {
                    loadModel()
                }) {
                    HStack {
                        Image(systemName: "cpu")
                        VStack(alignment: .leading) {
                            Text(mlxService.isModelLoaded ? "Model Loaded" : "Load Model")
                                .font(.body)
                                .fontWeight(.medium)

                            Text("Load model into memory for faster inference")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .disabled(mlxService.isModelLoaded)

                if mlxService.isModelLoaded {
                    Button(action: {
                        unloadModel()
                    }) {
                        HStack {
                            Image(systemName: "xmark.circle")
                            VStack(alignment: .leading) {
                                Text("Unload Model")
                                    .font(.body)
                                    .fontWeight(.medium)

                                Text("Free up memory")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

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
                Text("Models are downloaded from Hugging Face and cached locally. All processing happens on-device with complete privacy.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let cacheDir = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                    let mlxDir = cacheDir.appendingPathComponent("mlx-models")
                    Text("Cache location: \(mlxDir.path)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func saveConfiguration() {
        UserDefaults.standard.set(selectedModel.rawValue, forKey: "mlxModelName")
        UserDefaults.standard.set(maxTokens, forKey: "mlxMaxTokens")
        UserDefaults.standard.set(maxContext, forKey: "mlxMaxContext")
        UserDefaults.standard.set(temperature, forKey: "mlxTemperature")
        UserDefaults.standard.set(topP, forKey: "mlxTopP")
        UserDefaults.standard.set(true, forKey: "enableMLX")

        print("✅ MLX configuration saved - Model: \(selectedModel.displayName), MaxContext: \(maxContext), MaxTokens: \(maxTokens), Temp: \(temperature), TopP: \(topP)")
    }

    private func downloadModel() {
        Task { @MainActor in
            isDownloading = true
            errorMessage = ""

            do {
                // Save configuration BEFORE downloading so the new model is persisted
                saveConfiguration()

                // Update service config before downloading
                let config = MLXConfig(
                    modelName: selectedModel.rawValue,
                    huggingFaceRepoId: selectedModel.huggingFaceRepoId,
                    maxTokens: maxTokens,
                    temperature: temperature,
                    topP: 0.9
                )

                let service = MLXService(config: config)
                try await service.downloadModel()

                // Update the main service after successful download
                mlxService.downloadState = .downloaded
                isDownloading = false

                print("✅ Model downloaded successfully")

                // Notify that configuration changed
                onConfigurationChanged?()

            } catch {
                errorMessage = "Failed to download model: \(error.localizedDescription)"
                showingError = true
                isDownloading = false

                print("❌ Model download failed: \(error)")
            }
        }
    }

    private func loadModel() {
        Task { @MainActor in
            do {
                try await mlxService.loadModel()
                print("✅ Model loaded successfully")
            } catch {
                errorMessage = "Failed to load model: \(error.localizedDescription)"
                showingError = true
                print("❌ Model loading failed: \(error)")
            }
        }
    }

    private func unloadModel() {
        mlxService.unloadModel()
        print("✅ Model unloaded")
    }

    private func deleteModel() {
        do {
            try mlxService.deleteModel()
            print("✅ Model deleted successfully")
        } catch {
            errorMessage = "Failed to delete model: \(error.localizedDescription)"
            showingError = true
            print("❌ Model deletion failed: \(error)")
        }
    }
}

#Preview {
    MLXSettingsView()
}
