//
//  OnDeviceLLMDownloadManager.swift
//  BisonNotes AI
//
//  Manages downloading LLM models from Hugging Face with progress tracking
//  Adapted from OLMoE.swift project
//

import Foundation
import Combine
import Network

// MARK: - Download Manager

/// Singleton manager for downloading and managing on-device LLM models
@MainActor
public class OnDeviceLLMDownloadManager: NSObject, ObservableObject {

    // MARK: - Singleton

    public static let shared = OnDeviceLLMDownloadManager()

    // MARK: - Published Properties

    @Published public var downloadProgress: Float = 0
    @Published public var isDownloading = false
    @Published public var downloadError: String?
    @Published public var isModelReady = false
    @Published public var downloadedSize: Int64 = 0
    @Published public var totalSize: Int64 = 0
    @Published public var selectedModel: OnDeviceLLMModelInfo = OnDeviceLLMModelInfo.granite4Micro // Default, will be updated in init
    @Published public var currentlyDownloadingModel: OnDeviceLLMModelInfo?
    @Published public var downloadSpeed: Double = 0 // bytes per second

    // MARK: - Private Properties

    private var networkMonitor: NWPathMonitor?
    private var downloadSession: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var lastUpdateTime: Date = Date()
    private var lastBytesWritten: Int64 = 0
    private var hasCheckedDiskSpace = false
    private let updateInterval: TimeInterval = 0.5
    private var lastDispatchedBytesWritten: Int64 = 0

    // MARK: - Initialization

