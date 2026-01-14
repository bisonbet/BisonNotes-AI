//
//  WhisperKitManager.swift
//  BisonNotes AI
//
//  Manages WhisperKit model downloading and transcription
//

import Foundation
import WhisperKit
import Combine
import Network
import CoreML

// MARK: - WhisperKit Errors

public enum WhisperKitError: Error, LocalizedError {
    case modelNotDownloaded
    case modelNotLoaded
    case transcriptionFailed(String)
    case networkUnavailable
    case insufficientRAM
    case downloadFailed(String)
    case invalidAudioFile

    public var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "WhisperKit model has not been downloaded yet. Please download the model in Settings."
        case .modelNotLoaded:
            return "WhisperKit model is not loaded. Please wait for model to initialize."
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .networkUnavailable:
            return "Network connection required for model download."
        case .insufficientRAM:
            return "Device does not have sufficient RAM for WhisperKit (4GB+ required)."
        case .downloadFailed(let message):
            return "Model download failed: \(message)"
        case .invalidAudioFile:
            return "Invalid or unsupported audio file format."
        }
    }
}

// MARK: - WhisperKit Manager

/// Singleton manager for WhisperKit model downloading and transcription
@MainActor
public class WhisperKitManager: NSObject, ObservableObject {

    // MARK: - Singleton

    public static let shared = WhisperKitManager()

    // MARK: - Published Properties

    @Published public var downloadProgress: Float = 0
    @Published public var isDownloading = false
    @Published public var downloadError: String?
    @Published public var isModelReady = false
    @Published public var downloadedSize: Int64 = 0
    @Published public var totalSize: Int64 = 0
    @Published public var downloadSpeed: Double = 0
    @Published public var isTranscribing = false
    @Published public var transcriptionProgress: Double = 0
    @Published public var currentStatus: String = ""

    // MARK: - Private Properties

    private var whisperKit: WhisperKit?
    private var networkMonitor: NWPathMonitor?
    private var downloadTask: Task<Void, Error>?
    private var lastUpdateTime: Date = Date()
    private var lastBytesWritten: Int64 = 0

    // MARK: - Initialization

