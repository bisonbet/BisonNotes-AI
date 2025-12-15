//
//  OnDeviceLLMSettingsView.swift
//  BisonNotes AI
//
//  Settings view for on-device LLM configuration and model management
//

import SwiftUI

struct OnDeviceLLMSettingsView: View {
    @AppStorage(OnDeviceLLMSettingsKeys.enableOnDeviceLLM) private var isEnabled: Bool = false
    @AppStorage(OnDeviceLLMSettingsKeys.modelID) private var selectedModelID: String = OnDeviceLLMModel.defaultModel.id
    @AppStorage(OnDeviceLLMSettingsKeys.quantization) private var selectedQuantization: String = OnDeviceLLMQuantization.q4_K_M.rawValue
    @AppStorage(OnDeviceLLMSettingsKeys.temperature) private var temperature: Double = 0.1
    @AppStorage(OnDeviceLLMSettingsKeys.maxTokens) private var maxTokens: Int = 2048
    @AppStorage(OnDeviceLLMSettingsKeys.allowCellularDownload) private var allowCellularDownload: Bool = false

    var onConfigurationChanged: (() -> Void)?

    @StateObject private var downloadManager = ModelDownloadManager.shared
    @StateObject private var llmService = OnDeviceLLMService.shared

    @State private var showingDeleteConfirmation = false
    @State private var modelToDelete: (OnDeviceLLMModel, OnDeviceLLMQuantization)?
    @State private var isDeletingAllModels = false
    @State private var showingCellularWarning = false
    @State private var pendingDownload: (OnDeviceLLMModel, OnDeviceLLMQuantization)?
    @State private var showingErrorAlert = false
    @State private var errorMessage = ""
    @State private var showingInsufficientRAMAlert = false
    @State private var showingSuccessAlert = false
    @State private var successMessage = ""

    @Environment(\.dismiss) private var dismiss

    private var selectedModel: OnDeviceLLMModel? {
        OnDeviceLLMModel.model(byID: selectedModelID)
    }

    private var currentQuantization: OnDeviceLLMQuantization {
        OnDeviceLLMQuantization(rawValue: selectedQuantization) ?? .q4_K_M
    }