    private override init() {
        super.init()

        // Use foreground session for faster downloads
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200 // 2 hours for large model downloads
        config.waitsForConnectivity = true
        downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        startNetworkMonitoring()
        
        // Initialize selectedModel from UserDefaults without triggering migration
        // Check UserDefaults directly first to avoid accessing selectedModel computed property
        if let savedModelId = UserDefaults.standard.string(forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId),
           let model = OnDeviceLLMModelInfo.model(withId: savedModelId) {
            selectedModel = model
            isModelReady = model.isDownloaded
        } else {
            // Use Granite Micro as default (recommended for 6GB+ devices)
            // Don't use defaultSummarizationModel as it might access availableModels
            let deviceRAM = DeviceCapabilities.totalRAMInGB
            if deviceRAM >= 8.0 {
                selectedModel = OnDeviceLLMModelInfo.granite4H
            } else if deviceRAM >= 6.0 {
                selectedModel = OnDeviceLLMModelInfo.granite4Micro
            } else {
                selectedModel = OnDeviceLLMModelInfo.granite4Micro // Fallback
            }
            isModelReady = selectedModel.isDownloaded
        }
        
        // Don't call refreshModelStatus() here - it's safe to call explicitly when needed
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                if path.status == .unsatisfied {
                    self?.downloadError = "Connection lost. Please check your internet connection."
                    self?.isDownloading = false
                    self?.hasCheckedDiskSpace = false
                    self?.isModelReady = false
                    self?.lastDispatchedBytesWritten = 0
                    self?.downloadTask?.cancel()
                }
            }
        }

        let queue = DispatchQueue(label: "OnDeviceLLMNetworkMonitor")
        networkMonitor?.start(queue: queue)
    }

    // MARK: - Download Methods

    /// Start downloading a specific model
    public func startDownload(for model: OnDeviceLLMModelInfo? = nil) {
        // Check network
        if networkMonitor?.currentPath.status == .unsatisfied {
            downloadError = "No network connection available. Please check your internet connection."
            return
        }

        let modelToDownload = model ?? selectedModel
        guard let url = URL(string: modelToDownload.downloadURL) else {
            downloadError = "Invalid download URL for \(modelToDownload.displayName)"
            return
        }

        print("[OnDeviceLLM] Starting download for \(modelToDownload.displayName)")
        print("[OnDeviceLLM] URL: \(url)")

        // Cancel any existing download
        downloadTask?.cancel()

        // Reset state
        currentlyDownloadingModel = modelToDownload
        isDownloading = true
        downloadError = nil
        downloadedSize = 0
        totalSize = 0
        downloadProgress = 0
        downloadSpeed = 0
        lastDispatchedBytesWritten = 0
        lastBytesWritten = 0
        hasCheckedDiskSpace = false

        // Store model ID for synchronous retrieval in delegate
        UserDefaults.standard.set(modelToDownload.id, forKey: "currentlyDownloadingModelId")

        // Create request with proper headers
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        downloadTask = downloadSession.downloadTask(with: request)
        downloadTask?.resume()

        print("[OnDeviceLLM] Download task started")
    }

    /// Cancel the current download
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        currentlyDownloadingModel = nil
        downloadProgress = 0
        downloadedSize = 0
        totalSize = 0
        downloadSpeed = 0

        // Clean up stored model ID
        UserDefaults.standard.removeObject(forKey: "currentlyDownloadingModelId")

        print("[OnDeviceLLM] Download cancelled")
    }

    /// Delete a downloaded model
    public func deleteModel(_ model: OnDeviceLLMModelInfo? = nil) {
        let modelToDelete = model ?? selectedModel

        do {
            if FileManager.default.fileExists(atPath: modelToDelete.fileURL.path) {
                try FileManager.default.removeItem(at: modelToDelete.fileURL)
                print("[OnDeviceLLM] Deleted model: \(modelToDelete.displayName)")
            }

            // Update state
            refreshModelStatus()

        } catch {
            downloadError = "Failed to delete model: \(error.localizedDescription)"
        }
    }

    /// Select a model (must be already downloaded)
    public func selectModel(_ model: OnDeviceLLMModelInfo) {
        // Always set the model, even if not downloaded yet (for download preparation)
        selectedModel = model
        UserDefaults.standard.set(model.id, forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId)
        // Only set isModelReady if the model is actually downloaded
        isModelReady = model.isDownloaded
    }

    /// Refresh the status of all models
    public func refreshModelStatus() {
        // First, check UserDefaults directly to avoid triggering migration in selectedModel
        let savedModelId = UserDefaults.standard.string(forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId)
        
        // If we have a saved model ID, check if that model is downloaded
        if let modelId = savedModelId, let model = OnDeviceLLMModelInfo.model(withId: modelId) {
            if model.isDownloaded {
                selectedModel = model
                isModelReady = true
                return
            }
        }
        
        // If saved model is not downloaded, check if any model is downloaded
        if let availableModel = OnDeviceLLMModelInfo.allModels.first(where: { $0.isDownloaded }) {
            selectedModel = availableModel
            UserDefaults.standard.set(availableModel.id, forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId)
            isModelReady = true
        } else {
            // No models downloaded - use the currently selected model's status
            isModelReady = selectedModel.isDownloaded
        }
    }

    /// Get list of downloaded models
    public var downloadedModels: [OnDeviceLLMModelInfo] {
        OnDeviceLLMModelInfo.allModels.filter { $0.isDownloaded }
    }

    // MARK: - Private Helpers

    private func hasEnoughDiskSpace(requiredSpace: Int64) -> Bool {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let availableCapacity = values.volumeAvailableCapacityForImportantUsage {
                // Require 20% extra space for safety
                let requiredWithBuffer = Int64(Double(requiredSpace) * 1.2)
                return availableCapacity > requiredWithBuffer
            }
        } catch {
            print("[OnDeviceLLM] Error checking disk space: \(error)")
        }
        return false
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

// MARK: - URLSessionDownloadDelegate

extension OnDeviceLLMDownloadManager: URLSessionDownloadDelegate {

    public nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // CRITICAL: Must move file SYNCHRONOUSLY before this method returns
        // or the temp file will be deleted by URLSession

        // Local helper to format file size
        func formatSize(_ size: Int64) -> String {
            let sizeInGB = Double(size) / 1_000_000_000.0
            if sizeInGB >= 1.0 {
                return String(format: "%.2f GB", sizeInGB)
            } else {
                let sizeInMB = Double(size) / 1_000_000.0
                return String(format: "%.0f MB", sizeInMB)
            }
        }

        let fileManager = FileManager.default

        // Get model info (needs to be read synchronously before any async work)
        let modelId = UserDefaults.standard.string(forKey: "currentlyDownloadingModelId")
        let model = OnDeviceLLMModelInfo.allModels.first(where: { $0.id == modelId }) ?? OnDeviceLLMModelInfo.defaultSummarizationModel
        let destination = model.fileURL

        print("[OnDeviceLLM] Download finished! Temp location: \(location)")
        print("[OnDeviceLLM] Moving to: \(destination)")

        var moveError: Error?