    private override init() {
        super.init()
        startNetworkMonitoring()
        refreshModelStatus()
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                if path.status == .unsatisfied && self?.isDownloading == true {
                    self?.downloadError = "Network connection lost. Please check your internet connection."
                    self?.cancelDownload()
                }
            }
        }

        let queue = DispatchQueue(label: "WhisperKitNetworkMonitor")
        networkMonitor?.start(queue: queue)
    }

    // MARK: - Model Management

    /// Download the WhisperKit model
    public func downloadModel() async throws {
        guard !isDownloading else {
            print("[WhisperKit] Download already in progress")
            return
        }

        // Check network
        if networkMonitor?.currentPath.status == .unsatisfied {
            throw WhisperKitError.networkUnavailable
        }

        // Check device capability
        guard DeviceCompatibility.isWhisperKitSupported else {
            throw WhisperKitError.insufficientRAM
        }

        let model = WhisperKitModelInfo.selectedModel

        print("[WhisperKit] Starting download for \(model.displayName)")

        isDownloading = true
        downloadError = nil
        downloadProgress = 0.0  // Initialize to exactly 0.0
        downloadedSize = 0
        totalSize = model.downloadSizeBytes
        downloadSpeed = 0
        lastUpdateTime = Date()
        lastBytesWritten = 0
        currentStatus = "Preparing download..."
        
        print("[WhisperKit] Initial download state - totalSize: \(totalSize) bytes (\(formatSize(totalSize)))")

        do {
            // WhisperKit handles model download internally when initializing
            // We track progress via the progressCallback
            currentStatus = "Downloading model..."

            // WhisperKit's progress callback is unreliable - we'll track actual file sizes instead
            // Set up monitoring task to check actual download progress frequently
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let modelFolderName = "openai_whisper-\(model.modelName)"
            let expectedModelPath = documentsPath
                .appendingPathComponent("huggingface")
                .appendingPathComponent("models")
                .appendingPathComponent("argmaxinc")
                .appendingPathComponent("whisperkit-coreml")
                .appendingPathComponent(modelFolderName)
                .path
            
            // Start monitoring task to check actual file sizes frequently
            // This runs independently and tracks actual file system changes
            let downloadMonitoringTask = Task { @MainActor in
                var lastCheckedSize: Int64 = 0
                var lastCheckTime = Date()
                var checkCount = 0
                
                while !Task.isCancelled && self.isDownloading {
                    // Check every 0.5 seconds for responsive updates
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    checkCount += 1
                    
                    // Check if model directory exists and get its size
                    if FileManager.default.fileExists(atPath: expectedModelPath) {
                        let actualSize = self.getDirectorySize(at: expectedModelPath)
                        
                            // Update downloaded size if it increased
                            if actualSize > self.downloadedSize {
                                self.downloadedSize = actualSize
                                
                                // Calculate progress percentage (clamped to 0.0...1.0)
                                if self.totalSize > 0 {
                                    let progress = Float(actualSize) / Float(self.totalSize)
                                    self.downloadProgress = max(0.0, min(1.0, progress))
                                }
                            
                            // Calculate speed based on size changes
                            let now = Date()
                            let timeDelta = now.timeIntervalSince(lastCheckTime)
                            
                            // Update speed if we have meaningful time delta (at least 0.5 seconds) and size change
                            if timeDelta >= 0.5 && actualSize > lastCheckedSize {
                                let bytesDelta = actualSize - lastCheckedSize
                                self.downloadSpeed = Double(bytesDelta) / timeDelta
                                self.lastUpdateTime = now
                                self.lastBytesWritten = actualSize
                                
                                // Log progress every 5 checks (every 2.5 seconds) or when significant change
                                if checkCount % 5 == 0 || bytesDelta > 5_000_000 {
                                    print("[WhisperKit] Progress: \(self.formatSize(actualSize)) / \(self.formatSize(self.totalSize)) (\(Int(self.downloadProgress * 100))%) - \(self.formattedDownloadSpeed)")
                                }
                                
                                lastCheckTime = now
                                lastCheckedSize = actualSize
                            } else if actualSize > lastCheckedSize {
                                // Size increased but not enough time passed - update size anyway, reset timer
                                lastCheckedSize = actualSize
                                lastCheckTime = now
                            }
                            } else if actualSize > 0 && self.downloadedSize == 0 {
                                // First detection of files
                                self.downloadedSize = actualSize
                                if self.totalSize > 0 {
                                    let progress = Float(actualSize) / Float(self.totalSize)
                                    self.downloadProgress = max(0.0, min(1.0, progress))
                                }
                            lastCheckedSize = actualSize
                            lastCheckTime = Date()
                            print("[WhisperKit] Download started - detected \(self.formatSize(actualSize))")
                        }
                    } else if checkCount > 10 {
                        // If directory doesn't exist after 5 seconds, log for debugging
                        print("[WhisperKit] Waiting for model directory to appear at: \(expectedModelPath)")
                    }
                }
            }
            
            // Create minimal progress handler (WhisperKit requires it, but we ignore its values)
            let progressHandler: ((Progress) -> Void) = { _ in
                // We ignore WhisperKit's progress callback as it's unreliable
                // All tracking is done via the monitoring task above
            }
            
            // Download the model using WhisperKit's static method
            let modelFolder = try await WhisperKit.download(
                variant: model.modelName,
                progressCallback: progressHandler
            )
            
            // Final check - get actual size after download completes
            let finalSize = getDirectorySize(at: modelFolder.path)
            if finalSize > 0 {
                downloadedSize = finalSize
                downloadProgress = 1.0  // Clamp to 1.0 for completion
                print("[WhisperKit] Final size: \(formatSize(finalSize))")
            } else {
                // Ensure progress is at least 0.0
                downloadProgress = max(0.0, downloadProgress)
            }
            
            // Cancel the monitoring task once download completes
            downloadMonitoringTask.cancel()

            let modelPath = modelFolder.path
            print("[WhisperKit] Model downloaded to: \(modelFolder)")
            print("[WhisperKit] Model path string: \(modelPath)")

            // Verify the path exists before saving
            guard FileManager.default.fileExists(atPath: modelPath) else {
                throw WhisperKitError.downloadFailed("Downloaded model folder not found at: \(modelPath)")
            }

            // Save the model path
            UserDefaults.standard.set(modelPath, forKey: WhisperKitModelInfo.SettingsKeys.modelPath)
            UserDefaults.standard.set(true, forKey: WhisperKitModelInfo.SettingsKeys.modelDownloaded)
            
            print("[WhisperKit] Model path saved to UserDefaults: \(modelPath)")

            isModelReady = true
            isDownloading = false
            downloadProgress = 1.0  // Ensure completion shows 100%
            currentStatus = "Model ready"

            print("[WhisperKit] Download complete")

        } catch {
            print("[WhisperKit] Download failed: \(error)")
            downloadError = "Download failed: \(error.localizedDescription)"
            isDownloading = false
            currentStatus = ""
            throw WhisperKitError.downloadFailed(error.localizedDescription)
        }
    }

    /// Clear compiled CoreML cache to force recompilation
    /// Note: This doesn't delete .mlmodelc files (they're required), but clears any ANE-specific caches
    public func clearCompiledCache() {
        // Don't delete .mlmodelc files - they're the actual model files WhisperKit needs
        // The ANE compilation issue needs to be resolved by re-downloading or letting
        // WhisperKit handle recompilation automatically
        print("[WhisperKit] Note: Model files are required. If experiencing ANE errors, try re-downloading the model.")
        
        // Just unload the in-memory instance to force a fresh load
        whisperKit = nil
        isModelReady = false
    }

    /// Delete the downloaded model
    public func deleteModel() {
        // Clear the WhisperKit instance
        whisperKit = nil

        // Get the model path and delete
        if let modelPath = UserDefaults.standard.string(forKey: WhisperKitModelInfo.SettingsKeys.modelPath) {
            let modelURL = URL(fileURLWithPath: modelPath)
            do {
                if FileManager.default.fileExists(atPath: modelURL.path) {
                    try FileManager.default.removeItem(at: modelURL)
                    print("[WhisperKit] Model deleted from: \(modelPath)")
                }
            } catch {
                print("[WhisperKit] Failed to delete model: \(error)")
                downloadError = "Failed to delete model: \(error.localizedDescription)"
            }
        }

        // Also try to clean up the default WhisperKit models directory
        let defaultModelsDir = URL.whisperKitModelsDirectory
        if FileManager.default.fileExists(atPath: defaultModelsDir.path) {
            try? FileManager.default.removeItem(at: defaultModelsDir)
        }

        // Clear user defaults
        UserDefaults.standard.removeObject(forKey: WhisperKitModelInfo.SettingsKeys.modelPath)
        UserDefaults.standard.set(false, forKey: WhisperKitModelInfo.SettingsKeys.modelDownloaded)

        isModelReady = false
        currentStatus = ""
    }

    /// Cancel the current download
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0.0  // Reset to exactly 0.0
        downloadedSize = 0
        totalSize = 0
        downloadSpeed = 0
        currentStatus = ""

        print("[WhisperKit] Download cancelled")
    }

    /// Refresh model status
    public func refreshModelStatus() {
        let isDownloaded = UserDefaults.standard.bool(forKey: WhisperKitModelInfo.SettingsKeys.modelDownloaded)
        let modelPath = UserDefaults.standard.string(forKey: WhisperKitModelInfo.SettingsKeys.modelPath)

        // First, check if the saved path exists
        if isDownloaded, let path = modelPath {
            // Verify the model still exists
            if FileManager.default.fileExists(atPath: path) {
                isModelReady = true
                return
            }
        }

        // If not found in UserDefaults, check the standard WhisperKit model location
        // WhisperKit stores models in Documents/huggingface/models/argmaxinc/whisperkit-coreml/
        let model = WhisperKitModelInfo.selectedModel
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // The folder name uses openai_whisper- prefix, e.g., openai_whisper-large-v3_turbo
        let modelFolderName = "openai_whisper-\(model.modelName)"
        let standardModelPath = documentsPath
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(modelFolderName)
            .path

        if FileManager.default.fileExists(atPath: standardModelPath) {
            // Restore the path to UserDefaults
            UserDefaults.standard.set(standardModelPath, forKey: WhisperKitModelInfo.SettingsKeys.modelPath)
            UserDefaults.standard.set(true, forKey: WhisperKitModelInfo.SettingsKeys.modelDownloaded)
            isModelReady = true
            return
        }

        // Model not found anywhere, reset state
        print("[WhisperKit] Model not found - needs download")
        isModelReady = false
        UserDefaults.standard.set(false, forKey: WhisperKitModelInfo.SettingsKeys.modelDownloaded)
    }

    // MARK: - Transcription

    /// Transcribe an audio file
    /// - Parameter audioURL: URL to the audio file
    /// - Returns: TranscriptionResult with the transcribed text and segments
    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        guard isModelReady else {
            throw WhisperKitError.modelNotDownloaded
        }

        // Verify file exists
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw WhisperKitError.invalidAudioFile
        }

        isTranscribing = true
        transcriptionProgress = 0
        currentStatus = "Initializing WhisperKit..."

        defer {
            isTranscribing = false
            currentStatus = ""
        }

        let startTime = Date()

        do {
            // Load or initialize WhisperKit
            if whisperKit == nil {
                currentStatus = "Loading model..."
                print("[WhisperKit] Initializing WhisperKit...")

                // Get the saved model path
                guard let modelPath = UserDefaults.standard.string(forKey: WhisperKitModelInfo.SettingsKeys.modelPath) else {
                    throw WhisperKitError.modelNotDownloaded
                }

                // Verify the model folder exists
                guard FileManager.default.fileExists(atPath: modelPath) else {
                    print("[WhisperKit] Model folder not found at: \(modelPath)")
                    throw WhisperKitError.modelNotDownloaded
                }

                print("[WhisperKit] Loading model from: \(modelPath)")

                let config = WhisperKitConfig(
                    modelFolder: modelPath,
                    verbose: true,
                    prewarm: true,
                    load: true,
                    download: false  // Model should already be downloaded
                )

                do {
                    whisperKit = try await WhisperKit(config)
                    print("[WhisperKit] WhisperKit initialized")
                } catch {
                    let errorMessage = error.localizedDescription
                    print("[WhisperKit] Failed to initialize: \(error)")
                    
                    // Check for ANE compilation errors
                    if errorMessage.contains("ANE model load has failed") || 
                       errorMessage.contains("Must re-compile") ||
                       errorMessage.contains("E5 bundle") {
                        print("[WhisperKit] Model compilation error detected. Model may need to be re-downloaded.")
                        // Clear the model ready state so user knows to re-download
                        isModelReady = false
                        UserDefaults.standard.set(false, forKey: WhisperKitModelInfo.SettingsKeys.modelDownloaded)
                        throw WhisperKitError.modelNotLoaded
                    }
                    throw error
                }
            }

            guard let pipe = whisperKit else {
                throw WhisperKitError.modelNotLoaded
            }

            currentStatus = "Transcribing audio..."
            print("[WhisperKit] Starting transcription for: \(audioURL.lastPathComponent)")

            // Configure decoding options to reduce artifacts
            let decodingOptions = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: nil,
                temperature: 0.0,  // Deterministic output
                topK: 50,
                usePrefillPrompt: false,
                withoutTimestamps: true  // Disable timestamp tokens to reduce artifacts
            )

            // Perform transcription with clean options
            let results = try await pipe.transcribe(audioPath: audioURL.path, decodeOptions: decodingOptions)

            let processingTime = Date().timeIntervalSince(startTime)

            // Convert WhisperKit results to app's format
            var fullText = ""
            var segments: [TranscriptSegment] = []

            for result in results {
                // Clean known WhisperKit artifact markers from result text
                let cleanedText = self.cleanWhisperKitArtifacts(result.text)
                fullText += cleanedText

                // Convert segments with cleaning
                for segment in result.segments {
                    let segmentText = self.cleanWhisperKitArtifacts(segment.text)

                    // Only add segments with actual content (skip empty or artifact-only segments)
                    if !segmentText.isEmpty {
                        let transcriptSegment = TranscriptSegment(
                            speaker: "Speaker",
                            text: segmentText,
                            startTime: TimeInterval(segment.start),
                            endTime: TimeInterval(segment.end)
                        )
                        segments.append(transcriptSegment)
                    }
                }
            }

            // Clean up the full text
            fullText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)

            print("[WhisperKit] Transcription complete. Duration: \(String(format: "%.2f", processingTime))s")
            print("[WhisperKit] Text length: \(fullText.count) characters, \(segments.count) segments")

            return TranscriptionResult(
                fullText: fullText,
                segments: segments,
                processingTime: processingTime,
                chunkCount: 1,
                success: true,
                error: nil
            )

        } catch {
            let errorMessage = error.localizedDescription
            print("[WhisperKit] Transcription failed: \(error)")
            
            // Check for ANE compilation errors
            if errorMessage.contains("ANE model load has failed") || 
               errorMessage.contains("Must re-compile") ||
               errorMessage.contains("E5 bundle") {
                let compilationError = "Model needs recompilation. Please delete and re-download the model in Settings."
                print("[WhisperKit] \(compilationError)")
                throw WhisperKitError.transcriptionFailed(compilationError)
            }
            
            throw WhisperKitError.transcriptionFailed(errorMessage)
        }
    }

    /// Unload the model from memory
    public func unloadModel() {
        whisperKit = nil
        print("[WhisperKit] Model unloaded from memory")
    }

    // MARK: - Formatted Properties

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

    /// Estimated time remaining for download
    public var estimatedTimeRemaining: String? {
        // Only show time remaining if we have meaningful speed (> 1 KB/s) and valid progress
        guard downloadSpeed > 1_000, totalSize > downloadedSize, downloadedSize > 0 else { return nil }
        
        let remainingBytes = totalSize - downloadedSize
        let secondsRemaining = Double(remainingBytes) / downloadSpeed
        
        // Cap at reasonable maximum (24 hours) to avoid showing unrealistic times
        let cappedSeconds = min(secondsRemaining, 86400)

        if cappedSeconds < 60 {
            return "Less than a minute"
        } else if cappedSeconds < 3600 {
            let minutes = Int(cappedSeconds / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") remaining"
        } else {
            let hours = Int(cappedSeconds / 3600)
            let minutes = Int((cappedSeconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m remaining"
        }
    }

    /// Format size for display
    public func formatSize(_ size: Int64) -> String {
        let sizeInGB = Double(size) / 1_000_000_000.0
        if sizeInGB >= 1.0 {
            return String(format: "%.2f GB", sizeInGB)
        } else {
            let sizeInMB = Double(size) / 1_000_000.0
            return String(format: "%.0f MB", sizeInMB)
        }
    }
    
    /// Get the total size of a directory and its contents
    private func getDirectorySize(at path: String) -> Int64 {
        guard FileManager.default.fileExists(atPath: path) else {
            return 0
        }

        var totalSize: Int64 = 0
        let fileManager = FileManager.default

        if let enumerator = fileManager.enumerator(atPath: path) {
            for file in enumerator {
                if let filePath = file as? String {
                    let fullPath = (path as NSString).appendingPathComponent(filePath)
                    if let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                       let fileSize = attributes[.size] as? Int64 {
                        totalSize += fileSize
                    }
                }
            }
        }

        return totalSize
    }

    /// Clean WhisperKit-specific artifact markers from transcription text
    /// Only removes known non-speech markers to avoid removing actual transcript content
    private func cleanWhisperKitArtifacts(_ text: String) -> String {
        var cleaned = text

        // Remove specific WhisperKit markers that are definitely artifacts
        // [BLANK_AUDIO] - silence markers
        cleaned = cleaned.replacingOccurrences(of: "[BLANK_AUDIO]", with: "")

        // [MUSIC], [APPLAUSE], [NOISE] - audio classification markers
        cleaned = cleaned.replacingOccurrences(of: "[MUSIC]", with: "")
        cleaned = cleaned.replacingOccurrences(of: "[APPLAUSE]", with: "")
        cleaned = cleaned.replacingOccurrences(of: "[NOISE]", with: "")

        let whisperKitTokens = [
            "<|startoftranscript|>",
            "<|nocaptions|>",
            "<|endoftext|>",
            "<|en|>",
            "<|transcribe|>"
        ]
        for token in whisperKitTokens {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }

        // Remove timestamp tokens in format <|0.00|>, <|1.50|> etc.
        // Pattern: <| followed by numbers/decimals followed by |>
        cleaned = cleaned.replacingOccurrences(
            of: "<\\|[0-9]+\\.?[0-9]*\\|>",
            with: "",
            options: .regularExpression
        )

        // Trim whitespace and normalize multiple spaces to single space
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        cleaned = cleaned.replacingOccurrences(
            of: "  +",
            with: " ",
            options: .regularExpression
        )

        return cleaned
    }
}
