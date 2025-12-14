//
//  ModelDownloadManager.swift
//  BisonNotes AI
//
//  Manages downloading, storing, and managing on-device LLM models
//

import Foundation
import Network
import os.log

// MARK: - Model Download Manager

@MainActor
class ModelDownloadManager: NSObject, ObservableObject {
    static let shared = ModelDownloadManager()

    // MARK: - Published Properties

    @Published private(set) var downloadStates: [String: ModelDownloadState] = [:]
    @Published private(set) var downloadedModels: [DownloadedModel] = []
    @Published private(set) var isOnWiFi: Bool = true
    @Published private(set) var totalStorageUsed: Int64 = 0

    // MARK: - Private Properties

    private var backgroundSession: URLSession!
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var downloadCompletionHandlers: [String: (Result<URL, Error>) -> Void] = [:]
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.bisonnotes.networkmonitor")
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.bisonnotes.ai", category: "ModelDownload")

    // MARK: - Storage Paths

    private var modelsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("OnDeviceLLM/Models", isDirectory: true)

        // Create directory if needed
        if !fileManager.fileExists(atPath: modelsDir.path) {
            try? fileManager.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        }

        return modelsDir
    }

    // MARK: - Initialization

    private override init() {
        super.init()
        setupBackgroundSession()
        setupNetworkMonitor()
        loadDownloadedModels()
    }

    private func setupBackgroundSession() {
        let config = URLSessionConfiguration.background(withIdentifier: "com.bisonnotes.modeldownload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true // We control this at the app level
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private func setupNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOnWiFi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            }
        }
        networkMonitor.start(queue: monitorQueue)
    }

    // MARK: - Public Methods

    /// Get the download state for a specific model/quantization combo
    func downloadState(for model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization) -> ModelDownloadState {
        let key = downloadKey(model: model, quantization: quantization)
        return downloadStates[key] ?? .notDownloaded
    }

    /// Check if a model is downloaded
    func isModelDownloaded(_ model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization) -> Bool {
        let key = downloadKey(model: model, quantization: quantization)
        if case .downloaded = downloadStates[key] {
            return true
        }
        return false
    }

    /// Get the file path for a downloaded model
    func modelFilePath(for model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization) -> URL? {
        let key = downloadKey(model: model, quantization: quantization)
        if case .downloaded(let downloadedModel) = downloadStates[key] {
            return URL(fileURLWithPath: downloadedModel.filePath)
        }
        return nil
    }

    /// Start downloading a model
    func downloadModel(
        _ model: OnDeviceLLMModel,
        quantization: OnDeviceLLMQuantization,
        allowCellular: Bool = false
    ) async throws {
        let key = downloadKey(model: model, quantization: quantization)

        // Check if already downloading or downloaded
        if case .downloading = downloadStates[key] {
            logger.info("Model already downloading: \(key)")
            return
        }

        if case .downloaded = downloadStates[key] {
            logger.info("Model already downloaded: \(key)")
            return
        }

        // Check network conditions
        if !isOnWiFi && !allowCellular {
            throw OnDeviceLLMError.cellularNotAllowed
        }

        // Check available storage
        let requiredBytes = Int64(quantization.estimatedSizeGB * 1_073_741_824) // Convert GB to bytes
        let availableBytes = availableStorageSpace()

        if availableBytes < requiredBytes {
            throw OnDeviceLLMError.insufficientStorage(required: requiredBytes, available: availableBytes)
        }

        // Build download URL
        let filename = model.huggingFaceFilename(for: quantization)
        guard let downloadURL = URL(string: "https://huggingface.co/\(model.huggingFaceRepo)/resolve/main/\(filename)") else {
            throw OnDeviceLLMError.downloadFailed("Invalid download URL")
        }

        logger.info("Starting download: \(downloadURL.absoluteString)")

        // Update state
        downloadStates[key] = .downloading(progress: 0)

        // Create download task
        let task = backgroundSession.downloadTask(with: downloadURL)
        task.taskDescription = key
        downloadTasks[key] = task
        task.resume()
    }

    /// Cancel a download in progress
    func cancelDownload(for model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization) {
        let key = downloadKey(model: model, quantization: quantization)

        if let task = downloadTasks[key] {
            task.cancel()
            downloadTasks.removeValue(forKey: key)
        }

        downloadStates[key] = .notDownloaded
    }

    /// Delete a downloaded model
    func deleteModel(_ model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization) throws {
        let key = downloadKey(model: model, quantization: quantization)

        guard case .downloaded(let downloadedModel) = downloadStates[key] else {
            return
        }

        // Delete file
        let fileURL = URL(fileURLWithPath: downloadedModel.filePath)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }

        // Update state
        downloadStates[key] = .notDownloaded

        // Update downloaded models list
        downloadedModels.removeAll { $0.id == downloadedModel.id }
        saveDownloadedModels()
        updateTotalStorageUsed()

        logger.info("Deleted model: \(key)")
    }

    /// Delete all downloaded models
    func deleteAllModels() throws {
        for model in downloadedModels {
            let fileURL = URL(fileURLWithPath: model.filePath)
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
            }
        }

        downloadedModels.removeAll()
        downloadStates.removeAll()
        saveDownloadedModels()
        updateTotalStorageUsed()

        logger.info("Deleted all models")
    }

    /// Get available storage space
    func availableStorageSpace() -> Int64 {
        do {
            let values = try modelsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            logger.error("Failed to get available storage: \(error.localizedDescription)")
            return 0
        }
    }

    /// Format storage size for display
    func formatStorageSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Private Methods

    private func downloadKey(model: OnDeviceLLMModel, quantization: OnDeviceLLMQuantization) -> String {
        return "\(model.id)-\(quantization.rawValue)"
    }

    private func loadDownloadedModels() {
        // Load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: OnDeviceLLMSettingsKeys.downloadedModels),
           let models = try? JSONDecoder().decode([DownloadedModel].self, from: data) {
            downloadedModels = models

            // Update download states
            for model in models {
                let key = "\(model.modelID)-\(model.quantization.rawValue)"

                // Verify file exists
                if fileManager.fileExists(atPath: model.filePath) {
                    downloadStates[key] = .downloaded(model: model)
                } else {
                    // File was deleted externally, remove from list
                    logger.warning("Model file missing: \(model.filePath)")
                }
            }

            // Clean up models with missing files
            downloadedModels = downloadedModels.filter { model in
                fileManager.fileExists(atPath: model.filePath)
            }

            if downloadedModels.count != models.count {
                saveDownloadedModels()
            }
        }

        updateTotalStorageUsed()
    }

    private func saveDownloadedModels() {
        if let data = try? JSONEncoder().encode(downloadedModels) {
            UserDefaults.standard.set(data, forKey: OnDeviceLLMSettingsKeys.downloadedModels)
        }
    }

    private func updateTotalStorageUsed() {
        totalStorageUsed = downloadedModels.reduce(0) { $0 + $1.fileSize }
    }

    private func handleDownloadCompletion(key: String, location: URL) {
        // Parse key to get model and quantization
        let components = key.split(separator: "-")
        guard components.count >= 2,
              let model = OnDeviceLLMModel.model(byID: String(components.dropLast().joined(separator: "-"))),
              let quantization = OnDeviceLLMQuantization(rawValue: String(components.last!)) else {
            logger.error("Failed to parse download key: \(key)")
            Task { @MainActor in
                self.downloadStates[key] = .failed(error: "Invalid download key")
            }
            return
        }

        // Move file to models directory
        let filename = model.huggingFaceFilename(for: quantization)
        let destinationURL = modelsDirectory.appendingPathComponent(filename)

        do {
            // Remove existing file if present
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            // Move downloaded file
            try fileManager.moveItem(at: location, to: destinationURL)

            // Get file size
            let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0

            // Create downloaded model record
            let downloadedModel = DownloadedModel(
                id: UUID().uuidString,
                modelID: model.id,
                quantization: quantization,
                filePath: destinationURL.path,
                fileSize: fileSize,
                downloadedAt: Date()
            )

            Task { @MainActor in
                // Update states
                self.downloadStates[key] = .downloaded(model: downloadedModel)
                self.downloadedModels.append(downloadedModel)
                self.saveDownloadedModels()
                self.updateTotalStorageUsed()
                self.downloadTasks.removeValue(forKey: key)

                self.logger.info("Download completed: \(key), size: \(fileSize) bytes")
            }
        } catch {
            logger.error("Failed to move downloaded file: \(error.localizedDescription)")
            Task { @MainActor in
                self.downloadStates[key] = .failed(error: error.localizedDescription)
                self.downloadTasks.removeValue(forKey: key)
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let key = downloadTask.taskDescription else { return }

        // Copy file to a temporary location before async work
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.copyItem(at: location, to: tempURL)

        Task { @MainActor in
            self.handleDownloadCompletion(key: key, location: tempURL)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let key = downloadTask.taskDescription else { return }

        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        Task { @MainActor in
            self.downloadStates[key] = .downloading(progress: progress)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let key = task.taskDescription else { return }

        if let error = error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                Task { @MainActor in
                    self.downloadStates[key] = .notDownloaded
                    self.downloadTasks.removeValue(forKey: key)
                }
            } else {
                Task { @MainActor in
                    self.downloadStates[key] = .failed(error: error.localizedDescription)
                    self.downloadTasks.removeValue(forKey: key)
                    self.logger.error("Download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Handle background session completion
        Task { @MainActor in
            self.logger.info("Background URL session finished events")
        }
    }
}

// MARK: - Network Status Extension

extension ModelDownloadManager {
    /// Check if download should proceed based on network and settings
    func canDownload(allowCellular: Bool) -> Bool {
        return isOnWiFi || allowCellular
    }

    /// Get network status description
    var networkStatusDescription: String {
        isOnWiFi ? "Connected to WiFi" : "Using Cellular Data"
    }
}
