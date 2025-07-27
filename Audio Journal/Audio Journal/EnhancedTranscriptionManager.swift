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
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayer?
    private var currentTask: SFSpeechRecognitionTask?
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    
    // Configuration
    private var enableEnhancedTranscription: Bool {
        // Default to true if not set
        if UserDefaults.standard.object(forKey: "enableEnhancedTranscription") == nil {
            UserDefaults.standard.set(true, forKey: "enableEnhancedTranscription")
        }
        return UserDefaults.standard.bool(forKey: "enableEnhancedTranscription")
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
    
    // Job tracking for async transcriptions
    private var pendingJobNames: String = ""
    private var pendingJobs: [TranscriptionJobInfo] = []
    
    // Background checking for completed transcriptions
    private var backgroundCheckTimer: Timer?
    private var isBackgroundChecking = false
    
    // Callback for when transcriptions complete
    var onTranscriptionCompleted: ((TranscriptionResult, TranscriptionJobInfo) -> Void)?
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        setupSpeechRecognizer()
        // Load pending job names from UserDefaults
        pendingJobNames = UserDefaults.standard.string(forKey: "pendingTranscriptionJobs") ?? ""
        
        // Load pending jobs from UserDefaults
        loadPendingJobs()
        
        // Start background checking for completed transcriptions
        startBackgroundChecking()
    }
    
    private func setupSpeechRecognizer() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechRecognizer?.delegate = self
    }
    
    // MARK: - Public Methods
    
    func transcribeAudioFile(at url: URL) async throws -> TranscriptionResult {
        print("🎯 Starting transcription for: \(url.lastPathComponent)")
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ File not found: \(url.path)")
            throw TranscriptionError.fileNotFound
        }
        
        // Check file duration
        let duration = try await getAudioDuration(url: url)
        print("📏 File duration: \(duration) seconds (\(duration/60) minutes)")
        
        // Try AWS Transcribe first if enabled and configured
        if let config = awsConfig {
            print("☁️ Using AWS Transcribe for transcription")
            return try await transcribeWithAWS(url: url, config: config)
        }
        
        // Fall back to local transcription
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
        audioEngine?.stop()
        audioPlayer?.stop()
        isTranscribing = false
        progress = nil
        currentStatus = "Transcription cancelled"
    }
    
    /// Manually check for completed transcriptions
    func checkForCompletedTranscriptions() async {
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
                    
                    // Remove from pending jobs
                    removePendingJob(jobName)
                    
                    // Notify completion
                    if let jobInfo = getPendingJobInfo(for: jobName) {
                        onTranscriptionCompleted?(result, jobInfo)
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
        
        return try await withCheckedThrowingContinuation { continuation in
            guard let recognizer = speechRecognizer else {
                print("❌ Speech recognizer is nil")
                continuation.resume(throwing: TranscriptionError.speechRecognizerUnavailable)
                return
            }
            
            print("✅ Speech recognizer available, starting recognition...")
            
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            
            currentTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    if let error = error {
                        print("❌ Speech recognition error: \(error)")
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
        
        // Create segments from transcription
        var segments: [TranscriptSegment] = []
        var currentText = ""
        var currentStartTime: TimeInterval = 0
        
        for segment in transcription.segments {
            if currentText.isEmpty {
                currentStartTime = segment.timestamp
            }
            
            currentText += " " + segment.substring
            
            // Create a segment every 30 seconds or when there's a significant pause
            let segmentDuration = segment.timestamp + segment.duration - currentStartTime
            if segmentDuration >= 30.0 || segment == transcription.segments.last {
                segments.append(TranscriptSegment(
                    speaker: "Speaker",
                    text: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
                    startTime: currentStartTime,
                    endTime: segment.timestamp + segment.duration
                ))
                currentText = ""
            }
        }
        
        return segments
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
    
    // MARK: - Job Tracking Helpers
    
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
    
    private func checkForCompletedTranscriptionsInBackground() async {
        guard let config = awsConfig else { 
            print("❌ Background check: No AWS config available")
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
                    
                    // Remove from pending jobs
                    removePendingJob(jobName)
                    
                    // Notify completion
                    if let jobInfo = getPendingJobInfo(for: jobName) {
                        onTranscriptionCompleted?(result, jobInfo)
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
        }
    }
}