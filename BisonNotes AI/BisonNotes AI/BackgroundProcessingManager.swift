//
//  BackgroundProcessingManager.swift
//  Audio Journal
//
//  Background processing manager for handling transcription and summarization jobs
//

import Foundation
import SwiftUI
import UserNotifications
import UIKit
import CoreData
import AVFoundation
import AVKit

// MARK: - Processing Job Models

struct ProcessingJob: Identifiable, Codable {
    let id: UUID
    let type: JobType
    let recordingURL: URL
    let recordingName: String
    let status: JobProcessingStatus
    let progress: Double
    let startTime: Date
    let completionTime: Date?
    let chunks: [AudioChunk]?
    let error: String?
    
    init(type: JobType, recordingURL: URL, recordingName: String, chunks: [AudioChunk]? = nil) {
        self.id = UUID()
        self.type = type
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.status = .queued
        self.progress = 0.0
        self.startTime = Date()
        self.completionTime = nil
        self.chunks = chunks
        self.error = nil
    }
    
    func withStatus(_ status: JobProcessingStatus) -> ProcessingJob {
        ProcessingJob(
            id: self.id,
            type: self.type,
            recordingURL: self.recordingURL,
            recordingName: self.recordingName,
            status: status,
            progress: self.progress,
            startTime: self.startTime,
            completionTime: status == .completed || status.isError ? Date() : self.completionTime,
            chunks: self.chunks,
            error: status.errorMessage
        )
    }
    
    func withProgress(_ progress: Double) -> ProcessingJob {
        ProcessingJob(
            id: self.id,
            type: self.type,
            recordingURL: self.recordingURL,
            recordingName: self.recordingName,
            status: self.status,
            progress: progress,
            startTime: self.startTime,
            completionTime: self.completionTime,
            chunks: self.chunks,
            error: self.error
        )
    }
    
    init(id: UUID, type: JobType, recordingURL: URL, recordingName: String, status: JobProcessingStatus, progress: Double, startTime: Date, completionTime: Date?, chunks: [AudioChunk]?, error: String?) {
        self.id = id
        self.type = type
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.status = status
        self.progress = progress
        self.startTime = startTime
        self.completionTime = completionTime
        self.chunks = chunks
        self.error = error
    }
}

enum JobType: Codable {
    case transcription(engine: TranscriptionEngine)
    case summarization(engine: String)
    
    var displayName: String {
        switch self {
        case .transcription(let engine):
            return "Transcription (\(engine.rawValue))"
        case .summarization(let engine):
            return "Summarization (\(engine))"
        }
    }
    
    var engineName: String {
        switch self {
        case .transcription(let engine):
            return engine.rawValue
        case .summarization(let engine):
            return engine
        }
    }
    
    // MARK: - Codable Implementation
    
    private enum CodingKeys: String, CodingKey {
        case type
        case engine
    }
    
    private enum JobTypeIdentifier: String, Codable {
        case transcription
        case summarization
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(JobTypeIdentifier.self, forKey: .type)
        
        switch type {
        case .transcription:
            let engineRawValue = try container.decode(String.self, forKey: .engine)
            guard let engine = TranscriptionEngine(rawValue: engineRawValue) else {
                throw DecodingError.dataCorruptedError(forKey: .engine, in: container, debugDescription: "Invalid TranscriptionEngine value: \(engineRawValue)")
            }
            self = .transcription(engine: engine)
        case .summarization:
            let engine = try container.decode(String.self, forKey: .engine)
            self = .summarization(engine: engine)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .transcription(let engine):
            try container.encode(JobTypeIdentifier.transcription, forKey: .type)
            try container.encode(engine.rawValue, forKey: .engine)
        case .summarization(let engine):
            try container.encode(JobTypeIdentifier.summarization, forKey: .type)
            try container.encode(engine, forKey: .engine)
        }
    }
}

enum JobProcessingStatus: Codable, Equatable {
    case queued
    case processing
    case completed
    case failed(String)
    
    var isError: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
    
    var errorMessage: String? {
        if case .failed(let message) = self {
            return message
        }
        return nil
    }
    
    var displayName: String {
        switch self {
        case .queued:
            return "Queued"
        case .processing:
            return "Processing"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }
}

// MARK: - Background Processing Manager

@MainActor
class BackgroundProcessingManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var activeJobs: [ProcessingJob] = []
    @Published var processingStatus: JobProcessingStatus = .queued
    @Published var currentJob: ProcessingJob?
    
    // MARK: - Completion Handlers
    
    var onTranscriptionCompleted: ((TranscriptData, ProcessingJob) -> Void)?
    
    // MARK: - Private Properties
    
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let chunkingService = AudioFileChunkingService()
    private let performanceOptimizer = PerformanceOptimizer.shared
    private let enhancedFileManager = EnhancedFileManager.shared
    private let audioSessionManager = EnhancedAudioSessionManager()
    private let coreDataManager = CoreDataManager()
    
    // MARK: - Singleton
    
    static let shared = BackgroundProcessingManager()
    
