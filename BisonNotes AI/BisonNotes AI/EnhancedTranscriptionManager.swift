//
//  EnhancedTranscriptionManager.swift
//  Audio Journal
//
//  Enhanced transcription manager for handling large audio files
//

import Foundation
import Speech
import AVFoundation
import Combine
import SwiftUI // Added for @AppStorage
import UIKit

// MARK: - Transcription Progress

struct TranscriptionProgress {
    let currentChunk: Int
    let totalChunks: Int
    let processedDuration: TimeInterval
    let totalDuration: TimeInterval
    let currentText: String
    let isComplete: Bool
    let error: Error?
    
    var percentage: Double {
        guard totalChunks > 0 else { return 0 }
        return Double(currentChunk) / Double(totalChunks)
    }
    
    var formattedProgress: String {
        return "\(currentChunk)/\(totalChunks) chunks (\(Int(percentage * 100))%)"
    }
}

// MARK: - Transcription Result

struct TranscriptionResult {
    let fullText: String
    let segments: [TranscriptSegment]
    let processingTime: TimeInterval
    let chunkCount: Int
    let success: Bool
    let error: Error?
}

// MARK: - Transcription Job Info

struct TranscriptionJobInfo: Codable {
    let jobName: String
    let recordingURL: URL
    let recordingName: String
    let startDate: Date
}

// MARK: - Enhanced Transcription Manager

@MainActor
class EnhancedTranscriptionManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isTranscribing = false
    @Published var currentStatus = ""
    @Published var progress: TranscriptionProgress?
    
    // MARK: - Private Properties
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var currentTask: SFSpeechRecognitionTask?
    private let chunkingService = AudioFileChunkingService()
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    // Configuration - Always use enhanced transcription
    private var enableEnhancedTranscription: Bool {
        return true
    }
    
    private var maxChunkDuration: TimeInterval {
        UserDefaults.standard.double(forKey: "maxChunkDuration").nonZero ?? 300 // 5 minutes per chunk
    }
    
    private var maxTranscriptionTime: TimeInterval {
        UserDefaults.standard.double(forKey: "maxTranscriptionTime").nonZero ?? 3600 // 1 hour total timeout
    }
    
    private var chunkOverlap: TimeInterval {
        UserDefaults.standard.double(forKey: "chunkOverlap").nonZero ?? 2.0 // 2 second overlap between chunks
    }
    
    private var enableAWSTranscribe: Bool {
        return UserDefaults.standard.bool(forKey: "enableAWSTranscribe")
    }
    
    // AWS Configuration
    private var awsConfig: AWSTranscribeConfig? {
        guard enableAWSTranscribe else { return nil }
        
        // Use unified credentials manager instead of separate UserDefaults keys
        let credentials = AWSCredentialsManager.shared.credentials
        let bucketName = UserDefaults.standard.string(forKey: "awsBucketName") ?? ""
        
        guard credentials.isValid && !bucketName.isEmpty else {
            return nil
        }
        
        return AWSTranscribeConfig(
            region: credentials.region,
            accessKey: credentials.accessKeyId,
            secretKey: credentials.secretAccessKey,
            bucketName: bucketName
        )
    }
    
    // Whisper Configuration
    private var whisperConfig: WhisperConfig? {
        let isEnabled = UserDefaults.standard.bool(forKey: "enableWhisper")
        let serverURL = UserDefaults.standard.string(forKey: "whisperServerURL") ?? "localhost"
        let port = UserDefaults.standard.integer(forKey: "whisperPort")
        let protocolString = UserDefaults.standard.string(forKey: "whisperProtocol") ?? WhisperProtocol.rest.rawValue
        let selectedProtocol = WhisperProtocol(rawValue: protocolString) ?? .rest
        
        
        guard isEnabled else { 
    return nil 
        }
        
        // Use default port if not set (UserDefaults.integer returns 0 if key doesn't exist)
        let effectivePort = port > 0 ? port : (selectedProtocol == .wyoming ? 10300 : 9000)
        
        // Ensure URL format matches protocol
        var processedServerURL = serverURL
        if selectedProtocol == .rest && !serverURL.hasPrefix("http://") && !serverURL.hasPrefix("https://") {
            processedServerURL = "http://" + serverURL
        }
        
        let config = WhisperConfig(
            serverURL: processedServerURL,
            port: effectivePort,
            whisperProtocol: selectedProtocol
        )
        
        return config
    }
    
    // OpenAI Configuration
    private var openAIConfig: OpenAITranscribeConfig? {
        let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
        let modelString = UserDefaults.standard.string(forKey: "openAIModel") ?? OpenAITranscribeModel.gpt4oMiniTranscribe.rawValue
        let baseURL = UserDefaults.standard.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
        
        
        guard !apiKey.isEmpty else {
            print("⚠️ OpenAI API key is not configured")
            return nil
        }
        
        let model = OpenAITranscribeModel(rawValue: modelString) ?? .gpt4oMiniTranscribe
        
        let config = OpenAITranscribeConfig(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL
        )
        
        return config
    }
    
    // MARK: - Whisper Validation
    
    func isWhisperProperlyConfigured() -> Bool {
        let isEnabled = UserDefaults.standard.bool(forKey: "enableWhisper")
        let serverURL = UserDefaults.standard.string(forKey: "whisperServerURL")
        let port = UserDefaults.standard.integer(forKey: "whisperPort")
        
        
        guard isEnabled else {
    return false
        }
        
        guard let serverURL = serverURL, !serverURL.isEmpty else {
    return false
        }
        
        // Use default port if not set (UserDefaults.integer returns 0 if key doesn't exist)
        let _ = port > 0 ? port : 9000
        
        return true
    }
    
    func validateWhisperService() async -> Bool {
        guard isWhisperProperlyConfigured() else {
            return false
        }
        
        guard let config = whisperConfig else {
            return false
        }
        
        let whisperService = WhisperService(config: config, chunkingService: chunkingService)
        return await whisperService.testConnection()
    }
    
    // Job tracking for async transcriptions
    private var pendingJobNames: String = ""
    private var pendingJobs: [TranscriptionJobInfo] = []
    
    // Background checking for completed transcriptions
    private var backgroundCheckTimer: Timer?
    private var isBackgroundChecking = false
    
    // Callback for when transcriptions complete
    var onTranscriptionCompleted: ((TranscriptionResult, TranscriptionJobInfo) -> Void)?
    
    // Alert states for user notifications
    @Published var showingWhisperFallbackAlert = false
    @Published var whisperFallbackMessage = ""
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        setupSpeechRecognizer()
        // Load pending job names from UserDefaults
        pendingJobNames = UserDefaults.standard.string(forKey: "pendingTranscriptionJobs") ?? ""
        
        // Load pending jobs from UserDefaults
        loadPendingJobs()
        
        // Don't start background checking on init - let it be controlled by the selected engine
    }
    
    private func setupSpeechRecognizer() {
        // Try to create speech recognizer with user's preferred locale first
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        
        // If that fails, try en-US as fallback
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
        
        // If that still fails, try without specifying locale (uses system default)
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer()
        }
        
        speechRecognizer?.delegate = self
        
        if let recognizer = speechRecognizer {
            print("✅ Speech recognizer created with locale: \(recognizer.locale.identifier)")
            print("🔧 Speech recognizer availability: \(recognizer.isAvailable)")
            
            // Check if we need to request authorization
            let authStatus = SFSpeechRecognizer.authorizationStatus()
            print("🔧 Speech recognition authorization status: \(authStatus.rawValue)")
            
            if authStatus == .notDetermined {
                print("🎤 Requesting speech recognition authorization...")
                SFSpeechRecognizer.requestAuthorization { status in
                    print("🔧 Speech recognition authorization updated: \(status.rawValue)")
                }
            }
        } else {
            print("❌ Failed to create speech recognizer with any locale")
            print("🔧 This may be due to simulator limitations or device restrictions")
        }
    }
    
    deinit {
        // Clean up resources when the manager is deallocated
        currentTask?.cancel()
        currentTask = nil
        speechRecognizer = nil
    }

    // MARK: - Background Task Management

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WhisperTranscription") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    // MARK: - Memory Management
    
    private func checkMemoryPressure() {
        // Force garbage collection to help with memory management
        autoreleasepool {
            // This will help release memory
        }
        
        // Get actual app memory usage (not total device memory)
        let memoryUsage = getAppMemoryUsage()
        let memoryUsageMB = memoryUsage / 1024 / 1024
        print("💾 App memory usage: \(memoryUsageMB) MB")
        
        // Only warn about high memory usage, don't cancel transcriptions
        // iOS will handle memory pressure automatically
        let warningThresholdMB: UInt64 = 500 // 500 MB warning threshold
        if memoryUsageMB > warningThresholdMB {
            print("⚠️ High app memory usage detected (\(memoryUsageMB) MB), but continuing transcription")
            // Force cleanup without cancelling
            autoreleasepool {
                // This will help release memory
            }
        }
    }
    
    private func getAppMemoryUsage() -> UInt64 {
        // Get the current memory usage of this app process
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return UInt64(info.resident_size)
        } else {
            // Fallback: return a reasonable estimate
            return 100 * 1024 * 1024 // 100 MB fallback
        }
    }
    
    // MARK: - Public Methods
    
    func transcribeAudioFile(at url: URL, using engine: TranscriptionEngine? = nil) async throws -> TranscriptionResult {
        
        // Check if already transcribing
        guard !isTranscribing else {
    throw TranscriptionError.recognitionFailed(NSError(domain: "AlreadyTranscribing", code: -1, userInfo: nil))
        }
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ File not found: \(url.path)")
            throw TranscriptionError.fileNotFound
        }
        
        // Validate audio file before transcription
        do {
            let testPlayer = try AVAudioPlayer(contentsOf: url)
            guard testPlayer.duration > 0 else {
    throw TranscriptionError.noSpeechDetected
            }
            
            // Check if duration is reasonable
            let durationMinutes = testPlayer.duration / 60
if durationMinutes > 120 { // 2 hours max
                print("⚠️ Audio file is very long (\(durationMinutes) minutes), this may cause memory issues")
            }
        } catch {
            print("❌ Audio file validation failed: \(error)")
            throw TranscriptionError.audioExtractionFailed
        }
        
        // Check file duration
        let duration = try await getAudioDuration(url: url)
        
