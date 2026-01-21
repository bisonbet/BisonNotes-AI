//
//  WhisperKitSettingsView.swift
//  BisonNotes AI
//
//  Settings view for WhisperKit on-device transcription configuration
//

import SwiftUI
import WhisperKit
import CoreML

// MARK: - WhisperKit Settings View

struct WhisperKitSettingsView: View {

    // MARK: - State

    @Environment(\.dismiss) private var dismiss

    @AppStorage(WhisperKitModelInfo.SettingsKeys.enableWhisperKit) private var isEnabled = false
    @AppStorage(WhisperKitModelInfo.SettingsKeys.selectedModelId) private var selectedModelId = WhisperKitModelInfo.defaultModel.id

    @StateObject private var manager = WhisperKitManager.shared

    @State private var showingDeleteConfirmation = false
    @State private var isTestingTranscription = false
    @State private var testResult: String?

    // MARK: - Body

    var body: some View {
        let isSupported = DeviceCompatibility.isWhisperKitSupported
        
        return Form {
            // Info Section
            Section {
                if isSupported {
                    Text("High-quality on-device transcription. No internet connection required after model download.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("On-device transcription requires 4GB+ RAM and iOS 17+. Your device does not meet these requirements.")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // Model Section
            Section("Model") {
                Picker("Selected Model", selection: $selectedModelId) {
                    ForEach(WhisperKitModelInfo.allModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .onChange(of: selectedModelId) { oldValue, newValue in
                    manager.refreshModelStatus()
                }
                
                modelInfoView
            }

            // Model Selection Guide Section (moved right after Model section)
            Section("Which Model Should I Use?") {
                modelSelectionGuide
            }

            // Download Progress (if downloading)
            if manager.isDownloading {
                Section("Download Progress") {
                    downloadProgressView
                }
            }

            // Model Status Section
            Section("Status") {
                modelStatusView
            }

            // Test Section
            if manager.isModelReady {
                Section("Test") {
                    testButton
                }
            }
            
            // Info Section
            Section {
                infoView
            }
        }
        .navigationTitle("On Device Transcription")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .alert("Delete Model?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                manager.deleteModel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete the on-device model (~950MB) from your device. You can re-download it later.")
        }
        .onAppear {
            manager.refreshModelStatus()
        }
    }

    // MARK: - Model Info View

    @ViewBuilder
    private var modelInfoView: some View {
        let model = WhisperKitModelInfo.selectedModel
        let isSupported = DeviceCompatibility.isWhisperKitSupported

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

                // Action Button
                modelActionButton(isSupported: isSupported)
            }

            // Model details
            HStack(spacing: 16) {
                Label(model.downloadSize, systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Label("\(Int(model.requiredRAM))GB+ RAM", systemImage: "memorychip")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func modelActionButton(isSupported: Bool) -> some View {
        if !isSupported {
            Image(systemName: "exclamationmark.circle")
                .font(.title2)
                .foregroundColor(.red)
        } else if manager.isModelReady {
            Menu {
                Button {
                    // Unload model from memory to force fresh load
                    manager.unloadModel()
                } label: {
                    Label("Reload Model", systemImage: "arrow.clockwise")
                }
                
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
        } else if manager.isDownloading {
            Button {
                manager.cancelDownload()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.title2)
                    .foregroundColor(.red)
            }
        } else {
            Button {
                Task {
                    try? await manager.downloadModel()
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
        }
    }

    // MARK: - Download Progress View

    @ViewBuilder
    private var downloadProgressView: some View {
        VStack(spacing: 12) {
            Text("Downloading \(WhisperKitModelInfo.selectedModel.displayName)")
                .font(.subheadline)
                .fontWeight(.medium)

            ProgressView(value: Double(max(0.0, min(1.0, manager.downloadProgress))))
                .progressViewStyle(.linear)

            HStack {
                if manager.totalSize > 0 {
                    Text("\(manager.formatSize(manager.downloadedSize)) / \(manager.formatSize(manager.totalSize))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Downloading... \(manager.formatSize(manager.downloadedSize))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if manager.downloadSpeed > 0 {
                    Text(manager.formattedDownloadSpeed)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if manager.downloadedSize > 0 {
                    Text("Calculating...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let timeRemaining = manager.estimatedTimeRemaining {
                Text(timeRemaining)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if !manager.currentStatus.isEmpty {
                Text(manager.currentStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error = manager.downloadError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button("Cancel Download") {
                manager.cancelDownload()
            }
            .foregroundColor(.red)
        }
    }

    // MARK: - Model Status View

    @ViewBuilder
    private var modelStatusView: some View {
        if manager.isModelReady {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading) {
                    Text("Ready")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("On-device transcription is ready")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } else if manager.isDownloading {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                VStack(alignment: .leading) {
                    Text("Downloading...")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Please wait while the model downloads")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } else {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading) {
                    Text("Model Not Downloaded")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Download the model to enable on-device transcription")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Test Button

    @ViewBuilder
    private var testButton: some View {
        Button {
            testTranscription()
        } label: {
            HStack {
                if isTestingTranscription {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Testing...")
                } else {
                    Text("Test Model Loading")
                }
                Spacer()
                if let result = testResult {
                    Image(systemName: result.starts(with: "Success") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(result.starts(with: "Success") ? .green : .red)
                }
            }
        }
        .disabled(isTestingTranscription || !manager.isModelReady)

        if let result = testResult {
            Text(result)
                .font(.caption)
                .foregroundColor(result.starts(with: "Success") ? .green : .red)
        }
    }

    private func testTranscription() {
        isTestingTranscription = true
        testResult = nil

        Task {
            do {
                // Get the saved model path
                guard let modelPath = UserDefaults.standard.string(forKey: WhisperKitModelInfo.SettingsKeys.modelPath) else {
                    testResult = "Error: Model folder path not found. Please re-download the model."
                    isTestingTranscription = false
                    return
                }

                print("[WhisperKit] Test: Starting model load from: \(modelPath)")
                
                // Verify the model folder exists
                guard FileManager.default.fileExists(atPath: modelPath) else {
                    testResult = "Error: Model folder not found at saved path."
                    isTestingTranscription = false
                    return
                }
                
                // Check if model folder has required files
                let contents = try? FileManager.default.contentsOfDirectory(atPath: modelPath)
                print("[WhisperKit] Test: Model folder contents: \(contents?.joined(separator: ", ") ?? "none")")

                // Test by loading the model with a timeout
                let startTime = Date()
                
                print("[WhisperKit] Test: Creating WhisperKitConfig...")
                // Try without prewarm first - prewarm can cause hangs on first load
                let config = WhisperKitConfig(
                    modelFolder: modelPath,
                    verbose: true,  // Enable verbose for debugging
                    prewarm: false,  // Disable prewarm to avoid hanging on first load
                    load: true,
                    download: false
                )
                
                print("[WhisperKit] Test: Initializing WhisperKit (this may take 30+ seconds on first load)...")
                print("[WhisperKit] Test: Note - if you see ANE errors, the model may need to recompile. This can take 1-2 minutes.")
                
                // Use withTimeout to add a timeout wrapper (increased to 120 seconds for first compilation)
                _ = try await withTimeout(seconds: 120) {
                    try await WhisperKit(config)
                }

                let loadTime = Date().timeIntervalSince(startTime)
                print("[WhisperKit] Test: Model loaded successfully in \(loadTime)s")
                testResult = "Success! Model loaded in \(String(format: "%.1f", loadTime))s"
            } catch {
                let errorMessage = error.localizedDescription
                print("[WhisperKit] Test: Error - \(errorMessage)")
                
                // Check for ANE compilation errors
                if errorMessage.contains("ANE model load has failed") || 
                   errorMessage.contains("Must re-compile") ||
                   errorMessage.contains("E5 bundle") {
                    testResult = "Error: Model needs recompilation. Please delete and re-download the model."
                } else if errorMessage.contains("timeout") || errorMessage.contains("timed out") {
                    testResult = "Error: Model loading timed out. First load can take 2-3 minutes for ANE compilation. If ANE errors appear, the model may be incompatible with your device."
                } else if errorMessage.contains("ANE") || errorMessage.contains("E5") || errorMessage.contains("Model file not found") {
                    testResult = "Error: Model files missing or ANE compilation failed. Please delete and re-download the model."
                } else {
                    testResult = "Error: \(errorMessage)"
                }
            }

            isTestingTranscription = false
        }
    }
    
    /// Helper function to add timeout to async operations
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add the actual operation
            group.addTask {
                try await operation()
            }
            
            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "WhisperKitTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation timed out after \(Int(seconds)) seconds"])
            }
            
            // Return the first completed task (either success or timeout)
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Model Selection Guide

    @ViewBuilder
    private var modelSelectionGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            GuideRow(
                useCase: "Voice Notes / Journaling",
                recommendedModel: "Faster Processing",
                reason: "You are close to the mic; audio is clear. Speed is better."
            )
            
            Divider()
            
            GuideRow(
                useCase: "Meeting / Interview",
                recommendedModel: "Higher Quality",
                reason: "Handling multiple voices and distance from the mic requires the extra accuracy."
            )
            
            Divider()
            
            GuideRow(
                useCase: "Noisy Environment",
                recommendedModel: "Higher Quality",
                reason: "Faster Processing will fail to separate voice from noise."
            )
            
            Divider()
            
            GuideRow(
                useCase: "Long Battery Life Needed",
                recommendedModel: "Faster Processing",
                reason: "Higher Quality uses significantly more power per second of audio."
            )
        }
        .padding(.vertical, 4)
    }

    // MARK: - Info View

    @ViewBuilder
    private var infoView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("About On Device Transcription", systemImage: "info.circle")
                .font(.subheadline)
                .fontWeight(.medium)

            Text("On-device transcription provides high-quality speech-to-text entirely on your device. Your audio never leaves your device, ensuring complete privacy.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("The \(WhisperKitModelInfo.selectedModel.displayName) offers the best balance of accuracy and speed for most use cases.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
    }
}

// MARK: - Guide Row

struct GuideRow: View {
    let useCase: String
    let recommendedModel: String
    let reason: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(useCase)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(recommendedModel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(recommendedModel == "Faster Processing" ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
                    .foregroundColor(recommendedModel == "Faster Processing" ? .blue : .green)
                    .cornerRadius(6)
            }
            
            Text(reason)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        WhisperKitSettingsView()
    }
}