        do {
            // Ensure models directory exists
            let modelsDir = URL.onDeviceLLMModelsDirectory
            if !fileManager.fileExists(atPath: modelsDir.path) {
                try fileManager.createDirectory(
                    at: modelsDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                print("[OnDeviceLLM] Created models directory: \(modelsDir.path)")
            }

            // Remove existing file if present
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
                print("[OnDeviceLLM] Removed existing file")
            }

            // Move downloaded file to destination (MUST be synchronous)
            try fileManager.moveItem(at: location, to: destination)

            // Verify file was saved
            let fileSize = try fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int64 ?? 0
            print("[OnDeviceLLM] File saved successfully. Size: \(formatSize(fileSize))")

        } catch {
            print("[OnDeviceLLM] Failed to save file: \(error)")
            moveError = error
        }

        // Update UI state on main actor after file is safely moved
        Task { @MainActor in
            // Clean up temp UserDefaults key
            UserDefaults.standard.removeObject(forKey: "currentlyDownloadingModelId")

            if let error = moveError {
                downloadError = "Failed to save model: \(error.localizedDescription)"
                isDownloading = false
                currentlyDownloadingModel = nil
            } else {
                selectedModel = model
                UserDefaults.standard.set(model.id, forKey: OnDeviceLLMModelInfo.SettingsKeys.selectedModelId)
                isModelReady = true
                isDownloading = false
                currentlyDownloadingModel = nil
                downloadProgress = 1.0
            }
        }
    }

    public nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            print("[OnDeviceLLM] Task completed. Error: \(error?.localizedDescription ?? "none")")

            if let httpResponse = task.response as? HTTPURLResponse {
                print("[OnDeviceLLM] HTTP Status: \(httpResponse.statusCode)")
                if httpResponse.statusCode != 200 {
                    downloadError = "Server returned status \(httpResponse.statusCode)"
                    isDownloading = false
                    hasCheckedDiskSpace = false
                    currentlyDownloadingModel = nil
                    return
                }
            }

            if let error = error {
                if downloadError == nil {
                    downloadError = "Download failed: \(error.localizedDescription)"
                }
                isDownloading = false
                hasCheckedDiskSpace = false
                currentlyDownloadingModel = nil
            }
        }
    }

    public nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            // Check disk space on first update
            if !hasCheckedDiskSpace {
                hasCheckedDiskSpace = true
                if !hasEnoughDiskSpace(requiredSpace: totalBytesExpectedToWrite) {
                    downloadError = "Not enough disk space. Need \(formatSize(totalBytesExpectedToWrite)) free."
                    downloadTask.cancel()
                    return
                }
            }

            let currentTime = Date()
            guard currentTime.timeIntervalSince(lastUpdateTime) >= updateInterval else { return }

            // Calculate download speed
            let timeDelta = currentTime.timeIntervalSince(lastUpdateTime)
            let bytesDelta = totalBytesWritten - lastBytesWritten
            if timeDelta > 0 {
                downloadSpeed = Double(bytesDelta) / timeDelta
            }

            lastUpdateTime = currentTime
            lastBytesWritten = totalBytesWritten

            guard totalBytesWritten > lastDispatchedBytesWritten else { return }
            lastDispatchedBytesWritten = totalBytesWritten

            downloadProgress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
            downloadedSize = totalBytesWritten
            totalSize = totalBytesExpectedToWrite
        }
    }

    public nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        print("[OnDeviceLLM] Redirect to: \(request.url?.absoluteString ?? "unknown")")
        completionHandler(request)
    }

    public nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - Download Speed Formatting

extension OnDeviceLLMDownloadManager {

    /// Format download speed for display
    public var formattedDownloadSpeed: String {
        if downloadSpeed >= 1_000_000 {
            return String(format: "%.1f MB/s", downloadSpeed / 1_000_000)
        } else if downloadSpeed >= 1_000 {
            return String(format: "%.0f KB/s", downloadSpeed / 1_000)
        } else {
            return String(format: "%.0f B/s", downloadSpeed)
        }
    }

    /// Estimated time remaining
    public var estimatedTimeRemaining: String? {
        guard downloadSpeed > 0, totalSize > downloadedSize else { return nil }
        let remainingBytes = totalSize - downloadedSize
        let secondsRemaining = Double(remainingBytes) / downloadSpeed

        if secondsRemaining < 60 {
            return "Less than a minute"
        } else if secondsRemaining < 3600 {
            let minutes = Int(secondsRemaining / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") remaining"
        } else {
            let hours = Int(secondsRemaining / 3600)
            let minutes = Int((secondsRemaining.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m remaining"
        }
    }
}