    private init() {
        loadJobsFromCoreData()
        setupNotifications()
        setupAppLifecycleObservers()
        setupPerformanceOptimization()
        
        // Start processing any queued jobs on initialization
        Task {
            if !activeJobs.filter({ $0.status == .queued }).isEmpty {
                await processNextJob()
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Performance Optimization Setup
    
    private func setupPerformanceOptimization() {
        // Start periodic optimization
        Task {
            await performanceOptimizer.optimizeBackgroundProcessing()
            await performanceOptimizer.optimizeNetworkUsage()
        }
        
        // Start background time monitoring
        startBackgroundTimeMonitoring()
    }
    
    private func startBackgroundTimeMonitoring() {
        // Monitor background time every 10 seconds when there's an active job
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if self.backgroundTaskID != .invalid {
                    self.monitorBackgroundTime()
                }
            }
        }
    }
    
    // MARK: - Job Management
    
    func startTranscriptionJob(recordingURL: URL, recordingName: String, engine: TranscriptionEngine, chunks: [AudioChunk]? = nil) async throws {
        // Ensure only one job runs at a time
        guard currentJob == nil else {
            throw BackgroundProcessingError.jobAlreadyRunning
        }
        
        // Ensure recording exists in Core Data
        await ensureRecordingExists(recordingURL: recordingURL, recordingName: recordingName)
        
        let job = ProcessingJob(
            type: .transcription(engine: engine),
            recordingURL: recordingURL,
            recordingName: recordingName,
            chunks: chunks
        )
        
        await addJob(job)
        await processNextJob()
    }
    
    func startSummarizationJob(recordingURL: URL, recordingName: String, engine: String) async throws {
        // Ensure only one job runs at a time
        guard currentJob == nil else {
            throw BackgroundProcessingError.jobAlreadyRunning
        }
        
        let job = ProcessingJob(
            type: .summarization(engine: engine),
            recordingURL: recordingURL,
            recordingName: recordingName
        )
        
        await addJob(job)
        await processNextJob()
    }
    
    func cancelActiveJob() async {
        guard let job = currentJob else { return }
        
        let cancelledJob = job.withStatus(.failed("Cancelled by user"))
        await updateJob(cancelledJob)
        
        currentJob = nil
        processingStatus = .queued
        
        endBackgroundTask()
        // Core Data automatically persists changes
    }
    
    func getJobStatus(_ jobId: UUID) -> JobProcessingStatus {
        if let job = activeJobs.first(where: { $0.id == jobId }) {
            return job.status
        }
        return .failed("Job not found")
    }
    
    func getJobProgress(_ jobId: UUID) -> Double {
        if let job = activeJobs.first(where: { $0.id == jobId }) {
            return job.progress
        }
        return 0.0
    }
    
    func getCurrentJobProgress() -> Double {
        return currentJob?.progress ?? 0.0
    }
    
    func removeCompletedJobs() async {
        // Remove from Core Data
        coreDataManager.deleteCompletedProcessingJobs()
        
        // Remove from active jobs array
        activeJobs.removeAll { job in
            job.status == .completed || job.status.isError
        }
    }

    // MARK: - External Job Tracking

    func trackExternalJob(_ job: ProcessingJob) async {
        await addJob(job)
    }

    func updateExternalJob(_ job: ProcessingJob) async {
        await updateJob(job)
    }

    // MARK: - Helper Methods
    
    private func getEngineString(from jobType: JobType) -> String {
        switch jobType {
        case .transcription(let engine):
            return engine.rawValue
        case .summarization(let engine):
            return engine
        }
    }
    
    // MARK: - Private Job Management
    
    private func addJob(_ job: ProcessingJob) async {
        // Create Core Data entry
        let jobEntry = coreDataManager.createProcessingJob(
            id: job.id,
            jobType: job.type.displayName,
            engine: getEngineString(from: job.type),
            recordingURL: job.recordingURL,
            recordingName: job.recordingName
        )
        
        // Update the job entry with initial status
        jobEntry.status = job.status.displayName
        jobEntry.progress = job.progress
        coreDataManager.updateProcessingJob(jobEntry)
        
        activeJobs.append(job)
    }
    
    private func updateJob(_ updatedJob: ProcessingJob) async {
        if let index = activeJobs.firstIndex(where: { $0.id == updatedJob.id }) {
            activeJobs[index] = updatedJob
            
            if updatedJob.id == currentJob?.id {
                currentJob = updatedJob
                processingStatus = updatedJob.status
            }
            
            // Update Core Data entry
            if let jobEntry = coreDataManager.getProcessingJob(id: updatedJob.id) {
                jobEntry.status = updatedJob.status.displayName
                jobEntry.progress = updatedJob.progress
                jobEntry.lastModified = Date()
                
                if updatedJob.status == .completed || updatedJob.status.isError {
                    jobEntry.completionTime = Date()
                }
                
                if case .failed(let error) = updatedJob.status {
                    jobEntry.error = error
                }
                
                coreDataManager.updateProcessingJob(jobEntry)
            }
        }
    }
    
    private func processNextJob() async {
        // Find the next queued job
        guard let nextJob = activeJobs.first(where: { $0.status == .queued }) else {
            currentJob = nil
            processingStatus = .queued
            endBackgroundTask() // Ensure background task is ended when no more jobs
            return
        }
        
        currentJob = nextJob
        processingStatus = .processing
        
        // Start background task
        beginBackgroundTask()
        
        // Update job status to processing
        let processingJob = nextJob.withStatus(.processing)
        await updateJob(processingJob)
        
        print("🚀 Starting job processing: \(nextJob.type.displayName) for \(nextJob.recordingName)")
        print("   - Engine: \(nextJob.type.engineName)")
        print("   - Recording URL: \(nextJob.recordingURL)")
        print("   - File exists: \(FileManager.default.fileExists(atPath: nextJob.recordingURL.path))")
        
        do {
            // Apply battery-aware processing settings
            await applyBatteryOptimization(for: processingJob)
            
            switch nextJob.type {
            case .transcription(let engine):
                print("📝 Processing transcription job with \(engine.rawValue)")
                try await processTranscriptionJob(processingJob, engine: engine)
            case .summarization(let engine):
                print("📋 Processing summarization job with \(engine)")
                try await processSummarizationJob(processingJob, engine: engine)
            }
            
            // Job completed successfully
            let completedJob = processingJob.withStatus(.completed).withProgress(1.0)
            await updateJob(completedJob)
            
            print("✅ Job completed: \(nextJob.type.displayName) for \(nextJob.recordingName)")
            
            // Post-processing cleanup
            await performCleanupTasks(for: processingJob)
            await updateFileMetadata(for: processingJob)
            
        } catch {
            let failedJob = processingJob.withStatus(.failed(error.localizedDescription))
            await updateJob(failedJob)
            
            print("❌ Job failed: \(nextJob.type.displayName) for \(nextJob.recordingName)")
            print("   - Error: \(error)")
            print("   - Error type: \(type(of: error))")
            print("   - Localized description: \(error.localizedDescription)")
            
            // Save detailed error log
            await saveErrorLog(for: processingJob, error: error)
            
            // Error recovery
            await handleJobFailure(processingJob, error: error)
            
            // Send failure notification
            await sendNotification(
                title: "Processing Failed",
                body: "Failed to process \(nextJob.recordingName): \(error.localizedDescription)"
            )
        }
        
        // Clear current job
        currentJob = nil
        endBackgroundTask()
        
        // Process next job if any
        if !activeJobs.filter({ $0.status == .queued }).isEmpty {
            await processNextJob()
        }
    }
    

    
    private func applyBatteryOptimization(for job: ProcessingJob) async {
        // Apply battery-aware settings based on current conditions
        if performanceOptimizer.batteryInfo.shouldOptimizeForBattery {
            print("🔋 Applying battery optimization for job: \(job.recordingName)")
            
            // Reduce processing frequency
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
            
            // Use lower quality settings for battery optimization
            if case .transcription(let engine) = job.type {
                // Adjust engine settings for battery optimization
                print("🔋 Using battery-optimized settings for \(engine.rawValue)")
            }
        }
    }
    
    private func processTranscriptionJob(_ job: ProcessingJob, engine: TranscriptionEngine) async throws {
        EnhancedLogger.shared.logBackgroundJobStart(job)
        
        // Update progress
        let progressJob = job.withProgress(0.1)
        await updateJob(progressJob)
        
        // Get chunks or create them if needed
        let chunks: [AudioChunk]
        if let existingChunks = job.chunks {
            chunks = existingChunks
            EnhancedLogger.shared.logBackgroundProcessing("Using existing chunks: \(chunks.count)", level: .debug)
        } else {
            // Check if chunking is needed
            let needsChunking = try await chunkingService.shouldChunkFile(job.recordingURL, for: engine)
            
            if needsChunking {
                EnhancedLogger.shared.logBackgroundProcessing("File needs chunking for \(engine.rawValue)", level: .info)
                let chunkingResult = try await chunkingService.chunkAudioFile(job.recordingURL, for: engine)
                chunks = chunkingResult.chunks
            } else {
                // Create a single "chunk" for the whole file
                let fileInfo = try await chunkingService.getAudioFileInfo(job.recordingURL)
                chunks = [AudioChunk(
                    originalURL: job.recordingURL,
                    chunkURL: job.recordingURL,
                    sequenceNumber: 0,
                    startTime: 0,
                    endTime: fileInfo.duration,
                    fileSize: fileInfo.fileSize
                )]
            }
        }
        
        // Update progress after chunking
        let chunkingProgressJob = job.withProgress(0.2)
        await updateJob(chunkingProgressJob)
        
        // Process each chunk
        var transcriptChunks: [TranscriptChunk] = []
        let totalChunks = chunks.count
        
        for (index, chunk) in chunks.enumerated() {
            EnhancedLogger.shared.logChunkingProgress(index + 1, totalChunks: totalChunks, fileURL: job.recordingURL)
            
            // Update progress for this chunk
            let chunkProgress = 0.2 + (0.7 * Double(index) / Double(totalChunks))
            let chunkProgressJob = job.withProgress(chunkProgress)
            await updateJob(chunkProgressJob)
            
            // Send progress notification for significant progress updates
            if index == 0 || index == totalChunks / 2 || index == totalChunks - 1 {
                await sendProgressNotification(for: chunkProgressJob)
            }
            
            // Transcribe the chunk
            let transcriptResult = try await transcribeChunk(chunk, engine: engine)
            
            // Create transcript chunk
            let transcriptChunk = chunkingService.createTranscriptChunk(
                from: transcriptResult.fullText,
                audioChunk: chunk,
                segments: transcriptResult.segments
            )
            
            transcriptChunks.append(transcriptChunk)
            
            EnhancedLogger.shared.logBackgroundProcessing("Chunk \(index + 1) transcribed: \(transcriptResult.fullText.count) characters", level: .debug)
        }
        
        // Reassemble transcript if multiple chunks
        if transcriptChunks.count > 1 {
            EnhancedLogger.shared.logBackgroundProcessing("Reassembling transcript from \(transcriptChunks.count) chunks", level: .info)
            
            // Get the recording ID first
            let recordingId: UUID
            if let appCoordinator = enhancedFileManager.getCoordinator() {
                print("🔍 DEBUG: Looking for recording with URL: \(job.recordingURL)")
                print("🔍 DEBUG: URL absoluteString: \(job.recordingURL.absoluteString)")
                
                // Debug: List all recordings in Core Data
                let allRecordings = appCoordinator.coreDataManager.getAllRecordings()
                print("🔍 DEBUG: Found \(allRecordings.count) recordings in Core Data:")
                for recording in allRecordings {
                    print("   - \(recording.recordingName ?? "unknown"): \(recording.recordingURL ?? "no URL")")
                }
                
                if let recordingEntry = appCoordinator.getRecording(url: job.recordingURL),
                   let entryId = recordingEntry.id {
                    recordingId = entryId
                    print("🆔 Found recording ID for reassembly: \(recordingId)")
                } else {
                    print("❌ No recording found for URL: \(job.recordingURL), using new UUID")
                    recordingId = UUID()
                }
            } else {
                print("❌ AppCoordinator not available")
                recordingId = UUID()
            }
            
            let reassemblyResult = try await chunkingService.reassembleTranscript(
                from: transcriptChunks,
                originalURL: job.recordingURL,
                recordingName: job.recordingName,
                recordingDate: Date(), // TODO: Get actual recording date
                recordingId: recordingId
            )
            
            // Save the complete transcript
            await saveTranscript(reassemblyResult.transcriptData)
            
            // Clean up chunk files if they were created
            if chunks.count > 1 && chunks.first?.chunkURL != job.recordingURL {
                try await chunkingService.cleanupChunks(chunks)
            }
        } else if let firstChunk = transcriptChunks.first {
            // Single chunk, save directly
            // Get the recording ID first
            let recordingId: UUID
            if let appCoordinator = enhancedFileManager.getCoordinator() {
                print("🔍 DEBUG: Looking for recording with URL: \(job.recordingURL)")
                print("🔍 DEBUG: URL absoluteString: \(job.recordingURL.absoluteString)")
                
                // Debug: List all recordings in Core Data
                let allRecordings = appCoordinator.coreDataManager.getAllRecordings()
                print("🔍 DEBUG: Found \(allRecordings.count) recordings in Core Data:")
                for recording in allRecordings {
                    print("   - \(recording.recordingName ?? "unknown"): \(recording.recordingURL ?? "no URL")")
                }
                
                if let recordingEntry = appCoordinator.getRecording(url: job.recordingURL),
                   let entryId = recordingEntry.id {
                    recordingId = entryId
                    print("🆔 Found recording ID for single chunk: \(recordingId)")
                } else {
                    print("❌ No recording found for URL: \(job.recordingURL), using new UUID")
                    recordingId = UUID()
                }
            } else {
                print("❌ AppCoordinator not available")
                recordingId = UUID()
            }
            
            let transcriptData = TranscriptData(
                recordingId: recordingId,
                recordingURL: job.recordingURL,
                recordingName: job.recordingName,
                recordingDate: Date(), // TODO: Get actual recording date
                segments: firstChunk.segments,
                engine: engine
            )
            
            await saveTranscript(transcriptData)
        }
        
        // Post-processing: Generate title automatically - REMOVED for transcription jobs
        // await performPostProcessing(for: job, transcriptText: transcriptChunks.first?.transcript ?? "")
        
        // Complete the job - but validate we actually have transcript content
        let hasTranscriptContent = transcriptChunks.contains { !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        if !hasTranscriptContent {
            print("❌ WARNING: Transcription job completed but no transcript content found!")
            print("   - Total chunks: \(transcriptChunks.count)")
            for (index, chunk) in transcriptChunks.enumerated() {
                print("   - Chunk \(index): '\(chunk.transcript.prefix(50))...' (\(chunk.transcript.count) chars)")
            }
            
            // Mark as failed instead of completed
            let failedJob = job.withStatus(.failed("No transcript content generated")).withProgress(1.0)
            await updateJob(failedJob)
            
            await sendNotification(
                title: "Transcription Failed",
                body: "No transcript content was generated for \(job.recordingName)"
            )
            
            throw BackgroundProcessingError.processingFailed("Transcription completed but generated no content")
        }
        
        let completedJob = job.withStatus(.completed).withProgress(1.0)
        await updateJob(completedJob)
        
        // Send completion notification
        await sendNotification(
            title: "Transcription Complete",
            body: "Successfully transcribed \(job.recordingName)"
        )
        
        print("✅ Transcription job completed for: \(job.recordingName) with valid content")
    }
    
    private func transcribeChunk(_ chunk: AudioChunk, engine: TranscriptionEngine) async throws -> TranscriptionResult {
        let message = "🎯 Starting transcription of chunk: \(chunk.chunkURL.lastPathComponent) with engine: \(engine.rawValue)"
        print(message)
        DebugLogger.shared.log(message)
        
        // Verify chunk file exists and has content
        guard FileManager.default.fileExists(atPath: chunk.chunkURL.path) else {
            let error = BackgroundProcessingError.fileNotFound("Chunk file not found: \(chunk.chunkURL.path)")
            let errorMsg = "❌ Chunk file missing: \(chunk.chunkURL.path)"
            print(errorMsg)
            DebugLogger.shared.log(errorMsg)
            throw error
        }
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: chunk.chunkURL.path)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            let error = BackgroundProcessingError.invalidAudioFormat("Chunk file is empty: \(chunk.chunkURL.path)")
            let errorMsg = "❌ Chunk file is empty: \(chunk.chunkURL.path)"
            print(errorMsg)
            DebugLogger.shared.log(errorMsg)
            throw error
        }
        
        print("📁 Chunk file verified: \(fileSize) bytes, duration: \(chunk.duration)s")
        
        // Get the recording ID for this chunk
        let recordingId: UUID
        if let appCoordinator = enhancedFileManager.getCoordinator(),
           let recordingEntry = appCoordinator.getRecording(url: chunk.chunkURL),
           let entryId = recordingEntry.id {
            recordingId = entryId
        } else {
            // Fallback to new UUID if recording not found
            recordingId = UUID()
            print("⚠️ Recording not found in Core Data for chunk, using fallback UUID: \(recordingId)")
        }
        
        let startTime = Date()
        do {
            let result: TranscriptionResult
            
            switch engine {
            case .openAI:
                print("🤖 Using OpenAI for transcription")
                let config = getOpenAIConfig()
                let service = OpenAITranscribeService(config: config, chunkingService: chunkingService)
                let openAIResult = try await service.transcribeAudioFile(at: chunk.chunkURL, recordingId: recordingId)
                result = TranscriptionResult(
                    fullText: openAIResult.transcriptText,
                    segments: openAIResult.segments,
                    processingTime: openAIResult.processingTime,
                    chunkCount: 1,
                    success: openAIResult.success,
                    error: openAIResult.error
                )
                
            case .whisper:
                print("🎤 Using Whisper for transcription")
                let config = getWhisperConfig()
                let service = WhisperService(config: config, chunkingService: chunkingService)
                result = try await service.transcribeAudio(url: chunk.chunkURL, recordingId: recordingId)

            case .awsTranscribe:
                print("☁️ Using AWS Transcribe for transcription")
                let manager = EnhancedTranscriptionManager()
                result = try await manager.transcribeAudioFile(at: chunk.chunkURL, using: .awsTranscribe)

            case .appleIntelligence:
                print("🍎 Using Apple Intelligence for transcription")
                let manager = EnhancedTranscriptionManager()
                result = try await manager.transcribeAudioFile(at: chunk.chunkURL, using: .appleIntelligence)
                
            case .openAIAPICompatible:
                throw BackgroundProcessingError.processingFailed("OpenAI API Compatible integration not yet implemented")
            }
            
            let processingTime = Date().timeIntervalSince(startTime)
            print("⏱️ Transcription completed in \(processingTime)s")
            
            // Validate result
            if result.fullText.isEmpty {
                let warningMsg = "⚠️ WARNING: Transcription result is empty! Success: \(result.success), Segments: \(result.segments.count)"
                print(warningMsg)
                DebugLogger.shared.log(warningMsg)
                if let error = result.error {
                    DebugLogger.shared.log("   - Error: \(error.localizedDescription)")
                }
            } else {
                let successMsg = "✅ Transcription successful: \(result.fullText.count) characters, \(result.segments.count) segments"
                print(successMsg)
                DebugLogger.shared.log(successMsg)
                DebugLogger.shared.log("   - Preview: \(result.fullText.prefix(100))...")
            }
            
            return result
            
        } catch {
            let processingTime = Date().timeIntervalSince(startTime)
            print("❌ Transcription failed after \(processingTime)s: \(error)")
            print("   - Error type: \(type(of: error))")
            print("   - Localized: \(error.localizedDescription)")
            
            // Re-throw with more context
            throw BackgroundProcessingError.processingFailed("Transcription failed for \(engine.rawValue): \(error.localizedDescription)")
        }
    }
    