// Determine transcription engine to use
        let selectedEngine = engine ?? .appleIntelligence // Default fallback
        
        // Check if Apple Intelligence is available for fallback
        if selectedEngine != .appleIntelligence {
            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
return try await transcribeWithAppleIntelligence(url: url, duration: duration)
            }
        }
        
        // Manage background checking based on selected engine
        switch selectedEngine {
        case .awsTranscribe:
            switchToAWSTranscription()
            
            // Check if AWS Transcribe is configured
            guard let config = awsConfig else {
                print("❌ AWS Transcribe selected but not configured")
                throw TranscriptionError.awsNotConfigured
            }
            
            // AWS Transcribe has a maximum limit of 4 hours
            let maxAWSDuration: TimeInterval = 4 * 60 * 60 // 4 hours in seconds
            if duration > maxAWSDuration {
                print("❌ File too large for AWS Transcribe: \(duration/3600) hours (max: 4 hours)")
                throw TranscriptionError.fileTooLarge(duration: duration, maxDuration: maxAWSDuration)
            }
            
return try await transcribeWithAWS(url: url, config: config)
            
        case .appleIntelligence:
            switchToAppleTranscription()
            
            // Ensure speech recognizer is available
            if speechRecognizer == nil {
                print("❌ Apple Intelligence speech recognizer is nil - attempting to recreate")
                setupSpeechRecognizer()
                guard speechRecognizer != nil else {
                    print("❌ Failed to recreate speech recognizer")
                    throw TranscriptionError.speechRecognizerUnavailable
                }
                print("✅ Successfully recreated speech recognizer")
            }
            
            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                print("❌ Apple Intelligence speech recognizer is not available")
                if let recognizer = speechRecognizer {
                    print("🔧 Recognizer locale: \(recognizer.locale.identifier)")
                }
                print("🔧 Authorization status: \(SFSpeechRecognizer.authorizationStatus().rawValue)")
                print("🔧 This may be due to simulator limitations or missing permissions")
                throw TranscriptionError.speechRecognizerUnavailable
            }
            
            print("✅ Speech recognizer is available, starting transcription")
            return try await transcribeWithAppleIntelligence(url: url, duration: duration)
            
        case .whisper, .whisperWyoming:
            switchToWhisperTranscription()
            
            // Validate Whisper configuration and availability
            if !isWhisperProperlyConfigured() {
                print("⚠️ Whisper not properly configured, falling back to Apple Intelligence")
                switchToAppleTranscription()
                return try await transcribeWithAppleIntelligence(url: url, duration: duration)
            }
            
            let isWhisperAvailable = await validateWhisperService()
