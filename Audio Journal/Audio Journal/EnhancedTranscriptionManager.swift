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
        UserDefaults.standard.double(forKey: "chunkOverlap").nonZero ?? 30.0 // 30 second overlap between chunks
    }
    
    private var enableAWSTranscribe: Bool {
        return UserDefaults.standard.bool(forKey: "enableAWSTranscribe")
    }
    
    // AWS Configuration
    private var awsConfig: AWSTranscribeConfig? {
        guard enableAWSTranscribe else { return nil }
        
        let accessKey = UserDefaults.standard.string(forKey: "awsAccessKey") ?? ""
        let secretKey = UserDefaults.standard.string(forKey: "awsSecretKey") ?? ""
        let region = UserDefaults.standard.string(forKey: "awsRegion") ?? "us-east-1"
        let bucketName = UserDefaults.standard.string(forKey: "awsBucketName") ?? ""
        
        guard !accessKey.isEmpty && !secretKey.isEmpty && !bucketName.isEmpty else {
            return nil
        }
        
        return AWSTranscribeConfig(
            region: region,
            accessKey: accessKey,
            secretKey: secretKey,
            bucketName: bucketName
        )
    }
    
    // Whisper Configuration
    private var whisperConfig: WhisperConfig? {
        let isEnabled = UserDefaults.standard.bool(forKey: "enableWhisper")
        let serverURL = UserDefaults.standard.string(forKey: "whisperServerURL") ?? "http://localhost"
        let port = UserDefaults.standard.integer(forKey: "whisperPort")
        
        print("🔍 Whisper config debug - enabled: \(isEnabled), serverURL: \(serverURL), port: \(port)")
        
        guard isEnabled else { 
            print("⚠️ Whisper is not enabled")
            return nil 
        }
        
        // Use default port if not set (UserDefaults.integer returns 0 if key doesn't exist)
        let effectivePort = port > 0 ? port : 9000
        
        let config = WhisperConfig(
            serverURL: serverURL,
            port: effectivePort
        )
        
        print("✅ Whisper config created: \(config.baseURL)")
        return config
    }
    
    // OpenAI Configuration
    private var openAIConfig: OpenAITranscribeConfig? {
        let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
        let modelString = UserDefaults.standard.string(forKey: "openAIModel") ?? OpenAITranscribeModel.whisper1.rawValue
        let baseURL = UserDefaults.standard.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
        
        print("🔍 OpenAI config debug - apiKey length: \(apiKey.count), model: \(modelString), baseURL: \(baseURL)")
        
        guard !apiKey.isEmpty else {
            print("⚠️ OpenAI API key is not configured")
            return nil
        }
        
        let model = OpenAITranscribeModel(rawValue: modelString) ?? .whisper1
        
        let config = OpenAITranscribeConfig(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL
        )
        
        print("✅ OpenAI config created with model: \(model.displayName)")
        return config
    }
    
    // MARK: - Whisper Validation
    
    func isWhisperProperlyConfigured() -> Bool {
        let isEnabled = UserDefaults.standard.bool(forKey: "enableWhisper")
        let serverURL = UserDefaults.standard.string(forKey: "whisperServerURL")
        let port = UserDefaults.standard.integer(forKey: "whisperPort")
        
        print("🔍 Whisper validation debug - enabled: \(isEnabled), serverURL: \(serverURL ?? "nil"), port: \(port)")
        
        guard isEnabled else {
            print("⚠️ Whisper is not enabled in settings")
            return false
        }
        
        guard let serverURL = serverURL, !serverURL.isEmpty else {
            print("⚠️ Whisper server URL is not configured")
            return false
        }
        
        // Use default port if not set (UserDefaults.integer returns 0 if key doesn't exist)
        let effectivePort = port > 0 ? port : 9000
        
        print("✅ Whisper configuration appears valid (effective port: \(effectivePort))")
        return true
    }
    
    func validateWhisperService() async -> Bool {
        guard isWhisperProperlyConfigured() else {
            return false
        }
        
        guard let config = whisperConfig else {
            return false
        }
        
        let whisperService = WhisperService(config: config)
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
        print("ℹ️ Transcription manager initialized, background checks will be managed by engine selection")
    }
    
    private func setupSpeechRecognizer() {
        print("🔧 Setting up speech recognizer...")
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechRecognizer?.delegate = self
        
        if speechRecognizer == nil {
            print("❌ Failed to create speech recognizer")
        } else {
            print("✅ Speech recognizer created successfully")
            print("🔍 Speech recognizer available: \(speechRecognizer?.isAvailable ?? false)")
        }
    }
    
    // MARK: - Public Methods
    
    func transcribeAudioFile(at url: URL, using engine: TranscriptionEngine? = nil) async throws -> TranscriptionResult {
        print("🎯 Starting transcription for: \(url.lastPathComponent)")
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ File not found: \(url.path)")
            throw TranscriptionError.fileNotFound
        }
        
        // Validate audio file before transcription
        do {
            let testPlayer = try AVAudioPlayer(contentsOf: url)
            print("📊 Audio file validation - Duration: \(testPlayer.duration)s, Channels: \(testPlayer.numberOfChannels)")
            guard testPlayer.duration > 0 else {
                print("❌ Audio file has no content")
                throw TranscriptionError.noSpeechDetected
            }
        } catch {
            print("❌ Audio file validation failed: \(error)")
            throw TranscriptionError.audioExtractionFailed
        }
        
        // Check file duration
        let duration = try await getAudioDuration(url: url)
        print("📏 File duration: \(duration) seconds (\(duration/60) minutes)")
        
        // Determine transcription engine to use
        let selectedEngine = engine ?? .appleIntelligence // Default fallback
        print("🔧 Using transcription engine: \(selectedEngine.rawValue)")
        
        // Manage background checking based on selected engine
        switch selectedEngine {
        case .awsTranscribe:
            switchToAWSTranscription()
            if let config = awsConfig {
                print("☁️ Using AWS Transcribe for transcription")
                return try await transcribeWithAWS(url: url, config: config)
            } else {
                print("⚠️ AWS Transcribe selected but not configured, falling back to Apple Intelligence")
                switchToAppleTranscription()
                return try await transcribeWithAppleIntelligence(url: url, duration: duration)
            }
            
        case .appleIntelligence:
            switchToAppleTranscription()
            return try await transcribeWithAppleIntelligence(url: url, duration: duration)
            
        case .whisper:
            switchToWhisperTranscription()
            
            // Validate Whisper configuration and availability
            if !isWhisperProperlyConfigured() {
                print("⚠️ Whisper not properly configured, falling back to Apple Intelligence")
                switchToAppleTranscription()
                return try await transcribeWithAppleIntelligence(url: url, duration: duration)
            }
            
            let isWhisperAvailable = await validateWhisperService()
            if isWhisperAvailable {
                print("🎤 Using Whisper for transcription")
                if let config = whisperConfig {
                    return try await transcribeWithWhisper(url: url, config: config)
                } else {
                    print("❌ Whisper config is nil despite validation passing")
                    switchToAppleTranscription()
                    return try await transcribeWithAppleIntelligence(url: url, duration: duration)
                }
            } else {
                print("⚠️ Whisper service not available, falling back to Apple Intelligence")
                switchToAppleTranscription()
                return try await transcribeWithAppleIntelligence(url: url, duration: duration)
            }
            
        case .openAI:
            switchToAppleTranscription() // OpenAI doesn't need background checking
            
            // Validate OpenAI configuration
            if let config = openAIConfig {
                print("🤖 Using OpenAI for transcription")
                return try await transcribeWithOpenAI(url: url, config: config)
            } else {
                print("⚠️ OpenAI not properly configured, falling back to Apple Intelligence")
                return try await transcribeWithAppleIntelligence(url: url, duration: duration)
            }
            
        case .openAIAPICompatible:
            // These are not implemented yet, fall back to Apple Intelligence
            print("⚠️ \(selectedEngine.rawValue) not yet implemented, falling back to Apple Intelligence")
            switchToAppleTranscription()
            return try await transcribeWithAppleIntelligence(url: url, duration: duration)
        }
    }
    
    private func transcribeWithAppleIntelligence(url: URL, duration: TimeInterval) async throws -> TranscriptionResult {
        // Use the existing logic for Apple Intelligence transcription
        if !enableEnhancedTranscription || duration <= maxChunkDuration {
            print("🔄 Using single chunk transcription (duration: \(duration)s, maxChunk: \(maxChunkDuration)s, enhanced: \(enableEnhancedTranscription))")
            return try await transcribeSingleChunk(url: url)
        } else {
            print("🔀 Using chunked transcription for large file")
            return try await transcribeLargeFile(url: url, duration: duration)
        }
    }
    
    func cancelTranscription() {
        currentTask?.cancel()
        isTranscribing = false
        progress = nil
        currentStatus = "Transcription cancelled"
    }
    
    /// Manually check for completed transcriptions
    func checkForCompletedTranscriptions() async {
        // Only check if AWS is enabled and configured
        guard enableAWSTranscribe else {
            print("ℹ️ Manual check: AWS transcription not enabled, skipping check")
            return
        }
        
        guard let config = awsConfig else { 
            print("❌ Manual check: No AWS config available")
            return 
        }
        
        let jobNames = getPendingJobNames()
        guard !jobNames.isEmpty else { 
            print("❌ Manual check: No pending jobs found")
            return 
        }
        
        print("🔍 Manual check: Checking \(jobNames.count) pending transcription jobs...")
        print("📋 Pending jobs: \(jobNames)")
        
        var stillPendingJobs: [String] = []
        
        for jobName in jobNames {
            do {
                let status = try await checkTranscriptionStatus(jobName: jobName, config: config)
                
                if status.isCompleted {
                    print("✅ Manual check: Found completed job: \(jobName)")
                    let result = try await retrieveTranscription(jobName: jobName, config: config)
                    
                    // Get job info before removing it
                    let jobInfo = getPendingJobInfo(for: jobName)
                    
                    // Remove from pending jobs
                    removePendingJob(jobName)
                    
                    // Notify completion
                    if let jobInfo = jobInfo {
                        print("🔔 Manual check: Calling onTranscriptionCompleted callback for job: \(jobName)")
                        print("🔔 Manual check: Job info: \(jobInfo.recordingName) - \(jobInfo.recordingURL)")
                        print("🔔 Manual check: Result text length: \(result.fullText.count)")
                        onTranscriptionCompleted?(result, jobInfo)
                        print("🔔 Manual check: Callback completed")
                    } else {
                        print("❌ Manual check: No job info found for completed job: \(jobName)")
                    }
                    
                } else if status.isFailed {
                    print("❌ Manual check: Job failed: \(jobName) - \(status.failureReason ?? "Unknown error")")
                    // Remove failed jobs from pending list
                    removePendingJob(jobName)
                } else {
                    print("⏳ Manual check: Job still pending: \(jobName)")
                    stillPendingJobs.append(jobName)
                }
            } catch {
                print("❌ Manual check: Error checking job \(jobName): \(error)")
                // Keep job in pending list if we can't check it
                stillPendingJobs.append(jobName)
            }
        }
        
        // Update pending jobs list
        if stillPendingJobs != jobNames {
            updatePendingJobNames(stillPendingJobs)
        }
    }
    
    /// Manually add a job for tracking (useful for testing)
    func addJobForTracking(jobName: String, recordingURL: URL, recordingName: String) {
        addPendingJob(jobName, recordingURL: recordingURL, recordingName: recordingName)
        print("📝 Manually added job for tracking: \(jobName)")
    }
    
    // MARK: - Private Methods
    
    private func getAudioDuration(url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }
    
    private func transcribeSingleChunk(url: URL) async throws -> TranscriptionResult {
        let startTime = Date()
        print("🎤 Starting single chunk transcription...")
        isTranscribing = true
        currentStatus = "Transcribing audio..."
        
        // Add timeout to prevent infinite CPU usage
        return try await withThrowingTaskGroup(of: TranscriptionResult.self) { group in
            // Main transcription task
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    guard let recognizer = self.speechRecognizer else {
                        print("❌ Speech recognizer is nil")
                        continuation.resume(throwing: TranscriptionError.speechRecognizerUnavailable)
                        return
                    }
                    
                    print("✅ Speech recognizer available, starting recognition...")
                    
                    let request = SFSpeechURLRecognitionRequest(url: url)
                    request.shouldReportPartialResults = false
                    
                    // Add additional request configuration to minimize audio issues
                    if #available(iOS 16.0, *) {
                        request.addsPunctuation = true
                    }
                    
                    print("📝 Creating recognition task with request for: \(url.lastPathComponent)")
                    
                    self.currentTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                        guard let self = self else { return }
                        
                        DispatchQueue.main.async {
                            if let error = error {
                                // Check if this is a non-critical error that can be safely ignored
                                if self.handleSpeechRecognitionError(error) {
                                    // Non-critical error, continue processing
                                    return
                                }
                                
                                // Critical error, stop processing
                                self.isTranscribing = false
                                self.currentStatus = "Transcription failed"
                                continuation.resume(throwing: TranscriptionError.recognitionFailed(error))
                            } else if let result = result {
                                print("📝 Recognition result received, isFinal: \(result.isFinal)")
                                if result.isFinal {
                                    let processingTime = Date().timeIntervalSince(startTime)
                                    let transcriptText = result.bestTranscription.formattedString
                                    print("📄 Transcript text length: \(transcriptText.count) characters")
                                    
                                    if transcriptText.isEmpty {
                                        print("❌ No speech detected in audio file")
                                        self.isTranscribing = false
                                        self.currentStatus = "No speech detected"
                                        continuation.resume(throwing: TranscriptionError.noSpeechDetected)
                                    } else {
                                        print("✅ Transcription successful!")
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
                                    print("⏳ Recognition in progress...")
                                }
                            }
                        }
                    }
                }
            }
            
            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(300 * 1_000_000_000)) // 5 minute timeout
                print("⏰ Transcription timeout reached, cancelling...")
                await MainActor.run {
                    self.currentTask?.cancel()
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
        print("🔀 Starting large file transcription...")
        isTranscribing = true
        currentStatus = "Processing large file..."
        
        // Calculate chunks
        let chunks = calculateChunks(duration: duration)
        print("📊 Calculated \(chunks.count) chunks for \(duration/60) minute file")
        var allSegments: [TranscriptSegment] = []
        var allText: [String] = []
        var currentOffset: TimeInterval = 0
        
        for (index, chunk) in chunks.enumerated() {
            print("🔄 Processing chunk \(index + 1) of \(chunks.count) (time: \(chunk.start/60)-\(chunk.end/60) minutes)")
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
                let chunkResult = try await transcribeChunk(url: url, startTime: chunk.start, endTime: chunk.end)
                
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
                
            } catch {
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
                throw TranscriptionError.chunkProcessingFailed(chunk: index + 1, error: error)
            }
            
            // Check timeout
            let elapsedTime = Date().timeIntervalSince(startTime)
            if elapsedTime > maxTranscriptionTime {
                isTranscribing = false
                currentStatus = "Transcription timeout"
                throw TranscriptionError.timeout
            }
        }
        
        let processingTime = Date().timeIntervalSince(startTime)
        let fullText = allText.joined(separator: " ")
        
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
        
        // Export the chunk
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
        await session.export()
        
        // Check export status (using status for now as states API may not be fully available)
        guard session.status == .completed else {
            throw TranscriptionError.audioExtractionFailed
        }
        
        return outputURL
    }
    
    private func calculateChunks(duration: TimeInterval) -> [(start: TimeInterval, end: TimeInterval)] {
        var chunks: [(start: TimeInterval, end: TimeInterval)] = []
        var currentStart: TimeInterval = 0
        
        while currentStart < duration {
            let currentEnd = min(currentStart + maxChunkDuration, duration)
            chunks.append((start: currentStart, end: currentEnd))
            currentStart = currentEnd - chunkOverlap
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
        print("☁️ Starting AWS Transcribe transcription...")
        
        let awsService = AWSTranscribeService(config: config)
        
        do {
            // Start the transcription job asynchronously
            let jobName = try await awsService.startTranscriptionJob(url: url)
            
            print("✅ AWS Transcribe job started: \(jobName)")
            print("⏳ Job is running in background. Use checkTranscriptionStatus() to monitor progress.")
            
            // Add job to pending list for background checking
            addPendingJob(jobName, recordingURL: url, recordingName: url.lastPathComponent)
            
            // Return a result indicating the job is running
            let transcriptionResult = TranscriptionResult(
                fullText: "Transcription job started: \(jobName)\n\nJob is running in background. Check status later to retrieve results.",
                segments: [TranscriptSegment(
                    speaker: "System",
                    text: "Transcription job \(jobName) is running in background",
                    startTime: 0,
                    endTime: 0
                )],
                processingTime: 0,
                chunkCount: 1,
                success: true,
                error: nil
            )
            
            return transcriptionResult
            
        } catch {
            print("❌ AWS Transcribe failed: \(error)")
            throw TranscriptionError.awsTranscriptionFailed(error)
        }
    }
    
    /// Wait for a transcription job to complete and retrieve the result
    private func waitForAndRetrieveTranscription(jobName: String, awsService: AWSTranscribeService) async throws -> TranscriptionResult {
        let maxWaitTime: TimeInterval = 3600 // 1 hour max wait
        let checkInterval: TimeInterval = 10 // Check every 10 seconds
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            let status = try await awsService.checkJobStatus(jobName: jobName)
            
            switch status.status {
            case .completed:
                print("✅ Transcription job completed, retrieving result...")
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
                
            case .failed:
                let errorMessage = status.failureReason ?? "Unknown error"
                print("❌ Transcription job failed: \(errorMessage)")
                throw TranscriptionError.awsTranscriptionFailed(NSError(domain: "AWSTranscribe", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
                
            case .inProgress:
                print("⏳ Transcription job still in progress... (elapsed: \(Int(Date().timeIntervalSince(startTime)))s)")
                try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                
            default:
                print("⚠️ Unknown job status: \(status.status.rawValue)")
                try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            }
        }
        
        throw TranscriptionError.timeout
    }
    
    /// Start an async transcription job and return the job name
    func startAsyncTranscription(url: URL, config: AWSTranscribeConfig) async throws -> String {
        print("🚀 Starting async transcription for: \(url.lastPathComponent)")
        
        let awsService = AWSTranscribeService(config: config)
        let jobName = try await awsService.startTranscriptionJob(url: url)
        
        // Track this job for later checking
        addPendingJob(jobName, recordingURL: url, recordingName: url.lastPathComponent)
        
        print("✅ Async transcription job started: \(jobName)")
        return jobName
    }
    
    /// Check the status of a transcription job
    func checkTranscriptionStatus(jobName: String, config: AWSTranscribeConfig) async throws -> AWSTranscribeJobStatus {
        let awsService = AWSTranscribeService(config: config)
        return try await awsService.checkJobStatus(jobName: jobName)
    }
    
    /// Retrieve a completed transcript
    func retrieveTranscription(jobName: String, config: AWSTranscribeConfig) async throws -> TranscriptionResult {
        let awsService = AWSTranscribeService(config: config)
        let awsResult = try await awsService.retrieveTranscript(jobName: jobName)
        
        // Convert AWS result to our TranscriptionResult format
        print("🔄 Converting AWS result to TranscriptionResult")
        print("🔄 AWS transcript text length: \(awsResult.transcriptText.count)")
        print("🔄 AWS segments count: \(awsResult.segments.count)")
        
        let transcriptionResult = TranscriptionResult(
            fullText: awsResult.transcriptText,
            segments: awsResult.segments,
            processingTime: awsResult.processingTime,
            chunkCount: 1,
            success: awsResult.success,
            error: awsResult.error
        )
        
        print("🔄 Final TranscriptionResult text length: \(transcriptionResult.fullText.count)")
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
                    print("✅ Found completed job: \(jobName)")
                    let result = try await retrieveTranscription(jobName: jobName, config: config)
                    completedResults.append(result)
                } else if status.isFailed {
                    print("❌ Job failed: \(jobName) - \(status.failureReason ?? "Unknown error")")
                    // Remove failed jobs from pending list
                } else {
                    print("⏳ Job still pending: \(jobName)")
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
        print("🎤 Starting Whisper transcription...")
        
        let whisperService = WhisperService(config: config)
        
        do {
            // Test connection first
            print("🔌 Testing Whisper connection...")
            let isConnected = await whisperService.testConnection()
            guard isConnected else {
                print("❌ Whisper connection failed")
                throw TranscriptionError.whisperConnectionFailed
            }
            
            print("✅ Whisper service connected successfully")
            
            // Get audio duration to determine if we need chunking
            let duration = try await getAudioDuration(url: url)
            
            let result: TranscriptionResult
            if duration > maxChunkDuration && enableEnhancedTranscription {
                print("🔀 Using chunked Whisper transcription for large file")
                result = try await whisperService.transcribeAudioInChunks(url: url, chunkDuration: maxChunkDuration)
            } else {
                print("🎤 Using standard Whisper transcription")
                result = try await whisperService.transcribeAudio(url: url)
            }
            
            print("✅ Whisper transcription completed successfully")
            return result
            
        } catch {
            print("❌ Whisper transcription failed: \(error)")
            throw TranscriptionError.whisperTranscriptionFailed(error)
        }
    }
    
    // MARK: - OpenAI Transcription
    
    private func transcribeWithOpenAI(url: URL, config: OpenAITranscribeConfig) async throws -> TranscriptionResult {
        print("🤖 Starting OpenAI transcription...")
        
        let openAIService = OpenAITranscribeService(config: config)
        
        do {
            // Test connection first
            print("🔌 Testing OpenAI connection...")
            try await openAIService.testConnection()
            print("✅ OpenAI service connected successfully")
            
            // OpenAI has a 25MB file size limit, so we don't need chunking for most files
            // But we should check the file size
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0
            let maxSize: Int64 = 25 * 1024 * 1024 // 25MB
            
            if fileSize > maxSize {
                print("⚠️ File too large for OpenAI (\(fileSize / 1024 / 1024)MB > 25MB), falling back to chunked Apple Intelligence")
                return try await transcribeWithAppleIntelligence(url: url, duration: try await getAudioDuration(url: url))
            }
            
            print("🎤 Using OpenAI transcription with model: \(config.model.displayName)")
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
            
            print("✅ OpenAI transcription completed successfully")
            print("📝 Transcript length: \(transcriptionResult.fullText.count) characters")
            
            if let usage = openAIResult.usage {
                print("💰 Token usage - Input: \(usage.inputTokens ?? 0), Output: \(usage.outputTokens ?? 0), Total: \(usage.totalTokens ?? 0)")
            }
            
            return transcriptionResult
            
        } catch {
            print("❌ OpenAI transcription failed: \(error)")
            throw TranscriptionError.openAITranscriptionFailed(error)
        }
    }
    
    // MARK: - Job Tracking Helpers
    
    /// Update pending jobs when recording files are renamed
    func updatePendingJobsForRenamedRecording(from oldURL: URL, to newURL: URL, newName: String) {
        print("🔄 Updating pending transcription jobs for renamed recording")
        print("🔄 Old URL: \(oldURL)")
        print("🔄 New URL: \(newURL)")
        print("🔄 New name: \(newName)")
        
        var updatedJobs: [TranscriptionJobInfo] = []
        var updated = false
        
        for job in pendingJobs {
            if job.recordingURL == oldURL {
                print("🔄 Updating job: \(job.jobName)")
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
            print("✅ Updated pending transcription jobs for renamed recording")
        } else {
            print("ℹ️ No pending jobs found for the renamed recording")
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
            print("📝 Added pending job: \(jobName) for recording: \(recordingName)")
            print("📝 Job URL: \(recordingURL)")
        }
    }
    
    private func removePendingJob(_ jobName: String) {
        pendingJobs.removeAll { $0.jobName == jobName }
        savePendingJobs()
        print("🗑️ Removed pending job: \(jobName)")
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
        print("📋 Updated pending jobs: \(jobNames)")
    }
    
    private func loadPendingJobs() {
        if let data = UserDefaults.standard.data(forKey: "pendingTranscriptionJobInfos"),
           let jobs = try? JSONDecoder().decode([TranscriptionJobInfo].self, from: data) {
            pendingJobs = jobs
            print("📋 Loaded \(jobs.count) pending transcription jobs")
            for job in jobs {
                print("📋 - Job: \(job.jobName) for recording: \(job.recordingName)")
            }
        } else {
            print("📋 No pending transcription jobs found in UserDefaults")
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
        print("🔄 Starting background transcription checking...")
        
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
        print("⏹️ Stopped background transcription checking")
    }
    
    // MARK: - Engine Management
    
    func switchToAppleTranscription() {
        print("🔄 Switching to Apple transcription, stopping AWS background checks...")
        stopBackgroundChecking()
        
        // Clear any pending AWS jobs since we're not using AWS anymore
        let pendingCount = getPendingJobNames().count
        if pendingCount > 0 {
            print("🧹 Clearing \(pendingCount) pending AWS transcription jobs")
            clearAllPendingJobs()
        }
        
        // Also disable AWS transcription in settings to prevent future background checks
        UserDefaults.standard.set(false, forKey: "enableAWSTranscribe")
        print("🔧 Disabled AWS transcription in settings")
    }
    
    func switchToAWSTranscription() {
        print("🔄 Switching to AWS transcription...")
        if awsConfig != nil {
            if !isBackgroundChecking {
                startBackgroundChecking()
                print("✅ Started AWS background checking")
            }
        } else {
            print("⚠️ AWS transcription selected but not configured")
        }
    }
    
    func switchToWhisperTranscription() {
        print("🔄 Switching to Whisper transcription...")
        // Whisper doesn't use background checking like AWS, so we stop any existing background processes
        stopBackgroundChecking()
        
        // Clear any pending AWS jobs since we're switching to Whisper
        let pendingCount = getPendingJobNames().count
        if pendingCount > 0 {
            print("🧹 Clearing \(pendingCount) pending AWS transcription jobs")
            clearAllPendingJobs()
        }
        
        if whisperConfig != nil {
            print("✅ Whisper transcription configured and ready")
        } else {
            print("⚠️ Whisper transcription selected but not configured")
        }
    }
    
    /// Public method to update transcription engine and manage background processes
    func updateTranscriptionEngine(_ engine: TranscriptionEngine) {
        print("🔧 Updating transcription engine to: \(engine.rawValue)")
        
        switch engine {
        case .awsTranscribe:
            switchToAWSTranscription()
        case .whisper:
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
        print("🧹 All pending AWS jobs cleared")
    }
    
    private func checkForCompletedTranscriptionsInBackground() async {
        // Only check if AWS is enabled, configured, AND we have pending jobs
        guard enableAWSTranscribe else {
            print("ℹ️ Background check: AWS transcription not enabled, stopping background checks")
            stopBackgroundChecking()
            clearAllPendingJobs()
            return
        }
        
        guard let config = awsConfig else { 
            print("❌ Background check: No AWS config available, stopping background checks")
            stopBackgroundChecking()
            return 
        }
        
        let jobNames = getPendingJobNames()
        guard !jobNames.isEmpty else { 
            print("❌ Background check: No pending jobs found")
            return 
        }
        
        print("🔍 Background check: Checking \(jobNames.count) pending transcription jobs...")
        print("📋 Background check - Pending jobs: \(jobNames)")
        
        var stillPendingJobs: [String] = []
        
        for jobName in jobNames {
            do {
                let status = try await checkTranscriptionStatus(jobName: jobName, config: config)
                
                if status.isCompleted {
                    print("✅ Background check: Found completed job: \(jobName)")
                    let result = try await retrieveTranscription(jobName: jobName, config: config)
                    
                    // Get job info before removing it
                    let jobInfo = getPendingJobInfo(for: jobName)
                    
                    // Remove from pending jobs
                    removePendingJob(jobName)
                    
                    // Notify completion
                    if let jobInfo = jobInfo {
                        print("🔔 Calling onTranscriptionCompleted callback for job: \(jobName)")
                        print("🔔 Job info: \(jobInfo.recordingName) - \(jobInfo.recordingURL)")
                        print("🔔 Result text length: \(result.fullText.count)")
                        onTranscriptionCompleted?(result, jobInfo)
                        print("🔔 Callback completed")
                    } else {
                        print("❌ No job info found for completed job: \(jobName)")
                    }
                    
                } else if status.isFailed {
                    print("❌ Background check: Job failed: \(jobName) - \(status.failureReason ?? "Unknown error")")
                    // Remove failed jobs from pending list
                    removePendingJob(jobName)
                } else {
                    print("⏳ Background check: Job still pending: \(jobName)")
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
    case awsTranscriptionFailed(Error)
    case whisperConnectionFailed
    case whisperTranscriptionFailed(Error)
    case openAITranscriptionFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Audio file not found"
        case .speechRecognizerUnavailable:
            return "Speech recognition is not available"
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
        case .whisperConnectionFailed:
            return "Failed to connect to Whisper service"
        case .whisperTranscriptionFailed(let error):
            return "Whisper transcription failed: \(error.localizedDescription)"
        case .openAITranscriptionFailed(let error):
            return "OpenAI transcription failed: \(error.localizedDescription)"
        }
    }
}