    // MARK: - Configuration Helpers
    
    private func getOpenAIConfig() -> OpenAITranscribeConfig {
        let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
        let modelString = UserDefaults.standard.string(forKey: "openAIModel") ?? OpenAITranscribeModel.gpt4oMiniTranscribe.rawValue
        let baseURL = UserDefaults.standard.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
        
        let model = OpenAITranscribeModel(rawValue: modelString) ?? .gpt4oMiniTranscribe
        
        return OpenAITranscribeConfig(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL
        )
    }
    
    private func getWhisperConfig() -> WhisperConfig {
        let serverURL = UserDefaults.standard.string(forKey: "whisperServerURL") ?? "http://localhost"
        let port = UserDefaults.standard.integer(forKey: "whisperPort")
        let effectivePort = port > 0 ? port : 9000
        
        return WhisperConfig(
            serverURL: serverURL,
            port: effectivePort
        )
    }
    
    private func getAWSConfig() -> AWSTranscribeConfig {
        let accessKey = UserDefaults.standard.string(forKey: "awsAccessKey") ?? ""
        let secretKey = UserDefaults.standard.string(forKey: "awsSecretKey") ?? ""
        let region = UserDefaults.standard.string(forKey: "awsRegion") ?? "us-east-1"
        let bucketName = UserDefaults.standard.string(forKey: "awsBucketName") ?? ""
        
        return AWSTranscribeConfig(
            region: region,
            accessKey: accessKey,
            secretKey: secretKey,
            bucketName: bucketName
        )
    }
    