if isWhisperAvailable {
                if let config = whisperConfig {
                    return try await transcribeWithWhisper(url: url, config: config)
                } else {
                    switchToAppleTranscription()
                    return try await transcribeWithAppleIntelligence(url: url, duration: duration)
                }
            } else {
                switchToAppleTranscription()
                return try await transcribeWithAppleIntelligence(url: url, duration: duration)
            }
            
        case .openAI:
            switchToAppleTranscription() // OpenAI doesn't need background checking
            
            // Validate OpenAI configuration
if let config = openAIConfig {
                return try await transcribeWithOpenAI(url: url, config: config)
            } else {
                // Ensure speech recognizer is available for fallback
                guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                    throw TranscriptionError.speechRecognizerUnavailable
                }
                
                return try await transcribeWithAppleIntelligence(url: url, duration: duration)
            }
            
        case .openAIAPICompatible:
// These are not implemented yet, fall back to Apple Intelligence
            switchToAppleTranscription()
            return try await transcribeWithAppleIntelligence(url: url, duration: duration)
        }
    }
    
    private func transcribeWithAppleIntelligence(url: URL, duration: TimeInterval) async throws -> TranscriptionResult {
        // Ensure transcription state is properly initialized
        await MainActor.run {
            isTranscribing = true
            currentStatus = "Initializing Apple Intelligence transcription..."
        }
        
        print("🎤 Starting Apple Intelligence transcription for file: \(url.lastPathComponent)")
        print("⏱️ Duration: \(duration) seconds")
        
        // Double-check speech recognizer availability right before transcription
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            await MainActor.run {
                isTranscribing = false
                currentStatus = "Speech recognition unavailable"
            }
            print("❌ Speech recognizer check failed at transcription start")
            throw TranscriptionError.speechRecognizerUnavailable
        }
        
        // Use the existing logic for Apple Intelligence transcription
        if !enableEnhancedTranscription || duration <= maxChunkDuration {
            print("📝 Using single chunk transcription (duration: \(duration)s <= \(maxChunkDuration)s)")
            return try await transcribeSingleChunk(url: url)
        } else {
            print("📝 Using large file transcription (duration: \(duration)s > \(maxChunkDuration)s)")
            return try await transcribeLargeFile(url: url, duration: duration)
        }
    }
    
    func cancelTranscription() {
        
        // Cancel the current task
        currentTask?.cancel()
        currentTask = nil
        
        // Reset state
        isTranscribing = false
        progress = nil
        currentStatus = "Transcription cancelled"
        
        // Force cleanup of speech recognizer resources
        speechRecognizer = nil
        setupSpeechRecognizer()
        
        // Force memory cleanup
        checkMemoryPressure()
        
    }
    
    /// Manually check for completed transcriptions
    func checkForCompletedTranscriptions() async {
        // Only check if AWS is enabled and configured
        guard enableAWSTranscribe else {
            return
        }
        
        guard let config = awsConfig else { 
            return 
        }
        
        let jobNames = getPendingJobNames()
        guard !jobNames.isEmpty else { 
            return 
        }
        
        
        var stillPendingJobs: [String] = []
        
        for jobName in jobNames {
            do {
                let status = try await checkTranscriptionStatus(jobName: jobName, config: config)
                
if status.isCompleted {
                    let result = try await retrieveTranscription(jobName: jobName, config: config)
                    
                    // Get job info before removing it
                    let jobInfo = getPendingJobInfo(for: jobName)
                    
                    // Remove from pending jobs
                    removePendingJob(jobName)
                    
                    // Notify completion
                    if let jobInfo = jobInfo {
                        onTranscriptionCompleted?(result, jobInfo)
                    }
                    
                } else if status.isFailed {
                    print("❌ AWS job failed: \(jobName) - \(status.failureReason ?? "Unknown error")")
                    // Remove failed jobs from pending list
                    removePendingJob(jobName)
                } else {
                    stillPendingJobs.append(jobName)
                }
            } catch {
                print("❌ Error checking AWS job \(jobName): \(error)")
                // Keep job in pending list if we can't check it
                stillPendingJobs.append(jobName)
            }
        }
        
        // Update pending jobs list
        if stillPendingJobs != jobNames {
            updatePendingJobNames(stillPendingJobs)
        }
    }
    
    // MARK: - Private Methods
    
    private func getAudioDuration(url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }
    
private func transcribeSingleChunk(url: URL) async throws -> TranscriptionResult {
        let startTime = Date()
        isTranscribing = true
        currentStatus = "Transcribing audio..."
        
        // Check if speech recognizer is available
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("❌ Speech recognizer is not available")
            isTranscribing = false
            currentStatus = "Speech recognition unavailable"
            throw TranscriptionError.speechRecognizerUnavailable
        }
        
        // Add timeout to prevent infinite CPU usage
        return try await withThrowingTaskGroup(of: TranscriptionResult.self) { group in
            // Main transcription task
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TranscriptionResult, Error>) in
                    
                    let request = SFSpeechURLRecognitionRequest(url: url)
                    request.shouldReportPartialResults = false
                    
                    // Add additional request configuration to minimize audio issues
                    if #available(iOS 16.0, *) {
                        request.addsPunctuation = true
                    }
                    
                    // Create a weak reference to avoid retain cycles
                    weak var weakSelf = self
                    var hasResumed = false
                    
                    self.currentTask = recognizer.recognitionTask(with: request) { result, error in
                        guard let self = weakSelf, !hasResumed else { return }
                        
                        DispatchQueue.main.async {
                            // Ensure we only resume once
                            guard !hasResumed else { return }
                            hasResumed = true
                            
                            // Clean up the task immediately
                            self.currentTask?.cancel()
                            self.currentTask = nil
                            
if let error = error {
                                // Check if this is a non-critical error that can be safely ignored
                                if self.handleSpeechRecognitionError(error) {
                                    // Non-critical error, continue processing
                                    hasResumed = false
                                    return
                                }
                                
                                // Check if speech recognizer became unavailable
                                if !recognizer.isAvailable {
                                    self.isTranscribing = false
                                    self.currentStatus = "Speech recognition unavailable"
                                    continuation.resume(throwing: TranscriptionError.speechRecognizerUnavailable)
                                    return
                                }
                                
                                // Critical error, stop processing
                                self.isTranscribing = false
                                self.currentStatus = "Transcription failed"
                                continuation.resume(throwing: TranscriptionError.recognitionFailed(error))
                            } else if let result = result {
if result.isFinal {
                                    let processingTime = Date().timeIntervalSince(startTime)
                                    let transcriptText = result.bestTranscription.formattedString
                                    
if transcriptText.isEmpty {
                                        self.isTranscribing = false
                                        self.currentStatus = "No speech detected"
                                        continuation.resume(throwing: TranscriptionError.noSpeechDetected)
                                    } else {
// Check if transcript contains error text
                                        if transcriptText.lowercased().contains("error") {
                                            print("⚠️ WARNING: Transcript contains 'error' text!")
                                            print("📝 Transcript text: \(transcriptText)")
                                            print("🔍 This might indicate a transcription error was saved as content")
                                        }
                                        let segments = self.createSegments(from: result.bestTranscription)
                                        let transcriptionResult = TranscriptionResult(
                                            fullText: transcriptText,
                                            segments: segments,
                                            processingTime: processingTime,
                                            chunkCount: 1,
                                            success: true,
                                            error: nil
                                        )
                                        
                                        self.isTranscribing = false
                                        self.currentStatus = "Transcription complete"
                                        continuation.resume(returning: transcriptionResult)
                                    }
} else {
                                    // Don't resume for partial results
                                    hasResumed = false
                                }
                            }
                        }
                    }
                }
            }
            
// Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(300 * 1_000_000_000)) // 5 minute timeout
                await MainActor.run {
                    self.currentTask?.cancel()
                    self.currentTask = nil
                    self.isTranscribing = false
                    self.currentStatus = "Transcription timed out"
                }
                throw TranscriptionError.timeout
            }
            
            // Return the first completed task (either success or timeout)
            guard let result = try await group.next() else {
                throw TranscriptionError.timeout
            }
            
            // Cancel remaining tasks
            group.cancelAll()
            return result
        }
    }
    
private func transcribeLargeFile(url: URL, duration: TimeInterval) async throws -> TranscriptionResult {
        let startTime = Date()
        isTranscribing = true
        currentStatus = "Processing large file..."
        
        // Check if file is too large to process safely
        let maxSafeDuration: TimeInterval = 3600 // 1 hour max for chunked processing
        if duration > maxSafeDuration {
            print("⚠️ File duration (\(duration/60) minutes) exceeds safe limit (\(maxSafeDuration/60) minutes)")
            throw TranscriptionError.fileTooLarge(duration: duration, maxDuration: maxSafeDuration)
        }
        
        // Check file size to prevent memory issues
do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0
            let fileSizeMB = fileSize / 1024 / 1024
            
            let maxFileSizeMB: Int64 = 500 // 500 MB max
            if fileSizeMB > maxFileSizeMB {
                print("⚠️ File size (\(fileSizeMB) MB) exceeds safe limit (\(maxFileSizeMB) MB)")
                throw TranscriptionError.fileTooLarge(duration: duration, maxDuration: maxSafeDuration)
            }
        } catch {
            print("⚠️ Could not check file size: \(error)")
        }
        
        // Check available disk space
do {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let documentsAttributes = try FileManager.default.attributesOfFileSystem(forPath: documentsPath.path)
            let freeSpace = documentsAttributes[.systemFreeSize] as? Int64 ?? 0
            let freeSpaceMB = freeSpace / 1024 / 1024
            
            let minFreeSpaceMB: Int64 = 1000 // 1 GB min
            if freeSpaceMB < minFreeSpaceMB {
                print("⚠️ Insufficient disk space (\(freeSpaceMB) MB), need at least \(minFreeSpaceMB) MB")
                throw TranscriptionError.audioExtractionFailed
            }
        } catch {
            print("⚠️ Could not check disk space: \(error)")
        }
        
// Calculate chunks
        let chunks = calculateChunks(duration: duration)
        
        // Limit the number of chunks to prevent memory issues
        let maxChunks = 20 // Maximum number of chunks to process
        if chunks.count > maxChunks {
            print("⚠️ Too many chunks (\(chunks.count)), limiting to \(maxChunks)")
            throw TranscriptionError.fileTooLarge(duration: duration, maxDuration: maxSafeDuration)
        }
        
        var allSegments: [TranscriptSegment] = []
        var allText: [String] = []
        var currentOffset: TimeInterval = 0
        
for (index, chunk) in chunks.enumerated() {
            currentStatus = "Processing chunk \(index + 1) of \(chunks.count)..."
            
            // Update progress
            progress = TranscriptionProgress(
                currentChunk: index + 1,
                totalChunks: chunks.count,
                processedDuration: currentOffset,
                totalDuration: duration,
                currentText: allText.joined(separator: " "),
                isComplete: false,
                error: nil
            )
            
            
            do {
                // Check if transcription was cancelled
                guard isTranscribing else {
                    print("🛑 Transcription cancelled during chunk \(index + 1) processing")
                    throw TranscriptionError.recognitionFailed(NSError(domain: "TranscriptionCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transcription was cancelled by user or system"]))
                }
                
                // Check if speech recognizer is still available
                guard let recognizer = speechRecognizer else {
                    print("❌ Speech recognizer is nil during chunk \(index + 1)")
                    isTranscribing = false
                    currentStatus = "Speech recognition unavailable - recognizer is nil"
                    throw TranscriptionError.speechRecognizerUnavailable
                }
                
                guard recognizer.isAvailable else {
                    print("❌ Speech recognizer became unavailable during chunk \(index + 1)")
                    print("🔧 Recognizer locale: \(recognizer.locale.identifier)")
                    print("🔧 Authorization status: \(SFSpeechRecognizer.authorizationStatus().rawValue)")
                    isTranscribing = false
                    currentStatus = "Speech recognition unavailable"
                    throw TranscriptionError.speechRecognizerUnavailable
                }
                
                // Add timeout for individual chunk processing
                let chunkResult = try await withThrowingTaskGroup(of: TranscriptionResult.self) { group in
                    group.addTask {
                        try await self.transcribeChunk(url: url, startTime: chunk.start, endTime: chunk.end)
                    }
                    
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(180 * 1_000_000_000)) // 3 minute timeout per chunk
                        throw TranscriptionError.timeout
                    }
                    
                    guard let result = try await group.next() else {
                        throw TranscriptionError.timeout
                    }
                    
                    group.cancelAll()
                    return result
                }
                
                // Adjust segment timestamps
                let adjustedSegments = chunkResult.segments.map { segment in
                    TranscriptSegment(
                        speaker: segment.speaker,
                        text: segment.text,
                        startTime: segment.startTime + currentOffset,
                        endTime: segment.endTime + currentOffset
                    )
                }
                
