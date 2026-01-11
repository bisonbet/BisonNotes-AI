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
import BackgroundTasks

// MARK: - Processing Job Models

struct ProcessingJob: Identifiable, Codable {
    let id: UUID
    let type: JobType
    let recordingPath: String // Changed from URL to String for relative path
    let recordingName: String
    let status: JobProcessingStatus
    let progress: Double
    let startTime: Date
    let completionTime: Date?
    let chunks: [AudioChunk]?
    let error: String?
    
    // Computed property to get absolute URL when needed
    var recordingURL: URL {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // Fallback to a temporary URL if documents directory is not available
            return URL(fileURLWithPath: "/tmp/\(recordingPath)")
        }
        return documentsURL.appendingPathComponent(recordingPath)
    }
    
    init(type: JobType, recordingURL: URL, recordingName: String, chunks: [AudioChunk]? = nil) {
        self.id = UUID()
        self.type = type
        // Store only the filename as relative path
        self.recordingPath = recordingURL.lastPathComponent
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
            recordingPath: self.recordingPath,
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
            recordingPath: self.recordingPath,
            recordingName: self.recordingName,
            status: self.status,
            progress: progress,
            startTime: self.startTime,
            completionTime: self.completionTime,
            chunks: self.chunks,
            error: self.error
        )
    }
    
    init(id: UUID, type: JobType, recordingPath: String, recordingName: String, status: JobProcessingStatus, progress: Double, startTime: Date, completionTime: Date?, chunks: [AudioChunk]?, error: String?) {
        self.id = id
        self.type = type
        self.recordingPath = recordingPath
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
    private var backgroundTaskStartTime: Date?
    private var backgroundTimeMonitor: Task<Void, Never>?
    private let chunkingService = AudioFileChunkingService()
    private let performanceOptimizer = PerformanceOptimizer.shared
    private let enhancedFileManager = EnhancedFileManager.shared
    private let audioSessionManager = EnhancedAudioSessionManager()
    private let coreDataManager = CoreDataManager()
    private var keepAlivePlayer: AVAudioPlayer?
    
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
        // Cancel any existing monitoring
        backgroundTimeMonitor?.cancel()

        // Start periodic monitoring every 20 seconds to catch tasks that need refreshing
        // We refresh at 25s, so checking every 20s ensures we catch them in time
        backgroundTimeMonitor = Task {
            while !Task.isCancelled && backgroundTaskID != .invalid {
                try? await Task.sleep(nanoseconds: 20_000_000_000) // 20 seconds

                if !Task.isCancelled {
                    monitorBackgroundTime()
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
        
        // For transcription jobs, check if we need to replace an existing job
        await addTranscriptionJob(job)
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
        
        await endBackgroundTask()
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
    
    func debugJobStatus() {
        print("🔍 BackgroundProcessingManager Debug Status:")
        print("   - Active jobs count: \(activeJobs.count)")
        print("   - Current job: \(currentJob?.recordingName ?? "None")")
        print("   - Processing status: \(processingStatus)")
        print("   - Background task ID: \(backgroundTaskID.rawValue)")
        
        for (index, job) in activeJobs.enumerated() {
            print("   - Job \(index): \(job.recordingName) - \(job.status) - Progress: \(job.progress)")
        }
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
        // Check for existing jobs for the same recording to prevent duplicates
        let existingJobs = activeJobs.filter { existingJob in
            existingJob.recordingPath == job.recordingPath && 
            existingJob.type.displayName == job.type.displayName &&
            (existingJob.status == .queued || existingJob.status == .processing)
        }
        
        if !existingJobs.isEmpty {
            print("⚠️ Job already exists for \(job.recordingName) (\(job.type.displayName)). Skipping duplicate.")
            return
        }
        
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
    
    private func addTranscriptionJob(_ job: ProcessingJob) async {
        // For transcription jobs, we want to allow reruns by replacing existing completed/failed jobs
        let existingJobs = activeJobs.filter { existingJob in
            existingJob.recordingPath == job.recordingPath && 
            existingJob.type.displayName == job.type.displayName
        }
        
        // Remove any existing transcription jobs for this recording (to allow reruns)
        for existingJob in existingJobs {
            if let index = activeJobs.firstIndex(where: { $0.id == existingJob.id }) {
                print("🔄 Removing existing transcription job for \(job.recordingName) to allow rerun")
                activeJobs.remove(at: index)
                
                // Also remove from Core Data
                if let jobEntry = coreDataManager.getProcessingJob(id: existingJob.id) {
                    coreDataManager.deleteProcessingJob(jobEntry)
                }
            }
        }
        
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
        print("✅ Added new transcription job for \(job.recordingName) (replacing existing job)")
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
    
    func processNextJob() async {
        // Find the next queued job
        guard let nextJob = activeJobs.first(where: { $0.status == .queued }) else {
            currentJob = nil
            processingStatus = .queued
            await endBackgroundTask() // Ensure background task is ended when no more jobs
            return
        }
        
        currentJob = nextJob
        processingStatus = .processing
        
        // Start background task
        await beginBackgroundTask()
        
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
        await endBackgroundTask()
        
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
                // print("🔍 DEBUG: Looking for recording with URL: \(job.recordingURL)")
                // print("🔍 DEBUG: URL absoluteString: \(job.recordingURL.absoluteString)")
                
                // Use the new Core Data system
                
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
                // print("🔍 DEBUG: Looking for recording with URL: \(job.recordingURL)")
                // print("🔍 DEBUG: URL absoluteString: \(job.recordingURL.absoluteString)")
                
                // Use the new Core Data system
                
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
        
        // Enhanced chunk diagnostics
        print("🔍 Chunk details:")
        print("   - ID: \(chunk.id)")
        print("   - Sequence: \(chunk.sequenceNumber)")
        print("   - Duration: \(chunk.duration)s (\(chunk.duration/60) minutes)")
        print("   - Start time: \(chunk.startTime)s")
        print("   - End time: \(chunk.endTime)s")
        print("   - File size: \(chunk.fileSize) bytes (\(chunk.fileSize/1024/1024) MB)")
        print("   - Original URL: \(chunk.originalURL.lastPathComponent)")
        print("   - Chunk URL: \(chunk.chunkURL.lastPathComponent)")
        print("   - URLs match: \(chunk.originalURL == chunk.chunkURL)")
        
        // Verify chunk file exists and has content
        guard FileManager.default.fileExists(atPath: chunk.chunkURL.path) else {
            let error = BackgroundProcessingError.fileNotFound("Chunk file not found: \(chunk.chunkURL.path)")
            let errorMsg = "❌ Chunk file missing: \(chunk.chunkURL.path)"
            print(errorMsg)
            throw error
        }
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: chunk.chunkURL.path)[.size] as? Int64) ?? 0
        if fileSize == 0 {
            let error = BackgroundProcessingError.invalidAudioFormat("Chunk file is empty: \(chunk.chunkURL.path)")
            let errorMsg = "❌ Chunk file is empty: \(chunk.chunkURL.path)"
            print(errorMsg)
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
            case .notConfigured:
                throw BackgroundProcessingError.processingFailed("Transcription engine not configured. Please configure a transcription engine in Settings.")
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
                let config = getWhisperConfig()
                let service = WhisperService(config: config, chunkingService: chunkingService)
                
                // CRITICAL: Disable Wyoming client background task management since we're already managing it
                service.disableWyomingBackgroundTaskManagement()
                
                result = try await service.transcribeAudio(url: chunk.chunkURL, recordingId: recordingId)

            case .awsTranscribe:
                let manager = EnhancedTranscriptionManager()
                result = try await manager.transcribeAudioFile(at: chunk.chunkURL, using: .awsTranscribe)

            case .appleIntelligence:
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
                if let error = result.error {
                    print("   - Error: \(error.localizedDescription)")
                }
                
                // Check if this is a silent audio chunk or processing issue
                if result.success && result.segments.count > 0 {
                    print("   - Audio chunk processed successfully but contains no speech content")
                    print("   - This may indicate a silent audio segment or background noise only")
                } else {
                    print("   - This may indicate a processing error or invalid audio format")
                }
                
                // Return a result indicating no speech detected instead of empty transcription
                return TranscriptionResult(
                    fullText: "[No speech detected in this audio segment]",
                    segments: result.segments,
                    processingTime: result.processingTime,
                    chunkCount: result.chunkCount,
                    success: true,
                    error: nil
                )
            } else {
                let successMsg = "✅ Transcription successful: \(result.fullText.count) characters, \(result.segments.count) segments"
                print(successMsg)
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
        let serverURL = UserDefaults.standard.string(forKey: "whisperServerURL") ?? "localhost"
        let port = UserDefaults.standard.integer(forKey: "whisperPort")
        let protocolString = UserDefaults.standard.string(forKey: "whisperProtocol") ?? WhisperProtocol.rest.rawValue
        let selectedProtocol = WhisperProtocol(rawValue: protocolString) ?? .rest
        
        print("🔍 BackgroundProcessingManager - Whisper config: serverURL=\(serverURL), port=\(port), protocol=\(selectedProtocol.rawValue)")
        
        // Use default port if not set (UserDefaults.integer returns 0 if key doesn't exist)
        let effectivePort = port > 0 ? port : (selectedProtocol == .wyoming ? 10300 : 9000)
        
        // Ensure URL format matches protocol
        var processedServerURL = serverURL
        if selectedProtocol == .rest && !serverURL.hasPrefix("http://") && !serverURL.hasPrefix("https://") {
            processedServerURL = "http://" + serverURL
        }
        
        return WhisperConfig(
            serverURL: processedServerURL,
            port: effectivePort,
            whisperProtocol: selectedProtocol
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
                    quality: .whisperOptimized,
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
            
            // Use the new Core Data system
            if let appCoordinator = enhancedFileManager.getCoordinator() {
                // print("✅ DEBUG: AppCoordinator available")
                
                // Use the new Core Data system
                
                // Get the recording ID from the URL
                guard let recordingEntry = appCoordinator.getRecording(url: transcriptData.recordingURL),
                      let recordingId = recordingEntry.id else {
                    print("❌ No recording found for URL: \(transcriptData.recordingURL)")
                    // print("❌ DEBUG: URL absoluteString: \(transcriptData.recordingURL.absoluteString)")
                    return
                }
                
                print("🆔 Found recording ID: \(recordingId) for URL: \(transcriptData.recordingURL)")
                
                let transcriptId = appCoordinator.addTranscript(
                    for: recordingId,
                    segments: transcriptData.segments,
                    speakerMappings: [:], // No speaker mappings needed
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
            
        case "Apple Intelligence", "apple intelligence", "apple":
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
        
        // Determine engine type for background processing
        let engineType: String
        let lowerEngine = engine.lowercased()
        if lowerEngine.contains("openai") || lowerEngine.contains("gpt") {
            engineType = "OpenAI"
        } else if lowerEngine.contains("bedrock") || lowerEngine.contains("aws") {
            engineType = "AWS Bedrock"
        } else if lowerEngine.contains("google") || lowerEngine.contains("gemini") {
            engineType = "Google AI"
        } else if lowerEngine.contains("apple") {
            engineType = "Apple Intelligence"
        } else if lowerEngine.contains("ollama") {
            engineType = "Ollama"
        } else {
            engineType = "Background Service"
        }
        
        return EnhancedSummaryData(
            recordingURL: recordingURL,
            recordingName: recordingName,
            recordingDate: Date(), // TODO: Get actual recording date from file metadata
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiEngine: engineType,
            aiModel: engine,
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
            timeout: SummarizationTimeouts.current(),
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
        
        // If there's an active job, ensure background task is running
        if currentJob != nil && backgroundTaskID == .invalid {
            await beginBackgroundTask()
        }
        
        // Schedule background processing task if there are queued jobs
        await scheduleBackgroundProcessingIfNeeded()
        
        // Send a notification about ongoing processing
        if let job = currentJob {
            await sendNotification(
                title: "Processing in Background",
                body: "Continuing to process \(job.recordingName)"
            )
        } else if !activeJobs.filter({ $0.status == .queued }).isEmpty {
            await sendNotification(
                title: "Jobs Queued",
                body: "Your audio processing will continue when you return to the app."
            )
        }
    }
    
    /// Schedule background processing task for queued jobs
    private func scheduleBackgroundProcessingIfNeeded() async {
        guard !activeJobs.filter({ $0.status == .queued }).isEmpty else { return }
        
        let request = BGProcessingTaskRequest(identifier: "com.bisonai.audio-processing")
        request.requiresNetworkConnectivity = true // For cloud-based transcription services
        request.requiresExternalPower = false // Can run on battery
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10) // Start in 10 seconds
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("✅ Scheduled background processing task for queued jobs")
        } catch {
            print("❌ Failed to schedule background processing: \(error)")
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
        
        // Resume processing of any interrupted jobs
        await resumeInterruptedJobs()
        
        // Post notification for other components to check for unprocessed recordings
        NotificationCenter.default.post(name: NSNotification.Name("CheckForUnprocessedRecordings"), object: nil)
        
        // Resume processing if needed
        if currentJob == nil && !activeJobs.filter({ $0.status == .queued }).isEmpty {
            print("🚀 Resuming queued background processing jobs")
            await processNextJob()
        }
    }
    
    /// Resume jobs that were interrupted due to background limitations
    private func resumeInterruptedJobs() async {
        let interruptedJobs = activeJobs.filter { job in
            if case .failed(let message) = job.status {
                return message.contains("interrupted when app went to background")
            }
            return false
        }
        
        if !interruptedJobs.isEmpty {
            print("🔄 Found \(interruptedJobs.count) interrupted jobs to resume")
            
            // Deduplicate jobs by recording path to avoid processing the same recording multiple times
            var seenRecordings: Set<String> = []
            var jobsToResume: [ProcessingJob] = []
            var jobsToRemove: [ProcessingJob] = []
            
            for job in interruptedJobs {
                if !seenRecordings.contains(job.recordingPath) {
                    seenRecordings.insert(job.recordingPath)
                    jobsToResume.append(job)
                } else {
                    // This is a duplicate job for the same recording
                    jobsToRemove.append(job)
                    print("🗑️ Removing duplicate interrupted job: \(job.type.displayName) for \(job.recordingName)")
                }
            }
            
            // Remove duplicate jobs
            for job in jobsToRemove {
                if let index = activeJobs.firstIndex(where: { $0.id == job.id }) {
                    activeJobs.remove(at: index)
                }
                
                // Remove from Core Data
                if let jobEntry = coreDataManager.getProcessingJob(id: job.id) {
                    coreDataManager.deleteProcessingJob(jobEntry)
                }
            }
            
            // Resume unique jobs
            for job in jobsToResume {
                // Reset job status to queued for retry
                let resumedJob = job.withStatus(.queued).withProgress(0.0)
                await updateJob(resumedJob)
                
                print("↻ Resumed job: \(job.type.displayName) for \(job.recordingName)")
            }
            
            if jobsToRemove.count > 0 {
                print("✅ Cleaned up \(jobsToRemove.count) duplicate interrupted jobs")
            }
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
        await endBackgroundTask()
    }
    
    private func checkForCompletedJobs() async {
        // Check for stale jobs that may have been abandoned
        await cleanupStaleJobs()
        
        // This would check with external services (like AWS) for job completion
        // For now, we mainly focus on cleaning up stale local jobs
        print("🔍 Checked for completed and stale background jobs")
    }
    
    // MARK: - Core Data Persistence
    
    private func loadJobsFromCoreData() {
        let jobEntries = coreDataManager.getAllProcessingJobs()
        activeJobs = jobEntries.compactMap { convertToProcessingJob(from: $0) }
        
        // Clean up stale jobs on startup
        Task {
            await cleanupStaleJobs()
        }
    }
    
    private func convertToProcessingJob(from jobEntry: ProcessingJobEntry) -> ProcessingJob? {
        guard let id = jobEntry.id,
              let recordingPath = jobEntry.recordingURL, // Now stored as relative path
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
            type = .summarization(engine: jobEntry.engine ?? "Apple Intelligence")
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
            recordingPath: recordingPath,
            recordingName: recordingName,
            status: processingStatus,
            progress: jobEntry.progress,
            startTime: jobEntry.startTime ?? Date(),
            completionTime: jobEntry.completionTime,
            chunks: nil,
            error: jobEntry.error
        )
    }
    
    // MARK: - Keep Alive Audio
    
    private func startKeepAliveAudio() {
        guard keepAlivePlayer == nil else { return }
        
        print("🔈 Starting keep-alive silent audio")
        do {
            // Create a temporary silent WAV file
            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent("keep_alive_silence.wav")
            
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                // Create a 1-second silent buffer: 44.1kHz, 16-bit, mono
                let sampleRate = 44100.0
                let duration = 1.0
                let frameCount = Int(sampleRate * duration)
                
                guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
                    print("❌ Failed to create audio buffer for keep-alive")
                    return
                }
                
                buffer.frameLength = AVAudioFrameCount(frameCount)
                // Buffer is initialized with zeros (silence) by default
                
                let audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
                try audioFile.write(from: buffer)
            }
            
            // Configure player
            keepAlivePlayer = try AVAudioPlayer(contentsOf: fileURL)
            keepAlivePlayer?.numberOfLoops = -1 // Infinite loop
            keepAlivePlayer?.volume = 0.0 // Silence
            keepAlivePlayer?.prepareToPlay()
            
            // Ensure audio session is active before playing
            // (Handled by configureBackgroundRecording, but safe to verify/retry if needed? No, rely on existing flow)
            
            if keepAlivePlayer?.play() == true {
                print("✅ Keep-alive audio started")
            } else {
                print("⚠️ Keep-alive audio failed to start playing")
            }
        } catch {
            print("❌ Failed to start keep-alive audio: \(error)")
        }
    }
    
    private func stopKeepAliveAudio() {
        if keepAlivePlayer != nil {
            print("🔇 Stopping keep-alive silent audio")
            keepAlivePlayer?.stop()
            keepAlivePlayer = nil
        }
    }

    // MARK: - Background Task Management
    
    private func beginBackgroundTask() async {
        // Don't start a new background task if one is already running
        guard backgroundTaskID == .invalid else {
            print("⚠️ Background task already running: \(backgroundTaskID.rawValue)")
            return
        }
        
        // Configure audio session for background processing to get extended time
        // This is CRITICAL for getting more than 30 seconds of background time
        do {
            try await audioSessionManager.configureBackgroundRecording()
            
            // Wait a moment for the audio session to be fully configured
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            print("✅ Audio session configured for background processing")
            
            // Verify we actually got extended background time
            let backgroundTime = UIApplication.shared.backgroundTimeRemaining
            if backgroundTime != Double.greatestFiniteMagnitude {
                print("🕐 After audio session config: \(Int(backgroundTime))s background time")
            } else {
                print("🕐 After audio session config: Unlimited background time")
            }
        } catch {
            print("❌ CRITICAL: Could not configure background audio session: \(error)")
            print("   - This will severely limit background processing time")
            // Continue anyway, we'll still get some background time
        }
        
        // Create descriptive task name based on current job
        let taskName = if let currentJob = currentJob {
            "AudioProcessing-\(currentJob.type.displayName.replacingOccurrences(of: " ", with: ""))-\(currentJob.recordingName.prefix(20))"
        } else {
            "AudioProcessing-JobQueue"
        }
        
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: taskName) { [weak self] in
            print("⚠️ Background task is about to expire: \(taskName)")
            Task { @MainActor in
                await self?.handleBackgroundTaskExpiration()
            }
        }
        
        if backgroundTaskID == .invalid {
            print("❌ Failed to start background task")
            print("   - This usually means:")
            print("   - 1. App doesn't have proper background modes configured")
            print("   - 2. Device is low on resources")
            print("   - 3. Background App Refresh is disabled")
            backgroundTaskStartTime = nil
        } else {
            // Record when this background task started
            backgroundTaskStartTime = Date()
            print("🔄 Started background task: \(backgroundTaskID.rawValue)")

            // Check remaining background time immediately
            let remainingTime = UIApplication.shared.backgroundTimeRemaining
            if remainingTime == Double.greatestFiniteMagnitude {
                print("🕐 Background time: Unlimited (likely in foreground or audio session active)")
            } else {
                print("🕐 Background time remaining: \(Int(remainingTime))s")

                // Diagnose potential issues
                if remainingTime < 30 {
                    print("❌ CRITICAL: Very limited background time! Background task may fail immediately")
                    print("   - Background App Refresh may be disabled")
                    print("   - Device may be in Low Power Mode")
                    print("   - App may have been backgrounded too long")
                } else if remainingTime < 300 {
                    print("⚠️ WARNING: Limited background time (\(Int(remainingTime))s)")
                    print("   - Standard iOS background limit (30s) may be in effect")
                    print("   - Audio session may not be properly configured")
                }
            }

            // Start monitoring background time for long operations
            startBackgroundTimeMonitoring()
            
            // Start keep-alive audio to prevent app suspension during long tasks (like On-Device LLM)
            startKeepAliveAudio()
        }
    }
    
    
    private func endBackgroundTask() async {
        // Stop keep-alive audio
        stopKeepAliveAudio()
        
        // Cancel background time monitor first
        backgroundTimeMonitor?.cancel()
        backgroundTimeMonitor = nil

        if backgroundTaskID != .invalid {
            print("⏹️ Ending background task: \(backgroundTaskID.rawValue)")
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
            backgroundTaskStartTime = nil
            
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
        print("⚠️ Background task is expiring, attempting graceful shutdown")
        
        // If there's an active job, try to save partial progress first
        if let job = currentJob {
            print("💾 Saving progress for interrupted job: \(job.recordingName)")
            
            // Mark as interrupted but save any partial progress
            let interruptedJob = job.withStatus(.failed("Processing was interrupted when app went to background. The job has been queued and will resume when the app is active."))
            await updateJob(interruptedJob)
            
            // Send notification about interruption and queuing for retry
            await sendNotification(
                title: "Processing Paused",
                body: "\(job.recordingName) processing was paused. Open the app to continue."
            )
        }
        
        currentJob = nil
        processingStatus = .queued
        await endBackgroundTask()
        
        print("✅ Background task gracefully shut down")
    }
    
    private func monitorBackgroundTime() {
        guard backgroundTaskID != .invalid else { return }

        // Check if background task has been running too long (>25 seconds)
        // iOS warns if tasks are open for >30 seconds, so we refresh at 25s
        if let startTime = backgroundTaskStartTime {
            let taskAge = Date().timeIntervalSince(startTime)
            if taskAge > 25 {
                print("🔄 Background task age: \(Int(taskAge))s - refreshing to avoid iOS warning")
                Task { @MainActor in
                    await self.refreshBackgroundTask()
                }
                return
            }
        }

        let remainingTime = UIApplication.shared.backgroundTimeRemaining

        // Skip monitoring if we have unlimited time (app is likely in foreground or has special privileges)
        guard remainingTime != Double.greatestFiniteMagnitude else { return }

        // For long-running audio processing, manage time intelligently
        if remainingTime < 600 { // Less than 10 minutes
            print("⚠️ Background time running low (\(Int(remainingTime))s remaining)")

            // Notify current job about time constraints
            if let job = currentJob {
                print("📊 Current job: \(job.type.displayName) for \(job.recordingName) - Progress: \(Int(job.progress * 100))%")
            }
        }

        // Try to complete processing gracefully when very low on time
        if remainingTime < 120 { // Less than 2 minutes
            print("⚠️ Background time critically low (\(Int(remainingTime))s), will attempt graceful shutdown soon")
            // Allow the current processing chunk to complete if possible
        }

        // Force shutdown when almost expired to prevent sudden termination
        if remainingTime < 30 {
            print("⚠️ Background time almost expired (\(Int(remainingTime))s), initiating graceful shutdown")
            Task { @MainActor in
                await self.handleBackgroundTaskExpiration()
            }
        }
    }

    /// Refresh the background task to avoid iOS warnings about long-running tasks
    /// This ends the current task and immediately starts a new one
    private func refreshBackgroundTask() async {
        guard backgroundTaskID != .invalid else { return }

        print("♻️ Refreshing background task to avoid iOS 30-second warning")

        // Get the current task name before ending
        let hasActiveJob = currentJob != nil

        // End the current background task
        let oldTaskID = backgroundTaskID
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        backgroundTaskStartTime = nil
        print("   Ended old task: \(oldTaskID.rawValue)")

        // Immediately start a new one if we still have an active job
        if hasActiveJob {
            // Don't cancel the monitor, we'll keep using it
            await beginBackgroundTask()
        }
    }
    
    // MARK: - Notifications
    
    private func setupNotifications() {
        // Set up notification center but don't request permission yet
        // Permission will be requested when we actually implement user notifications
        print("📱 Notification center configured (permission request deferred)")
    }
    
    func sendNotification(title: String, body: String, identifier: String? = nil, userInfo: [String: Any] = [:]) async {
        // Check if we have notification permission first
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        
        // Request permission if not yet determined
        if settings.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                if granted {
                    print("✅ Notification permission granted")
                } else {
                    print("❌ Notification permission denied by user")
                    return
                }
            } catch {
                print("❌ Error requesting notification permission: \(error)")
                return
            }
        } else if settings.authorizationStatus != .authorized {
            print("📱 Notification not sent - permission denied or restricted")
            return
        }
        
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
    
    // MARK: - Stale Job Cleanup
    
    /// Cleans up jobs that have been stuck in processing state for too long
    func cleanupStaleJobs() async {
        let staleThreshold: TimeInterval = 3600 // 1 hour
        let now = Date()
        var cleanedCount = 0
        
        for job in activeJobs {
            let timeSinceStart = now.timeIntervalSince(job.startTime)
            
            // Check if job is stuck in processing state for too long
            if job.status == .processing && timeSinceStart > staleThreshold {
                // Cleanup stale job silently
                
                let failedJob = job.withStatus(.failed("Job timed out after \(Int(timeSinceStart/60)) minutes"))
                await updateJobInMemoryAndCoreData(failedJob)
                cleanedCount += 1
            }
        }
        
        if cleanedCount > 0 {
            // Update UI on main thread
            await MainActor.run {
                self.objectWillChange.send()
            }
        }
    }
    
    /// Updates job both in memory and Core Data
    private func updateJobInMemoryAndCoreData(_ updatedJob: ProcessingJob) async {
        // Update in memory
        if let index = activeJobs.firstIndex(where: { $0.id == updatedJob.id }) {
            activeJobs[index] = updatedJob
        }
        
        // Update in Core Data
        if let jobEntry = coreDataManager.getProcessingJob(id: updatedJob.id) {
            jobEntry.status = statusToString(updatedJob.status)
            jobEntry.error = updatedJob.error
            jobEntry.completionTime = updatedJob.completionTime
            jobEntry.progress = updatedJob.progress
            
            do {
                try coreDataManager.saveContext()
            } catch {
                print("❌ Failed to update job in Core Data: \(error)")
            }
        }
    }
    
    /// Convert JobProcessingStatus to string for Core Data storage
    private func statusToString(_ status: JobProcessingStatus) -> String {
        switch status {
        case .queued:
            return "queued"
        case .processing:
            return "processing"
        case .completed:
            return "completed"
        case .failed(let message):
            return "failed:\(message)"
        }
    }
    
    // MARK: - Manual Cleanup Functions
    
    /// Manually cleanup all failed and completed jobs
    func cleanupCompletedJobs() async {
        let jobsToRemove = activeJobs.filter { job in
            job.status == .completed || job.status.isError
        }
        
        for job in jobsToRemove {
            // Remove from Core Data
            if let jobEntry = coreDataManager.getProcessingJob(id: job.id) {
                coreDataManager.deleteProcessingJob(jobEntry)
            }
        }
        
        // Remove from memory
        activeJobs.removeAll { job in
            job.status == .completed || job.status.isError
        }
        
        print("🧹 Cleaned up \(jobsToRemove.count) completed/failed jobs")
        
        // Update UI
        await MainActor.run {
            self.objectWillChange.send()
        }
    }
    
    /// Cancel all processing jobs and mark them as failed
    func cancelAllJobs() async {
        let processingJobs = activeJobs.filter { $0.status == .processing || $0.status == .queued }
        
        for job in processingJobs {
            let cancelledJob = job.withStatus(.failed("Cancelled by user"))
            await updateJobInMemoryAndCoreData(cancelledJob)
        }
        
        // Clear current job
        currentJob = nil
        
        if !processingJobs.isEmpty {
            print("🛑 Cancelled \(processingJobs.count) jobs")
            
            // Update UI
            await MainActor.run {
                self.objectWillChange.send()
            }
        }
    }
    
    /// Force cleanup all jobs (nuclear option)
    func clearAllJobs() async {
        // Remove all jobs from Core Data
        let allJobEntries = coreDataManager.getAllProcessingJobs()
        for jobEntry in allJobEntries {
            coreDataManager.deleteProcessingJob(jobEntry)
        }
        
        // Clear from memory
        activeJobs.removeAll()
        currentJob = nil
        
        print("🧹 Cleared all background processing jobs")
        
        // Update UI
        await MainActor.run {
            self.objectWillChange.send()
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