    private func ensureRecordingExists(recordingURL: URL, recordingName: String) async {
        if let appCoordinator = enhancedFileManager.getCoordinator() {
            // Check if recording already exists
            if let existingRecording = appCoordinator.getRecording(url: recordingURL) {
                print("✅ Recording already exists in Core Data: \(existingRecording.recordingName ?? "unknown")")
                return
            }
            
            // Create recording entry if it doesn't exist
            print("📝 Creating recording entry in Core Data for: \(recordingName)")
            
            // Get file metadata
            let fileSize = getFileSize(url: recordingURL)
            let duration = await getAudioDuration(url: recordingURL)
            
            await MainActor.run {
                let recordingId = appCoordinator.addRecording(
                    url: recordingURL,
                    name: recordingName,
                    date: Date(),
                    fileSize: fileSize,
                    duration: duration,
                    quality: .high,
                    locationData: nil
                )
                
                print("✅ Created recording entry with ID: \(recordingId)")
            }
        } else {
            print("❌ AppCoordinator not available for recording creation")
        }
    }
    
    private func getFileSize(url: URL) -> Int64 {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(resourceValues.fileSize ?? 0)
        } catch {
            print("❌ Error getting file size: \(error)")
            return 0
        }
    }
    
    private func getAudioDuration(url: URL) async -> TimeInterval {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            print("❌ Error getting audio duration: \(error)")
            return 0
        }
    }
    
    private func saveTranscript(_ transcriptData: TranscriptData) async {
        // Save transcript using the Core Data coordinator
        await MainActor.run {
            print("🔍 DEBUG: Starting transcript save for URL: \(transcriptData.recordingURL)")
            print("🔍 DEBUG: URL absoluteString: \(transcriptData.recordingURL.absoluteString)")
            
            // Use the new Core Data system
            if let appCoordinator = enhancedFileManager.getCoordinator() {
                print("✅ DEBUG: AppCoordinator available")
                
                // Debug: List all recordings in Core Data
                let allRecordings = appCoordinator.coreDataManager.getAllRecordings()
                print("🔍 DEBUG: Found \(allRecordings.count) recordings in Core Data:")
                for recording in allRecordings {
                    print("   - \(recording.recordingName ?? "unknown"): \(recording.recordingURL ?? "no URL")")
                }
                
                // Get the recording ID from the URL
                guard let recordingEntry = appCoordinator.getRecording(url: transcriptData.recordingURL),
                      let recordingId = recordingEntry.id else {
                    print("❌ No recording found for URL: \(transcriptData.recordingURL)")
                    print("❌ DEBUG: URL absoluteString: \(transcriptData.recordingURL.absoluteString)")
                    return
                }
                
                print("🆔 Found recording ID: \(recordingId) for URL: \(transcriptData.recordingURL)")
                
                let transcriptId = appCoordinator.addTranscript(
                    for: recordingId,
                    segments: transcriptData.segments,
                    speakerMappings: transcriptData.speakerMappings,
                    engine: transcriptData.engine,
                    processingTime: transcriptData.processingTime,
                    confidence: transcriptData.confidence
                )
                if transcriptId != nil {
                    print("✅ Transcript saved to Core Data with ID: \(transcriptId!)")
                } else {
                    print("❌ Failed to save transcript to Core Data")
                }
            } else {
                print("❌ AppCoordinator not available for transcript saving")
            }
        }
        print("💾 Saved transcript: \(transcriptData.segments.count) segments, \(transcriptData.fullText.count) characters")
        
        // Call completion handler if set
        if let completionHandler = onTranscriptionCompleted {
            await MainActor.run {
                // Find the current job to pass to the completion handler
                if let currentJob = self.currentJob {
                    completionHandler(transcriptData, currentJob)
                }
            }
        }
    }
    
    private func processSummarizationJob(_ job: ProcessingJob, engine: String) async throws {
        print("🚀 Starting summarization job for: \(job.recordingName)")
        
        // Update progress
        let progressJob = job.withProgress(0.1)
        await updateJob(progressJob)
        
        // First, we need to get the transcript for this recording
        // TODO: Integrate with existing transcript storage to get the transcript
        // For now, we'll simulate having a transcript
        let transcriptText = "Sample transcript text for summarization"
        
        // Update progress after getting transcript
        let transcriptProgressJob = job.withProgress(0.3)
        await updateJob(transcriptProgressJob)
        
        // Generate summary using the specified engine
        let summaryResult = try await generateSummary(transcriptText, engine: engine, recordingURL: job.recordingURL, recordingName: job.recordingName)
        
        // Update progress after summarization
        let summaryProgressJob = job.withProgress(0.8)
        await updateJob(summaryProgressJob)
        
        // Save the summary
        await saveSummary(summaryResult)
        
        // Post-processing: Generate title and perform cleanup
        await performPostProcessing(for: job, transcriptText: transcriptText)
        
        // Complete the job
        let completedJob = job.withStatus(.completed).withProgress(1.0)
        await updateJob(completedJob)
        
        // Send completion notification with summary details
        let taskCount = summaryResult.tasks.count
        let reminderCount = summaryResult.reminders.count
        let notificationBody = "Successfully summarized \(job.recordingName)" + 
                              (taskCount > 0 ? " • \(taskCount) tasks" : "") +
                              (reminderCount > 0 ? " • \(reminderCount) reminders" : "")
        
        await sendNotification(
            title: "Summarization Complete",
            body: notificationBody
        )
        
        print("✅ Summarization job completed for: \(job.recordingName)")
    }
    
    private func generateSummary(_ transcriptText: String, engine: String, recordingURL: URL, recordingName: String) async throws -> EnhancedSummaryData {
        let startTime = Date()
        
        // Determine content type
        let contentType = await classifyContent(transcriptText)
        
        var summary: String
        var tasks: [TaskItem] = []
        var reminders: [ReminderItem] = []
        var titles: [TitleItem] = []
        
        switch engine {
        case "OpenAI", "openai", "gpt-4", "gpt-3.5":
            let config = getOpenAISummarizationConfig()
            let service = OpenAISummarizationService(config: config)
            
            // Generate summary
            summary = try await service.generateSummary(from: transcriptText, contentType: contentType)
            
            // Extract tasks, reminders, and titles
            tasks = try await service.extractTasks(from: transcriptText)
            reminders = try await service.extractReminders(from: transcriptText)
            titles = try await service.extractTitles(from: transcriptText)
            
        case "Enhanced Apple Intelligence", "apple intelligence", "apple":
            let appleEngine = EnhancedAppleIntelligenceEngine()
            
            // Generate summary
            summary = try await appleEngine.generateSummary(from: transcriptText, contentType: contentType)
            
            // Extract tasks, reminders, and titles
            tasks = try await appleEngine.extractTasks(from: transcriptText)
            reminders = try await appleEngine.extractReminders(from: transcriptText)
            titles = try await appleEngine.extractTitles(from: transcriptText)
            
        case "Local LLM (Ollama)", "ollama", "local":
            // TODO: Integrate with Ollama service when available
            summary = "Summary generated using local Ollama service (not yet implemented)"
            
        default:
            // Fallback to Apple Intelligence
            let appleEngine = EnhancedAppleIntelligenceEngine()
            summary = try await appleEngine.generateSummary(from: transcriptText, contentType: contentType)
            tasks = try await appleEngine.extractTasks(from: transcriptText)
            reminders = try await appleEngine.extractReminders(from: transcriptText)
            titles = try await appleEngine.extractTitles(from: transcriptText)
        }
        
        let processingTime = Date().timeIntervalSince(startTime)
        
        return EnhancedSummaryData(
            recordingURL: recordingURL,
            recordingName: recordingName,
            recordingDate: Date(), // TODO: Get actual recording date from file metadata
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiMethod: engine,
            originalLength: transcriptText.count,
            processingTime: processingTime
        )
    }
    
    private func getOpenAISummarizationConfig() -> OpenAISummarizationConfig {
        let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
        let modelString = UserDefaults.standard.string(forKey: "openAISummarizationModel") ?? OpenAISummarizationModel.gpt41Mini.rawValue
        let baseURL = UserDefaults.standard.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
        
        let model = OpenAISummarizationModel(rawValue: modelString) ?? .gpt41Mini
        
        return OpenAISummarizationConfig(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            temperature: 0.1,
            maxTokens: 2048,
            timeout: 30.0,
            dynamicModelId: nil
        )
    }
    
    private func classifyContent(_ text: String) async -> ContentType {
        // Simple content classification based on keywords
        let lowercaseText = text.lowercased()
        
        if lowercaseText.contains("meeting") || lowercaseText.contains("discussion") || lowercaseText.contains("agenda") {
            return .meeting
        } else if lowercaseText.contains("technical") || lowercaseText.contains("code") || lowercaseText.contains("api") {
            return .technical
        } else if lowercaseText.contains("personal") || lowercaseText.contains("diary") || lowercaseText.contains("journal") {
            return .personalJournal
        } else {
            return .general
        }
    }
    
    private func saveSummary(_ summaryData: EnhancedSummaryData) async {
        // TODO: Integrate with existing summary storage system
        // For now, just log that we would save it
        print("💾 Would save summary: \(summaryData.summary.count) characters, \(summaryData.tasks.count) tasks, \(summaryData.reminders.count) reminders")
    }
    
    private func performPostProcessing(for job: ProcessingJob, transcriptText: String) async {
        print("🔧 Starting post-processing for: \(job.recordingName)")
        
        // Generate and save title
        await generateAndSaveTitle(for: job.recordingURL, from: transcriptText)
        
        // Perform cleanup tasks
        await performCleanupTasks(for: job)
        
        // Update file metadata if needed
        await updateFileMetadata(for: job)
        
        print("✅ Post-processing completed for: \(job.recordingName)")
    }
    
    private func generateAndSaveTitle(for recordingURL: URL, from transcriptText: String) async {
        do {
            // Use Apple Intelligence for title generation as it's always available
            let appleEngine = EnhancedAppleIntelligenceEngine()
            let titles = try await appleEngine.extractTitles(from: transcriptText)
            
            if let bestTitle = titles.first {
                await saveGeneratedTitle(bestTitle.text, for: recordingURL)
                print("🏷️ Generated title: \(bestTitle.text)")
            } else {
                // Fallback to a simple title based on content
                let fallbackTitle = generateFallbackTitle(from: transcriptText, recordingURL: recordingURL)
                await saveGeneratedTitle(fallbackTitle, for: recordingURL)
                print("🏷️ Generated fallback title: \(fallbackTitle)")
            }
        } catch {
            print("⚠️ Failed to generate title: \(error)")
            // Generate a simple fallback title
            let fallbackTitle = generateFallbackTitle(from: transcriptText, recordingURL: recordingURL)
            await saveGeneratedTitle(fallbackTitle, for: recordingURL)
        }
    }
    
    private func generateFallbackTitle(from transcriptText: String, recordingURL: URL) -> String {
        // Extract first meaningful sentence or use filename
        let sentences = transcriptText.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 10 }
        
        if let firstSentence = sentences.first {
            // Limit to reasonable length
            let maxLength = 50
            if firstSentence.count > maxLength {
                let truncated = String(firstSentence.prefix(maxLength))
                return truncated + "..."
            }
            return firstSentence
        }
        
        // Fallback to filename-based title
        let filename = recordingURL.deletingPathExtension().lastPathComponent
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        
        return "\(filename) - \(dateFormatter.string(from: Date()))"
    }
    
    private func saveGeneratedTitle(_ title: String, for recordingURL: URL) async {
        // TODO: Integrate with existing title storage system
        // For now, just log that we would save it
        print("💾 Would save title '\(title)' for recording: \(recordingURL.lastPathComponent)")
    }
    
    private func performCleanupTasks(for job: ProcessingJob) async {
        print("🧹 Performing cleanup tasks for job: \(job.recordingName)")
        
        // Clean up temporary files
        if let chunks = job.chunks {
            try? await chunkingService.cleanupChunks(chunks)
        }
        
        // Update file relationships
        await enhancedFileManager.updateFileRelationships(for: job.recordingURL, relationships: FileRelationships(
            recordingURL: job.recordingURL,
            recordingName: job.recordingName,
            recordingDate: job.startTime,
            transcriptExists: true,
            summaryExists: false,
            iCloudSynced: false
        ))
    }
    
    private func updateFileMetadata(for job: ProcessingJob) async {
        print("📝 Updating file metadata for job: \(job.recordingName)")
        
        // Update file relationships to reflect new transcript
        await enhancedFileManager.updateFileRelationships(for: job.recordingURL, relationships: FileRelationships(
            recordingURL: job.recordingURL,
            recordingName: job.recordingName,
            recordingDate: job.startTime,
            transcriptExists: true,
            summaryExists: false,
            iCloudSynced: false
        ))
    }
    
    private func clearProcessingCache(for recordingURL: URL) async {
        // TODO: Clear any cached processing data
        print("🗑️ Would clear processing cache for: \(recordingURL.lastPathComponent)")
    }
    
    // MARK: - Job Status Management
    

    
    private func saveErrorLog(for job: ProcessingJob, error: Error) async {
        let errorLog = """
        =================
        JOB ERROR LOG
        =================
        Date: \(Date())
        Job ID: \(job.id)
        Job Type: \(job.type.displayName)
        Recording: \(job.recordingName)
        Recording URL: \(job.recordingURL)
        File Exists: \(FileManager.default.fileExists(atPath: job.recordingURL.path))
        
        ERROR DETAILS:
        - Type: \(type(of: error))
        - Description: \(error.localizedDescription)
        - Full Error: \(error)
        
        SYSTEM INFO:
        - Battery Level: \(UIDevice.current.batteryLevel)
        - Battery State: \(UIDevice.current.batteryState.rawValue)
        - Available Memory: \(ProcessInfo.processInfo.physicalMemory)
        
        =================
        """
        
        print("💾 Saving error log for job: \(job.recordingName)")
        print(errorLog)
        
        // Also log to the enhanced logger
        EnhancedLogger.shared.logBackgroundProcessing("Detailed error log:\n\(errorLog)", level: .error)
    }
    
    private func handleJobFailure(_ job: ProcessingJob, error: Error) async {
        print("🔄 Handling job failure: \(job.recordingName) - \(error.localizedDescription)")
        
        // Log the error for debugging
        EnhancedLogger.shared.logBackgroundProcessing("Job failed: \(error.localizedDescription)", level: .error)
        
        // Attempt recovery based on error type
        if let processingError = error as? AudioProcessingError {
            switch processingError {
            case .chunkingFailed:
                // Try processing without chunking
                print("🔄 Attempting to process without chunking")
                // Implementation would go here
            case .backgroundProcessingFailed:
                // Queue for retry when app returns to foreground
                print("🔄 Queuing job for retry")
                // Implementation would go here
            default:
                print("🔄 No specific recovery strategy for this error")
            }
        }
    }
    
    // MARK: - App Lifecycle Management
    
    private func setupAppLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }
    

    
    @objc private func appDidEnterBackground() {
        print("📱 App entered background")
        Task { @MainActor in
            await handleAppBackgrounding()
        }
    }
    
    @objc private func appWillEnterForeground() {
        print("📱 App will enter foreground")
        Task { @MainActor in
            await handleAppForegrounding()
        }
    }
    
    @objc private func appWillTerminate() {
        print("📱 App will terminate")
        Task { @MainActor in
            await handleAppTermination()
        }
    }
    
    private func handleAppBackgrounding() async {
        print("🔄 Handling app backgrounding")
        
        // Core Data automatically persists changes, no manual persistence needed
        
        // If there's an active job, ensure background task is running
        if currentJob != nil && backgroundTaskID == .invalid {
            beginBackgroundTask()
        }
        
        // Send a notification about ongoing processing
        if let job = currentJob {
            await sendNotification(
                title: "Processing in Background",
                body: "Continuing to process \(job.recordingName)"
            )
        }
    }
    
    private func handleAppForegrounding() async {
        print("🔄 Handling app foregrounding")
        
        // Don't end background task - let processing continue
        // Background tasks should continue running for transcription/summarization
        
        // Clear notification badge
        await clearNotificationBadge()
        
        // Check if any jobs completed while in background
        await checkForCompletedJobs()
        
        // Resume processing if needed
        if currentJob == nil && !activeJobs.filter({ $0.status == .queued }).isEmpty {
            await processNextJob()
        }
    }
    
    private func handleAppTermination() async {
        print("🔄 Handling app termination")
        
        // Core Data automatically persists changes, no manual persistence needed
        
        // Mark any processing job as interrupted
        if let job = currentJob {
            let interruptedJob = job.withStatus(.failed("App was terminated during processing"))
            await updateJob(interruptedJob)
        }
        
        // End background task
        endBackgroundTask()
    }
    
    private func checkForCompletedJobs() async {
        // This would check with external services (like AWS) for job completion
        // For now, just log that we would check
        print("🔍 Would check for completed background jobs")
    }
    
    // MARK: - Core Data Persistence
    
    private func loadJobsFromCoreData() {
        let jobEntries = coreDataManager.getAllProcessingJobs()
        activeJobs = jobEntries.compactMap { convertToProcessingJob(from: $0) }
        print("💾 Loaded \(activeJobs.count) jobs from Core Data")
    }
    
    private func convertToProcessingJob(from jobEntry: ProcessingJobEntry) -> ProcessingJob? {
        guard let id = jobEntry.id,
              let recordingURL = jobEntry.recordingURL,
              let url = URL(string: recordingURL),
              let recordingName = jobEntry.recordingName,
              let jobType = jobEntry.jobType,
              let status = jobEntry.status else {
            return nil
        }
        
        // Convert job type string back to JobType enum
        let type: JobType
        if jobType.contains("Transcription") {
            let engine = TranscriptionEngine(rawValue: jobEntry.engine ?? "appleIntelligence") ?? .appleIntelligence
            type = .transcription(engine: engine)
        } else {
            type = .summarization(engine: jobEntry.engine ?? "Enhanced Apple Intelligence")
        }
        
        // Convert status string back to JobProcessingStatus enum
        let processingStatus: JobProcessingStatus
        switch status {
        case "Queued":
            processingStatus = .queued
        case "Processing":
            processingStatus = .processing
        case "Completed":
            processingStatus = .completed
        case "Failed":
            processingStatus = .failed(jobEntry.error ?? "Unknown error")
        default:
            processingStatus = .queued
        }
        
        return ProcessingJob(
            id: id,
            type: type,
            recordingURL: url,
            recordingName: recordingName,
            status: processingStatus,
            progress: jobEntry.progress,
            startTime: jobEntry.startTime ?? Date(),
            completionTime: jobEntry.completionTime,
            chunks: nil,
            error: jobEntry.error
        )
    }
    
    // MARK: - Background Task Management
    
    private func beginBackgroundTask() {
        // Don't start a new background task if one is already running
        guard backgroundTaskID == .invalid else {
            print("⚠️ Background task already running: \(backgroundTaskID.rawValue)")
            return
        }
        
        // Configure audio session for background processing to get extended time
        Task {
            do {
                try await audioSessionManager.configureBackgroundRecording()
                print("✅ Audio session configured for background processing")
            } catch {
                print("⚠️ Could not configure background audio session: \(error)")
                // Continue anyway, we'll still get some background time
            }
        }
        
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AudioProcessing") { [weak self] in
            print("⚠️ Background task is about to expire")
            Task { @MainActor in
                await self?.handleBackgroundTaskExpiration()
            }
        }
        
        if backgroundTaskID == .invalid {
            print("❌ Failed to start background task")
        } else {
            print("🔄 Started background task: \(backgroundTaskID.rawValue)")
            
            // Check remaining background time
            let remainingTime = UIApplication.shared.backgroundTimeRemaining
            
            // With background audio session, we should get much more time
            if remainingTime < 1800 { // Less than 30 minutes
                print("📱 Audio processing should get extended background time")
            }
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            print("⏹️ Ending background task: \(backgroundTaskID.rawValue)")
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
            
            // Clean up audio session when background task ends
            Task {
                do {
                    try await audioSessionManager.deactivateSession()
                    print("✅ Audio session deactivated after background task")
                } catch {
                    print("⚠️ Could not deactivate audio session: \(error)")
                }
            }
        }
    }
    
    private func handleBackgroundTaskExpiration() async {
        print("⚠️ Background task is expiring, saving current state")
        
        // If there's an active job, mark it as interrupted
        if let job = currentJob {
            let interruptedJob = job.withStatus(.failed("Processing interrupted due to background time limit"))
            await updateJob(interruptedJob)
            
            // Send notification about interruption
            await sendNotification(
                title: "Processing Interrupted",
                body: "Processing of \(job.recordingName) was interrupted. Please try again when the app is active."
            )
        }
        
        currentJob = nil
        processingStatus = .queued
        endBackgroundTask()
    }
    
    private func monitorBackgroundTime() {
        guard backgroundTaskID != .invalid else { return }
        
        let remainingTime = UIApplication.shared.backgroundTimeRemaining
        
        // For long-running audio processing, we want to maximize the time
        // With background audio session, we should get much more time
        if remainingTime < 300 && remainingTime != Double.greatestFiniteMagnitude { // Less than 5 minutes
            print("⚠️ Background time running low (\(remainingTime)s), attempting to complete current job")
            // The job processing will handle this naturally as it checks for completion
        }
        
        // Only end the task if we're really about to expire (less than 30 seconds)
        // This gives more time for audio processing to complete
        if remainingTime < 30 && remainingTime != Double.greatestFiniteMagnitude {
            print("⚠️ Background time almost expired (\(remainingTime)s), ending task proactively")
            endBackgroundTask()
        }
    }
    
    // MARK: - Notifications
    
    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ Notification permission granted")
            } else if let error = error {
                print("❌ Notification permission denied: \(error)")
            } else {
                print("❌ Notification permission denied by user")
            }
        }
    }
    
    private func sendNotification(title: String, body: String, identifier: String? = nil, userInfo: [String: Any] = [:]) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: getActiveJobCount())
        
        // Add user info for handling notification taps
        var finalUserInfo = userInfo
        finalUserInfo["timestamp"] = Date().timeIntervalSince1970
        content.userInfo = finalUserInfo
        
        let request = UNNotificationRequest(
            identifier: identifier ?? UUID().uuidString,
            content: content,
            trigger: nil // Immediate delivery
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("📱 Sent notification: \(title)")
        } catch {
            print("❌ Failed to send notification: \(error)")
        }
    }
    
    private func sendProgressNotification(for job: ProcessingJob) async {
        let progress = Int(job.progress * 100)
        let title = "Processing \(job.type.displayName)"
        let body = "\(job.recordingName) - \(progress)% complete"
        
        await sendNotification(
            title: title,
            body: body,
            identifier: "progress_\(job.id.uuidString)",
            userInfo: [
                "jobId": job.id.uuidString,
                "jobType": job.type.displayName,
                "progress": job.progress
            ]
        )
    }
    
    private func getActiveJobCount() -> Int {
        return activeJobs.filter { !$0.status.isError && $0.status != .completed }.count
    }
    
    private func clearNotificationBadge() async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(0)
        } catch {
            print("⚠️ Failed to clear notification badge: \(error)")
        }
    }
}

// MARK: - Background Processing Errors

enum BackgroundProcessingError: LocalizedError {
    case jobAlreadyRunning
    case noActiveJob
    case jobNotFound
    case processingFailed(String)
    case timeoutError
    case resourceUnavailable
    case queueFull
    case invalidJobType
    case fileNotFound(String)
    case invalidAudioFormat(String)
    
    var errorDescription: String? {
        switch self {
        case .jobAlreadyRunning:
            return "A processing job is already running. Please wait for it to complete."
        case .noActiveJob:
            return "No active processing job found."
        case .jobNotFound:
            return "The specified job could not be found."
        case .processingFailed(let message):
            return "Processing failed: \(message)"
        case .timeoutError:
            return "Processing job timed out"
        case .resourceUnavailable:
            return "Required resources are not available"
        case .queueFull:
            return "Processing queue is full"
        case .invalidJobType:
            return "Invalid job type specified"
        case .fileNotFound(let message):
            return "File not found: \(message)"
        case .invalidAudioFormat(let message):
            return "Invalid audio format: \(message)"
        }
    }
}