allSegments.append(contentsOf: adjustedSegments)
                allText.append(chunkResult.fullText)
                currentOffset = chunk.end
                
                // Check memory pressure after each chunk
                autoreleasepool { }
                checkMemoryPressure()
                
} catch {
                // Clean up resources on error
                isTranscribing = false
                currentStatus = "Chunk \(index + 1) failed"
                progress = TranscriptionProgress(
                    currentChunk: index + 1,
                    totalChunks: chunks.count,
                    processedDuration: currentOffset,
                    totalDuration: duration,
                    currentText: allText.joined(separator: " "),
                    isComplete: false,
                    error: error
                )
                
                // Force cleanup on error
                checkMemoryPressure()
                
                throw TranscriptionError.chunkProcessingFailed(chunk: index + 1, error: error)
            }
            
// Check timeout more frequently
            let elapsedTime = Date().timeIntervalSince(startTime)
            if elapsedTime > maxTranscriptionTime {
                // Clean up resources on timeout
                isTranscribing = false
                currentStatus = "Transcription timeout"
                
                // Force cleanup on timeout
                checkMemoryPressure()
                
                throw TranscriptionError.timeout
            }
            
            
            // Add a longer delay between chunks to prevent overwhelming the system
            try await Task.sleep(nanoseconds: UInt64(2.0 * 1_000_000_000)) // 2 second delay
            
            // Check if transcription was cancelled during the delay
            guard isTranscribing else {
                print("🛑 Transcription was cancelled during delay")
                throw TranscriptionError.recognitionFailed(NSError(domain: "TranscriptionCancelled", code: -1, userInfo: nil))
            }
        }
        
        let processingTime = Date().timeIntervalSince(startTime)
        let fullText = allText.joined(separator: " ")
        
        // Final cleanup
        isTranscribing = false
        currentStatus = "Transcription complete"
        progress = TranscriptionProgress(
            currentChunk: chunks.count,
            totalChunks: chunks.count,
            processedDuration: duration,
            totalDuration: duration,
            currentText: fullText,
            isComplete: true,
            error: nil
        )
        
        // Force final memory cleanup
        checkMemoryPressure()
        
        print("🎉 Large file transcription completed in \(processingTime/60) minutes")
        
        // Debug: Check if the transcript contains placeholder text
        if fullText.lowercased().contains("loading") {
            print("⚠️ WARNING: Transcript contains 'loading' text!")
            print("📝 Full transcript preview: \(fullText.prefix(200))")
            print("🔍 Checking segments for placeholder text...")
            for (index, segment) in allSegments.enumerated() {
                if segment.text.lowercased().contains("loading") {
                    print("⚠️ Segment \(index) contains 'loading': \(segment.text)")
                }
            }
        }
        
        return TranscriptionResult(
            fullText: fullText,
            segments: allSegments,
            processingTime: processingTime,
            chunkCount: chunks.count,
            success: true,
            error: nil
        )
    }
    
    private func transcribeChunk(url: URL, startTime: TimeInterval, endTime: TimeInterval) async throws -> TranscriptionResult {
        print("🎵 Extracting chunk from \(startTime/60) to \(endTime/60) minutes...")
        
        // Create a temporary audio file for the chunk
        let chunkURL = try await extractAudioChunk(from: url, startTime: startTime, endTime: endTime)
        print("✅ Chunk extracted to: \(chunkURL.lastPathComponent)")
        
        defer {
            try? FileManager.default.removeItem(at: chunkURL)
            print("🗑️ Cleaned up temporary chunk file")
        }
        
        print("🎤 Transcribing chunk...")
        return try await transcribeSingleChunk(url: chunkURL)
    }
    
    private func extractAudioChunk(from url: URL, startTime: TimeInterval, endTime: TimeInterval) async throws -> URL {
        print("🔧 Creating audio composition...")
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        
        guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscriptionError.audioExtractionFailed
        }
        
        let timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            duration: CMTime(seconds: endTime - startTime, preferredTimescale: 600)
        )
        
        try audioTrack.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
        
        // Export the chunk with proper async handling and timeout
        let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("chunk_\(UUID().uuidString).m4a")
        
        print("📤 Exporting chunk to: \(outputURL.lastPathComponent)")
        
        exportSession?.outputURL = outputURL
        exportSession?.outputFileType = .m4a
        
        guard let session = exportSession else {
            print("❌ Failed to create export session")
            throw TranscriptionError.audioExtractionFailed
        }
        
        print("⏳ Starting export...")
        
        // Use async/await with timeout and progress monitoring
        return try await withThrowingTaskGroup(of: URL.self) { group in
                                            // Export task
                group.addTask { [weak session] in
                    // Unwrap session before the continuation to avoid sendability issues
                    guard let session = session else {
                        throw TranscriptionError.audioExtractionFailed
                    }
                    
                    // Use the modern async/await approach directly
                    if #available(iOS 18.0, *) {
                        // Use the new export method for iOS 18+
                        try await session.export(to: outputURL, as: .m4a)
                    } else {
                        // For iOS < 18, use the deprecated but available export method
                        await session.export()
                    }
                    
                    return outputURL
                }
            
            // Timeout task
            group.addTask { [weak session] in
                try await Task.sleep(nanoseconds: UInt64(120 * 1_000_000_000)) // 2 minute timeout
                print("⏰ Chunk export timeout reached, cancelling...")
                session?.cancelExport()
                throw TranscriptionError.timeout
            }
            
            // Return the first completed task (either success or timeout)
            guard let result = try await group.next() else {
                throw TranscriptionError.timeout
            }
            
            // Cancel remaining tasks
            group.cancelAll()
            return result
        }
    }
    
    private func calculateChunks(duration: TimeInterval) -> [(start: TimeInterval, end: TimeInterval)] {
        var chunks: [(start: TimeInterval, end: TimeInterval)] = []
        var currentStart: TimeInterval = 0
        
        // Limit chunk size to prevent memory issues
        let maxSafeChunkDuration: TimeInterval = 300 // 5 minutes max per chunk
        let actualChunkDuration = min(maxChunkDuration, maxSafeChunkDuration)
        
        // Ensure overlap is smaller than chunk duration to prevent infinite loops
        let safeOverlap = min(chunkOverlap, actualChunkDuration * 0.1) // Max 10% of chunk duration
        let minAdvancement: TimeInterval = 1.0 // Minimum 1 second advancement to prevent infinite loops
        
        while currentStart < duration {
            let currentEnd = min(currentStart + actualChunkDuration, duration)
            chunks.append((start: currentStart, end: currentEnd))
            
            // Calculate next start position with safety checks
            let nextStart = currentEnd - safeOverlap
            let advancement = nextStart - currentStart
            
            // Ensure we always advance by at least the minimum amount to prevent infinite loops
            if advancement < minAdvancement {
                currentStart = currentStart + minAdvancement
            } else {
                currentStart = nextStart
            }
            
            // Safety check: if we're not making progress, break to prevent infinite loop
            if currentStart >= currentEnd {
                print("⚠️ Breaking chunk calculation to prevent infinite loop")
                break
            }
        }
        
        return chunks
    }
    
    private func createSegments(from transcription: SFTranscription) -> [TranscriptSegment] {
        let fullText = transcription.formattedString
        
        if fullText.isEmpty {
            return []
        }
        
        // For single-file transcription, create one continuous segment
        // This prevents the UI from showing multiple 30-second blocks
        guard let firstSegment = transcription.segments.first,
              let lastSegment = transcription.segments.last else {
            return []
        }
        
        let singleSegment = TranscriptSegment(
            speaker: "Speaker",
            text: fullText,
            startTime: firstSegment.timestamp,
            endTime: lastSegment.timestamp + lastSegment.duration
        )
        
        return [singleSegment]
    }
    
    // MARK: - AWS Transcription
    