    var body: some View {
        NavigationView {
            Form {
                headerSection
                deviceCapabilitySection
                modelSelectionSection
                downloadSection
                storageSection
                advancedSettingsSection
                helpSection
            }
            .navigationTitle("On-Device LLM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        UserDefaults.standard.synchronize()
                        onConfigurationChanged?()
                        dismiss()
                    }
                }
            }
            .alert("Delete Model?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    isDeletingAllModels = false
                }
                Button("Delete", role: .destructive) {
                    if let (model, quantization) = modelToDelete {
                        deleteModel(model, quantization: quantization)
                    } else if isDeletingAllModels {
                        deleteAllModels()
                    }
                    isDeletingAllModels = false
                }
            } message: {
                if let (model, quantization) = modelToDelete {
                    Text("Delete \(model.displayName) (\(quantization.rawValue))? This will free up \(model.estimatedSizeGB, specifier: "%.1f") GB of storage.")
                } else if isDeletingAllModels {
                    Text("Delete all downloaded models? This will free up \(downloadManager.formatStorageSize(downloadManager.totalStorageUsed)).")
                }
            }
            .alert("Cellular Download", isPresented: $showingCellularWarning) {
                Button("Cancel", role: .cancel) {
                    pendingDownload = nil
                }
                Button("Download Anyway") {
                    if let (model, quantization) = pendingDownload {
                        startDownload(model, quantization: quantization, allowCellular: true)
                    }
                    pendingDownload = nil
                }
                Button("Enable Cellular Downloads") {
                    allowCellularDownload = true
                    if let (model, quantization) = pendingDownload {
                        startDownload(model, quantization: quantization, allowCellular: true)
                    }
                    pendingDownload = nil
                }
            } message: {
                Text("You're not connected to WiFi. Downloading will use cellular data (~2.5 GB). Continue?")
            }
            .alert("Error", isPresented: $showingErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
            .alert("Insufficient Device Memory", isPresented: $showingInsufficientRAMAlert) {
                Button("OK", role: .cancel) {
                    // Turn off the toggle if they acknowledged the error
                    isEnabled = false
                }
            } message: {
                Text(DeviceCapability.insufficientMemoryMessage)
            }
            .alert("Success", isPresented: $showingSuccessAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(successMessage)
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "brain")
                        .foregroundColor(.purple)
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("On-Device AI")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Run AI models directly on your device - completely private, no internet required")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Complete Privacy", systemImage: "lock.shield.fill")
                        .font(.caption)
                        .foregroundColor(.green)

                    Text("All processing happens on your device. Your data never leaves your phone.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)

                Toggle("Enable On-Device LLM", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        if newValue {
                            // Check if device has sufficient RAM before enabling
                            if !DeviceCapability.canSupportOnDeviceLLM {
                                showingInsufficientRAMAlert = true
                                return
                            }
                            UserDefaults.standard.set(true, forKey: OnDeviceLLMSettingsKeys.enableOnDeviceLLM)
                        }
                        onConfigurationChanged?()
                    }
            }
        }
    }

    // MARK: - Device Capability Section

    private var deviceCapabilitySection: some View {
        Section(header: Text("Device Compatibility")) {
            if DeviceCapability.canSupportOnDeviceLLM {
                // Device supports on-device LLM
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(DeviceCapability.memoryDescription)
                            .font(.body)
                            .fontWeight(.medium)
                        Text("Your device supports on-device AI models")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            } else {
                // Device does NOT support on-device LLM
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(DeviceCapability.memoryDescription)
                            .font(.body)
                            .fontWeight(.medium)
                        Text("Requires 6GB+ RAM")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("On-Device LLM Not Available")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text("Your device does not have enough RAM for on-device AI models. This feature requires:\n\n• iPhone 14 Pro or newer\n• iPhone 15 or newer\n• iPad Pro with M1 chip or newer\n• At least 6GB of RAM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Model Selection Section

    private var modelSelectionSection: some View {
        Section(header: Text("Model Selection")) {
            ForEach(OnDeviceLLMModel.allModels) { model in
                VStack(alignment: .leading, spacing: 12) {
                    // Header with name and selection indicator
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.displayName)
                                .font(.headline)

                            Text(model.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        if model.id == selectedModelID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue)
                                .font(.title3)
                        }
                    }

                    // Ratings Grid
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Size")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            HStack(spacing: 2) {
                                Text(String(format: "%.1f GB", model.estimatedSizeGB))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Speed")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            HStack(spacing: 2) {
                                ForEach(1...5, id: \.self) { index in
                                    Image(systemName: index <= model.speedRating ? "bolt.fill" : "bolt")
                                        .font(.caption2)
                                        .foregroundColor(index <= model.speedRating ? .green : .gray.opacity(0.3))
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Quality")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            HStack(spacing: 2) {
                                ForEach(1...5, id: \.self) { index in
                                    Image(systemName: index <= model.qualityRating ? "star.fill" : "star")
                                        .font(.caption2)
                                        .foregroundColor(index <= model.qualityRating ? .yellow : .gray.opacity(0.3))
                                }
                            }
                        }
                    }

                    // Pros and Cons
                    VStack(alignment: .leading, spacing: 8) {
                        // Pros
                        if !model.pros.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Pros:")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.green)
                                ForEach(model.pros, id: \.self) { pro in
                                    HStack(alignment: .top, spacing: 4) {
                                        Text("•")
                                            .foregroundColor(.green)
                                        Text(pro)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }

                        // Cons
                        if !model.cons.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Cons:")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.orange)
                                ForEach(model.cons, id: \.self) { con in
                                    HStack(alignment: .top, spacing: 4) {
                                        Text("•")
                                            .foregroundColor(.orange)
                                        Text(con)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    // Technical specs
                    HStack(spacing: 16) {
                        Label(model.parameters, systemImage: "cpu")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Label("\(model.contextWindow / 1000)K context", systemImage: "text.alignleft")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Label(String(format: "~%.1f GB RAM", model.memoryUsageGB), systemImage: "memorychip")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedModelID = model.id
                    onConfigurationChanged?()
                }

                if model.id != OnDeviceLLMModel.allModels.last?.id {
                    Divider()
                }
            }

            // Quantization info (Q4_K_M only)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "gearshape.2.fill")
                        .foregroundColor(.blue)
                        .font(.caption)
                    Text("Quantization: Q4_K_M")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                Text("Optimal balance of quality and memory usage for mobile devices. All models use 4-bit quantization.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Download Section

    private var downloadSection: some View {
        Section(header: Text("Model Download")) {
            if let model = selectedModel {
                let state = downloadManager.downloadState(for: model, quantization: currentQuantization)

                switch state {
                case .notDownloaded:
                    downloadButton(for: model, quantization: currentQuantization)

                case .downloading(let progress):
                    downloadProgressView(for: model, quantization: currentQuantization, progress: progress)

                case .downloaded(let downloadedModel):
                    downloadedView(for: model, downloadedModel: downloadedModel)

                case .failed(let error):
                    failedView(for: model, quantization: currentQuantization, error: error)

                case .paused(let progress):
                    pausedView(for: model, quantization: currentQuantization, progress: progress)
                }
            }

            // Network status
            HStack {
                Image(systemName: downloadManager.isOnWiFi ? "wifi" : "antenna.radiowaves.left.and.right")
                    .foregroundColor(downloadManager.isOnWiFi ? .green : .orange)
                Text(downloadManager.networkStatusDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Cellular download toggle
            Toggle("Allow Cellular Downloads", isOn: $allowCellularDownload)
                .onChange(of: allowCellularDownload) { _, _ in
                    onConfigurationChanged?()
                }

            if !allowCellularDownload && !downloadManager.isOnWiFi {
                Text("Connect to WiFi to download models, or enable cellular downloads above.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    private func downloadButton(for model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization) -> some View {
        Button(action: {
            handleDownloadTap(model: model, quantization: quantization)
        }) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)

                VStack(alignment: .leading) {
                    Text("Download \(model.displayName)")
                        .font(.body)
                    Text("\(model.estimatedSizeGB, specifier: "%.1f") GB - \(quantization.displayName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func downloadProgressView(for model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloading \(model.displayName)...")
                    .font(.body)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ProgressView(value: progress)
                .progressViewStyle(LinearProgressViewStyle())

            HStack {
                Text("\(model.estimatedSizeGB * progress, specifier: "%.1f") GB of \(model.estimatedSizeGB, specifier: "%.1f") GB")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Cancel") {
                    downloadManager.cancelDownload(for: model, quantization: quantization)
                }
                .font(.caption)
                .foregroundColor(.red)
            }
        }
    }

    private func downloadedView(for model: OnDeviceLLMModel, downloadedModel: DownloadedModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)

                VStack(alignment: .leading) {
                    Text("\(model.displayName) Ready")
                        .font(.body)
                        .fontWeight(.medium)
                    Text(downloadedModel.fileSizeFormatted)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    modelToDelete = (model, downloadedModel.quantization)
                    showingDeleteConfirmation = true
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }

            if llmService.isModelLoaded && llmService.currentModelID == model.id {
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Model loaded and ready")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
    }

    private func failedView(for model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization, error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)

                VStack(alignment: .leading) {
                    Text("Download Failed")
                        .font(.body)
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Button("Retry Download") {
                handleDownloadTap(model: model, quantization: quantization)
            }
            .font(.caption)
        }
    }

    private func pausedView(for model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "pause.circle.fill")
                    .foregroundColor(.orange)

                Text("Download Paused - \(Int(progress * 100))%")
                    .font(.body)
            }

            Button("Resume Download") {
                handleDownloadTap(model: model, quantization: quantization)
            }
            .font(.caption)
        }
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        Section(header: Text("Storage")) {
            HStack {
                Text("Models Installed")
                Spacer()
                Text("\(downloadManager.downloadedModels.count)")
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Storage Used")
                Spacer()
                Text(downloadManager.formatStorageSize(downloadManager.totalStorageUsed))
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Available Space")
                Spacer()
                Text(downloadManager.formatStorageSize(downloadManager.availableStorageSpace()))
                    .foregroundColor(.secondary)
            }

            if downloadManager.downloadedModels.count > 0 {
                Button(role: .destructive) {
                    // Show confirmation for deleting all
                    modelToDelete = nil  // Clear first to prevent race condition
                    isDeletingAllModels = true
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete All Models", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Advanced Settings Section

    private var advancedSettingsSection: some View {
        Section(header: Text("Advanced Settings")) {
            VStack(alignment: .leading) {
                Text("Temperature: \(temperature, specifier: "%.2f")")
                    .font(.body)
                Slider(value: $temperature, in: 0...1, step: 0.05)
                Text("Lower = more focused, Higher = more creative")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .onChange(of: temperature) { _, _ in
                onConfigurationChanged?()
            }

            Stepper("Max Tokens: \(maxTokens)", value: $maxTokens, in: 512...4096, step: 256)
                .onChange(of: maxTokens) { _, _ in
                    onConfigurationChanged?()
                }
        }
    }

    // MARK: - Help Section

    private var helpSection: some View {
        Section(header: Text("About")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Available Models")
                    .font(.headline)

                Text("**Ministral 3B Reasoning** - Mistral's reasoning-optimized model with 256K context window. Excellent for complex analysis and logical reasoning tasks.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("**Granite 4.0 Micro** - IBM's efficient hybrid transformer with Mamba2 architecture. 128K context, optimized for fast inference on mobile.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("**Qwen3 1.7B** - Compact and efficient 1.7B model. Smaller footprint (~1GB), faster inference, ideal for devices with 6GB RAM. Good for quick summaries.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Text("Device Requirements")
                    .font(.subheadline)
                    .fontWeight(.medium)

                VStack(alignment: .leading, spacing: 4) {
                    Label("6GB+ RAM required (iPhone 14 Pro or newer)", systemImage: "iphone")
                    Label("Q4_K_M quantization only (optimal balance)", systemImage: "gearshape.2")
                    Label("~1-2 GB storage per model", systemImage: "internaldrive")
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Divider()

                Text("Why 6GB RAM?")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("On-device AI models require significant memory during inference. Models need ~3-4GB when loaded (file size + overhead). iOS limits app memory usage, so 6GB+ device RAM ensures stable operation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func handleDownloadTap(model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization) {
        if !downloadManager.isOnWiFi && !allowCellularDownload {
            pendingDownload = (model, quantization)
            showingCellularWarning = true
        } else {
            startDownload(model, quantization: quantization, allowCellular: allowCellularDownload)
        }
    }

    private func startDownload(_ model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization, allowCellular: Bool) {
        Task {
            do {
                try await downloadManager.downloadModel(model, quantization: quantization, allowCellular: allowCellular)
            } catch {
                errorMessage = error.localizedDescription
                showingErrorAlert = true
            }
        }
    }

    private func deleteAllModels() {
        do {
            let modelCount = downloadManager.downloadedModels.count
            let storageFreed = downloadManager.formatStorageSize(downloadManager.totalStorageUsed)
            try downloadManager.deleteAllModels()
            onConfigurationChanged?()

            // Show success feedback for this significant action
            successMessage = "Successfully deleted \(modelCount) model\(modelCount == 1 ? "" : "s"), freeing up \(storageFreed)."
            showingSuccessAlert = true
        } catch {
            errorMessage = "Failed to delete models: \(error.localizedDescription)"
            showingErrorAlert = true
        }
    }

    private func deleteModel(_ model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization) {
        do {
            try downloadManager.deleteModel(model, quantization: quantization)
            onConfigurationChanged?()
        } catch {
            errorMessage = "Failed to delete model: \(error.localizedDescription)"
            showingErrorAlert = true
        }
    }
}

#Preview {
    OnDeviceLLMSettingsView()
}
