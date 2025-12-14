//
//  OnDeviceLLMSettingsView.swift
//  BisonNotes AI
//
//  Settings view for on-device LLM configuration and model management
//

import SwiftUI

struct OnDeviceLLMSettingsView: View {
    @AppStorage(OnDeviceLLMSettingsKeys.enableOnDeviceLLM) private var isEnabled: Bool = false
    @AppStorage(OnDeviceLLMSettingsKeys.modelID) private var selectedModelID: String = OnDeviceLLMModel.medGemma4B.id
    @AppStorage(OnDeviceLLMSettingsKeys.quantization) private var selectedQuantization: String = OnDeviceLLMQuantization.q4_K_M.rawValue
    @AppStorage(OnDeviceLLMSettingsKeys.temperature) private var temperature: Double = 0.1
    @AppStorage(OnDeviceLLMSettingsKeys.maxTokens) private var maxTokens: Int = 2048
    @AppStorage(OnDeviceLLMSettingsKeys.allowCellularDownload) private var allowCellularDownload: Bool = false

    var onConfigurationChanged: (() -> Void)?

    @StateObject private var downloadManager = ModelDownloadManager.shared
    @StateObject private var llmService = OnDeviceLLMService.shared

    @State private var showingDeleteConfirmation = false
    @State private var modelToDelete: (OnDeviceLLMModel, OnDeviceLLMQuantization)?
    @State private var showingCellularWarning = false
    @State private var pendingDownload: (OnDeviceLLMModel, OnDeviceLLMQuantization)?

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
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    if let (model, quantization) = modelToDelete {
                        deleteModel(model, quantization: quantization)
                    }
                }
            } message: {
                if let (model, quantization) = modelToDelete {
                    Text("Delete \(model.displayName) (\(quantization.rawValue))? This will free up \(quantization.estimatedSizeGB, specifier: "%.1f") GB of storage.")
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
                            UserDefaults.standard.set(true, forKey: OnDeviceLLMSettingsKeys.enableOnDeviceLLM)
                        }
                        onConfigurationChanged?()
                    }
            }
        }
    }

    // MARK: - Model Selection Section

    private var modelSelectionSection: some View {
        Section(header: Text("Model")) {
            ForEach(OnDeviceLLMModel.allModels) { model in
                VStack(alignment: .leading, spacing: 8) {
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
                        }
                    }

                    HStack(spacing: 16) {
                        Label(model.parameters, systemImage: "cpu")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Label("\(model.contextWindow / 1000)K context", systemImage: "text.alignleft")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        if model.specialization == .medical {
                            Label("Medical", systemImage: "cross.case.fill")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedModelID = model.id
                    onConfigurationChanged?()
                }
            }

            // Quantization picker
            if let model = selectedModel {
                Picker("Quality Level", selection: $selectedQuantization) {
                    ForEach(model.quantizations, id: \.rawValue) { quant in
                        VStack(alignment: .leading) {
                            Text(quant.displayName)
                            Text("\(quant.estimatedSizeGB, specifier: "%.1f") GB")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(quant.rawValue)
                    }
                }
                .onChange(of: selectedQuantization) { _, _ in
                    onConfigurationChanged?()
                }
            }
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
                    Text("\(quantization.estimatedSizeGB, specifier: "%.1f") GB - \(quantization.displayName)")
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
                Text("\(quantization.estimatedSizeGB * progress, specifier: "%.1f") GB of \(quantization.estimatedSizeGB, specifier: "%.1f") GB")
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
                    showingDeleteConfirmation = true
                    modelToDelete = nil
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
                Text("MedGemma")
                    .font(.headline)

                Text("MedGemma is Google's medical-specialized language model, optimized for healthcare applications. It excels at understanding medical terminology, clinical notes, and health-related content.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Text("Device Requirements")
                    .font(.subheadline)
                    .fontWeight(.medium)

                VStack(alignment: .leading, spacing: 4) {
                    Label("iPhone 12 or newer recommended", systemImage: "iphone")
                    Label("~3.5 GB RAM required during inference", systemImage: "memorychip")
                    Label("~2.5 GB storage for model files", systemImage: "internaldrive")
                }
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
                print("Download error: \(error)")
            }
        }
    }

    private func deleteModel(_ model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization) {
        do {
            try downloadManager.deleteModel(model, quantization: quantization)
            onConfigurationChanged?()
        } catch {
            print("Delete error: \(error)")
        }
    }
}

#Preview {
    OnDeviceLLMSettingsView()
}