private func transcribeWithAWS(url: URL, config: AWSTranscribeConfig) async throws -> TranscriptionResult {
        
        let awsService = AWSTranscribeService(config: config, chunkingService: chunkingService)
        
        do {
// Start the transcription job asynchronously
            let jobName = try await awsService.startTranscriptionJob(url: url)
            
            // Add job to pending list for background checking
            addPendingJob(jobName, recordingURL: url, recordingName: url.lastPathComponent)
            
            // Start background checking if not already running
            startBackgroundChecking()
            
            // Now wait for the job to complete by polling
            return try await waitForAndRetrieveTranscription(jobName: jobName, awsService: awsService)
            
        } catch {
            print("❌ AWS Transcribe failed: \(error)")
            throw TranscriptionError.awsTranscriptionFailed(error)
        }
    }
    
    /// Wait for a transcription job to complete and retrieve the result
private func waitForAndRetrieveTranscription(jobName: String, awsService: AWSTranscribeService) async throws -> TranscriptionResult {
        let maxWaitTime: TimeInterval = 3600 // 1 hour max wait
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            do {
                let status = try await awsService.checkJobStatus(jobName: jobName)
                
                
                switch status.status {
case .completed:
                    let awsResult = try await awsService.retrieveTranscript(jobName: jobName)
                    
                    // Remove from pending jobs since it's complete
                    removePendingJob(jobName)
                    
                    let transcriptionResult = TranscriptionResult(
                        fullText: awsResult.transcriptText,
                        segments: awsResult.segments,
                        processingTime: Date().timeIntervalSince(startTime),
                        chunkCount: 1,
                        success: true,
                        error: nil
                    )
                    
                    return transcriptionResult
                    
case .failed:
                    let errorMessage = status.failureReason ?? "Unknown error"
                    removePendingJob(jobName)
                    throw TranscriptionError.awsTranscriptionFailed(NSError(domain: "AWSTranscribe", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
                    
case .inProgress:
                    // Wait 30 seconds before checking again
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    
default:
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                }
                
            } catch {
                print("⚠️ Error checking job status: \(error), retrying in 30 seconds...")
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        
// If we get here, the job timed out
        removePendingJob(jobName)
        throw TranscriptionError.awsTranscriptionFailed(NSError(domain: "AWSTranscribe", code: -2, userInfo: [NSLocalizedDescriptionKey: "Transcription job timed out after \(Int(maxWaitTime/60)) minutes"]))
    }
    
private func removePendingJob(_ jobName: String) {
        pendingJobs.removeAll { $0.jobName == jobName }
        savePendingJobs()
    }
    
/// Start an async transcription job and return the job name
    func startAsyncTranscription(url: URL, config: AWSTranscribeConfig) async throws -> String {
        
        let awsService = AWSTranscribeService(config: config, chunkingService: chunkingService)
        let jobName = try await awsService.startTranscriptionJob(url: url)
        
        // Track this job for later checking
        addPendingJob(jobName, recordingURL: url, recordingName: url.lastPathComponent)
        
return jobName
    }
    
    /// Check the status of a transcription job
    func checkTranscriptionStatus(jobName: String, config: AWSTranscribeConfig) async throws -> AWSTranscribeJobStatus {
        let awsService = AWSTranscribeService(config: config, chunkingService: chunkingService)
        return try await awsService.checkJobStatus(jobName: jobName)
    }
    
    /// Retrieve a completed transcript
    func retrieveTranscription(jobName: String, config: AWSTranscribeConfig) async throws -> TranscriptionResult {
        let awsService = AWSTranscribeService(config: config, chunkingService: chunkingService)
        let awsResult = try await awsService.retrieveTranscript(jobName: jobName)
        
// Convert AWS result to our TranscriptionResult format
        
        let transcriptionResult = TranscriptionResult(
            fullText: awsResult.transcriptText,
            segments: awsResult.segments,
            processingTime: awsResult.processingTime,
            chunkCount: 1,
            success: awsResult.success,
            error: awsResult.error
        )
        
return transcriptionResult
    }
    
    /// Check for any completed transcription jobs and retrieve them
    func checkForCompletedTranscriptions(config: AWSTranscribeConfig) async -> [TranscriptionResult] {
        let jobNames = getPendingJobNames()
        var completedResults: [TranscriptionResult] = []
        var stillPendingJobs: [String] = []
        
        for jobName in jobNames {
            do {
                let status = try await checkTranscriptionStatus(jobName: jobName, config: config)
                
if status.isCompleted {
                    let result = try await retrieveTranscription(jobName: jobName, config: config)
                    completedResults.append(result)
                } else if status.isFailed {
                    // Remove failed jobs from pending list
                } else {
                    stillPendingJobs.append(jobName)
                }
            } catch {
                print("❌ Error checking job \(jobName): \(error)")
                // Keep job in pending list if we can't check it
                stillPendingJobs.append(jobName)
            }
        }
        
        // Update pending jobs list
        updatePendingJobNames(stillPendingJobs)
        
        return completedResults
    }
    
    // MARK: - Whisper Transcription
    
    private func transcribeWithWhisper(url: URL, config: WhisperConfig) async throws -> TranscriptionResult {
        beginBackgroundTask()
        defer { endBackgroundTask() }


        let whisperService = WhisperService(config: config, chunkingService: chunkingService)
        
        do {
// Test connection first
            let isConnected = await whisperService.testConnection()
            guard isConnected else {
                throw TranscriptionError.whisperConnectionFailed
            }
            
            // Get audio duration to determine if we need chunking
            let duration = try await getAudioDuration(url: url)
            
let result: TranscriptionResult
            if duration > maxChunkDuration && enableEnhancedTranscription {
                result = try await whisperService.transcribeAudioInChunks(url: url, chunkDuration: maxChunkDuration)
            } else {
                result = try await whisperService.transcribeAudio(url: url)
            }
            
return result
            
        } catch {
            throw TranscriptionError.whisperTranscriptionFailed(error)
        }
    }
    
    // MARK: - OpenAI Transcription
    
private func transcribeWithOpenAI(url: URL, config: OpenAITranscribeConfig) async throws -> TranscriptionResult {
        
        let openAIService = OpenAITranscribeService(config: config, chunkingService: chunkingService)
        
        do {
// Test connection first
            try await openAIService.testConnection()
            
            // OpenAI has a 25MB file size limit, so we don't need chunking for most files
            // But we should check the file size
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0
            let maxSize: Int64 = 25 * 1024 * 1024 // 25MB
            
if fileSize > maxSize {
                return try await transcribeWithChunkedOpenAI(url: url)
            }
            
let openAIResult = try await openAIService.transcribeAudioFile(at: url)
            
            // Convert OpenAI result to our TranscriptionResult format
            let transcriptionResult = TranscriptionResult(
                fullText: openAIResult.transcriptText,
                segments: openAIResult.segments,
                processingTime: openAIResult.processingTime,
                chunkCount: 1,
                success: openAIResult.success,
                error: openAIResult.error
            )
            
return transcriptionResult
            
        } catch {
            print("❌ OpenAI transcription failed: \(error)")
            throw TranscriptionError.openAITranscriptionFailed(error)
        }
    }
    
private func transcribeWithChunkedOpenAI(url: URL) async throws -> TranscriptionResult {
        
        guard let openAIConfig = openAIConfig else {
            throw TranscriptionError.openAITranscriptionFailed(TranscriptionError.fileNotFound)
        }
        
        do {
            // Create OpenAI service with config
            let openAIService = OpenAITranscribeService(config: openAIConfig, chunkingService: chunkingService)
            
// Use the chunking service to chunk the file
            let chunkingResult = try await chunkingService.chunkAudioFile(url, for: .openAI)
            let chunks = chunkingResult.chunks
            
            var allTranscripts: [String] = []
            var allSegments: [TranscriptSegment] = []
            var totalProcessingTime: TimeInterval = 0
            var chunkIndex = 0
            
for chunk in chunks {
                chunkIndex += 1
                
                let startTime = Date()
                let openAIResult = try await openAIService.transcribeAudioFile(at: chunk.chunkURL)
                let processingTime = Date().timeIntervalSince(startTime)
                totalProcessingTime += processingTime
                
                // Add the transcript text
                allTranscripts.append(openAIResult.transcriptText)
                
                // Adjust segment timestamps to account for chunk start time
                let adjustedSegments = openAIResult.segments.map { segment in
                    TranscriptSegment(
                        speaker: "Speaker",
                        text: segment.text,
                        startTime: segment.startTime + chunk.startTime,
                        endTime: segment.endTime + chunk.startTime
                    )
                }
                allSegments.append(contentsOf: adjustedSegments)
                
            }
            
            // Combine all transcripts
            let fullTranscript = allTranscripts.joined(separator: " ")
            
            let transcriptionResult = TranscriptionResult(
                fullText: fullTranscript,
                segments: allSegments,
                processingTime: totalProcessingTime,
                chunkCount: chunks.count,
                success: true,
                error: nil
            )
            
return transcriptionResult
            
        } catch {
            print("❌ Chunked OpenAI transcription failed: \(error)")
            throw TranscriptionError.openAITranscriptionFailed(error)
        }
    }
    
    // MARK: - Job Tracking Helpers
    
/// Update pending jobs when recording files are renamed
    func updatePendingJobsForRenamedRecording(from oldURL: URL, to newURL: URL, newName: String) {
        
        var updatedJobs: [TranscriptionJobInfo] = []
        var updated = false
        
for job in pendingJobs {
            if job.recordingURL == oldURL {
                let updatedJob = TranscriptionJobInfo(
                    jobName: job.jobName,
                    recordingURL: newURL,
                    recordingName: newName,
                    startDate: job.startDate
                )
                updatedJobs.append(updatedJob)
                updated = true
            } else {
                updatedJobs.append(job)
            }
        }
        
if updated {
            pendingJobs = updatedJobs
            savePendingJobs()
        }
    }
    
    private func addPendingJob(_ jobName: String, recordingURL: URL, recordingName: String) {
        let jobInfo = TranscriptionJobInfo(
            jobName: jobName,
            recordingURL: recordingURL,
            recordingName: recordingName,
            startDate: Date()
        )
        
if !pendingJobs.contains(where: { $0.jobName == jobName }) {
            pendingJobs.append(jobInfo)
            savePendingJobs()
        }
    }
    
    private func getPendingJobNames() -> [String] {
        return pendingJobs.map { $0.jobName }
    }
    
    private func getPendingJobInfo(for jobName: String) -> TranscriptionJobInfo? {
        return pendingJobs.first { $0.jobName == jobName }
    }
    
    private func updatePendingJobNames(_ jobNames: [String]) {
        // Remove jobs that are no longer in the list
        pendingJobs.removeAll { !jobNames.contains($0.jobName) }
        savePendingJobs()
    }
    
private func loadPendingJobs() {
        if let data = UserDefaults.standard.data(forKey: "pendingTranscriptionJobInfos"),
           let jobs = try? JSONDecoder().decode([TranscriptionJobInfo].self, from: data) {
            pendingJobs = jobs
        }
    }
    
    private func savePendingJobs() {
        if let data = try? JSONEncoder().encode(pendingJobs) {
            UserDefaults.standard.set(data, forKey: "pendingTranscriptionJobInfos")
        }
    }
    
    // MARK: - Background Checking
    
private func startBackgroundChecking() {
        guard !isBackgroundChecking else { return }
        
        isBackgroundChecking = true
        
        // Check every 30 seconds for completed transcriptions
        backgroundCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForCompletedTranscriptionsInBackground()
            }
        }
    }
    
private func stopBackgroundChecking() {
        backgroundCheckTimer?.invalidate()
        backgroundCheckTimer = nil
        isBackgroundChecking = false
    }
    
    // MARK: - Engine Management
    
func switchToAppleTranscription() {
        stopBackgroundChecking()
        
        // Clear any pending AWS jobs since we're not using AWS anymore
        let pendingCount = getPendingJobNames().count
        if pendingCount > 0 {
            clearAllPendingJobs()
        }
        
        // Also disable AWS transcription in settings to prevent future background checks
        UserDefaults.standard.set(false, forKey: "enableAWSTranscribe")
    }
    
func switchToAWSTranscription() {
        if awsConfig != nil {
            if !isBackgroundChecking {
                startBackgroundChecking()
            }
        }
    }
    
func switchToWhisperTranscription() {
        // Whisper doesn't use background checking like AWS, so we stop any existing background processes
        stopBackgroundChecking()
        
        // Clear any pending AWS jobs since we're switching to Whisper
        let pendingCount = getPendingJobNames().count
        if pendingCount > 0 {
            clearAllPendingJobs()
        }
        
        if whisperConfig != nil {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLogger.shared.verbose("Whisper transcription configured and ready", category: "EnhancedTranscriptionManager")
            }
        } else {
            AppLogger.shared.warning("Whisper transcription selected but not configured", category: "EnhancedTranscriptionManager")
        }
    }
    
    /// Public method to update transcription engine and manage background processes
    func updateTranscriptionEngine(_ engine: TranscriptionEngine) {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Updating transcription engine to: \(engine.rawValue)", category: "EnhancedTranscriptionManager")
        }
        
        switch engine {
        case .awsTranscribe:
            switchToAWSTranscription()
        case .whisper, .whisperWyoming:
            switchToWhisperTranscription()
        case .appleIntelligence, .openAI, .openAIAPICompatible:
            switchToAppleTranscription()
        }
    }
    
    private func clearAllPendingJobs() {
        pendingJobs.removeAll()
        pendingJobNames = ""
        UserDefaults.standard.set("", forKey: "pendingTranscriptionJobs")
        savePendingJobs()
    }
    
    private func checkForCompletedTranscriptionsInBackground() async {
        // Only check if AWS is enabled, configured, AND we have pending jobs
guard enableAWSTranscribe else {
            stopBackgroundChecking()
            clearAllPendingJobs()
            return
        }
        
        guard let config = awsConfig else { 
            stopBackgroundChecking()
            return 
        }
        
        let jobNames = getPendingJobNames()
guard !jobNames.isEmpty else { 
            return 
        }
        
        var stillPendingJobs: [String] = []
        
        for jobName in jobNames {
            do {
                let status = try await checkTranscriptionStatus(jobName: jobName, config: config)
                
if status.isCompleted {
                    let result = try await retrieveTranscription(jobName: jobName, config: config)
                    
                    // Get job info before removing it
                    let jobInfo = getPendingJobInfo(for: jobName)
                    
                    // Remove from pending jobs
                    removePendingJob(jobName)
                    
                    // Notify completion
                    if let jobInfo = jobInfo {
                        onTranscriptionCompleted?(result, jobInfo)
                    }
                    
} else if status.isFailed {
                    // Remove failed jobs from pending list
                    removePendingJob(jobName)
                } else {
                    stillPendingJobs.append(jobName)
                }
            } catch {
                print("❌ Background check: Error checking job \(jobName): \(error)")
                // Keep job in pending list if we can't check it
                stillPendingJobs.append(jobName)
            }
        }
        
        // Update pending jobs list
        if stillPendingJobs != jobNames {
            updatePendingJobNames(stillPendingJobs)
        }
    }
    
    // MARK: - Error Handling
    
    private func isNonCriticalSpeechRecognitionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        
        // Known non-critical errors that can be safely ignored
        let nonCriticalErrors: [(domain: String, code: Int)] = [
            ("kAFAssistantErrorDomain", 1101), // Local speech recognition service error
            ("kAFAssistantErrorDomain", 1100), // Another common local speech recognition error
            ("com.apple.speech.recognition.error", 203), // Recognition service temporarily unavailable
            ("com.apple.speech.recognition.error", 204)  // Recognition service busy
        ]
        
        for (domain, code) in nonCriticalErrors {
            if nsError.domain == domain && nsError.code == code {
                return true
            }
        }
        
        return false
    }
    
    private func handleSpeechRecognitionError(_ error: Error) -> Bool {
        if isNonCriticalSpeechRecognitionError(error) {
            print("⚠️ Non-critical speech recognition error (safe to ignore): \(error.localizedDescription)")
            return true // Error was handled
        }
        
        print("❌ Critical speech recognition error: \(error)")
        return false // Error was not handled, should be treated as critical
    }
}


// MARK: - Extensions

extension Double {
    var nonZero: Double? {
        return self > 0 ? self : nil
    }
}

// MARK: - SFSpeechRecognizerDelegate

extension EnhancedTranscriptionManager: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available {
            Task { @MainActor in
                self.currentStatus = "Speech recognition unavailable"
                // Reset the speech recognizer to try to recover
                self.speechRecognizer = nil
                self.setupSpeechRecognizer()
            }
        }
    }
}

// MARK: - Transcription Errors

enum TranscriptionError: LocalizedError {
    case fileNotFound
    case speechRecognizerUnavailable
    case recognitionFailed(Error)
    case noSpeechDetected
    case chunkProcessingFailed(chunk: Int, error: Error)
    case audioExtractionFailed
    case timeout
    case fileTooLarge(duration: TimeInterval, maxDuration: TimeInterval)
    case awsTranscriptionFailed(Error)
    case awsNotConfigured
    case whisperConnectionFailed
    case whisperTranscriptionFailed(Error)
    case openAITranscriptionFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Audio file not found"
        case .speechRecognizerUnavailable:
            return "Speech recognition is not available. This may be due to simulator limitations, missing permissions, or device restrictions. Try running on a physical device or check Settings > Privacy & Security > Speech Recognition."
        case .recognitionFailed(let error):
            return "Recognition failed: \(error.localizedDescription)"
        case .noSpeechDetected:
            return "No speech detected in the audio file"
        case .chunkProcessingFailed(let chunk, let error):
            return "Failed to process chunk \(chunk): \(error.localizedDescription)"
        case .audioExtractionFailed:
            return "Failed to extract audio chunk"
        case .timeout:
            return "Transcription timed out"
        case .awsTranscriptionFailed(let error):
            return "AWS Transcribe failed: \(error.localizedDescription)"
        case .awsNotConfigured:
            return "AWS Transcribe is not properly configured. Please check your AWS credentials in settings."
        case .whisperConnectionFailed:
            return "Failed to connect to Whisper service"
        case .whisperTranscriptionFailed(let error):
            return "Whisper transcription failed: \(error.localizedDescription)"
        case .openAITranscriptionFailed(let error):
            return "OpenAI transcription failed: \(error.localizedDescription)"
        case .fileTooLarge(let duration, let maxDuration):
            return "File too large for processing (\(Int(duration/60)) minutes, max \(Int(maxDuration/60)) minutes)"
        }
    }
}