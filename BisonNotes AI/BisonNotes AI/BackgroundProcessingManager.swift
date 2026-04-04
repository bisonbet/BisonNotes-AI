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
    let modelName: String?
    /// Optional alternative audio file to transcribe from (e.g. cleaned audio).
    /// When set, transcription reads from this file instead of `recordingPath`,
    /// but the recording identity and Core Data associations use `recordingPath`.
    /// The file is automatically deleted when the job completes or fails.
    let sourceAudioPath: String?
    let status: JobProcessingStatus
    let progress: Double
    let startTime: Date
    /// When the job actually began processing (transitioned from queued to processing).
    /// Not persisted — only valid for the current app session.
    let processingStartTime: Date?
    let completionTime: Date?
    let chunks: [AudioChunk]?
    let error: String?

    // Exclude processingStartTime from Codable to avoid forward-compatibility issues
    private enum CodingKeys: String, CodingKey {
        case id, type, recordingPath, recordingName, modelName, sourceAudioPath, status, progress,
             startTime, completionTime, chunks, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(JobType.self, forKey: .type)
        recordingPath = try container.decode(String.self, forKey: .recordingPath)
        recordingName = try container.decode(String.self, forKey: .recordingName)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        sourceAudioPath = try container.decodeIfPresent(String.self, forKey: .sourceAudioPath)
        status = try container.decode(JobProcessingStatus.self, forKey: .status)
        progress = try container.decode(Double.self, forKey: .progress)
        startTime = try container.decode(Date.self, forKey: .startTime)
        processingStartTime = nil
        completionTime = try container.decodeIfPresent(Date.self, forKey: .completionTime)
        chunks = try container.decodeIfPresent([AudioChunk].self, forKey: .chunks)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    // Computed property to get absolute URL when needed
    var recordingURL: URL {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // Fallback to a temporary URL if documents directory is not available
            return URL(fileURLWithPath: "/tmp/\(recordingPath)")
        }
        return documentsURL.appendingPathComponent(recordingPath)
    }

    /// The URL to actually read audio from. Uses `sourceAudioPath` (cleaned audio) if set,
    /// otherwise falls back to `recordingURL`.
    var audioSourceURL: URL {
        guard let sourcePath = sourceAudioPath else { return recordingURL }
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: "/tmp/\(sourcePath)")
        }
        return documentsURL.appendingPathComponent(sourcePath)
    }

    init(type: JobType, recordingURL: URL, recordingName: String, modelName: String? = nil, sourceAudioURL: URL? = nil, chunks: [AudioChunk]? = nil) {
        self.id = UUID()
        self.type = type
        // Store only the filename as relative path
        self.recordingPath = recordingURL.lastPathComponent
        self.recordingName = recordingName
        self.modelName = modelName
        self.sourceAudioPath = sourceAudioURL?.lastPathComponent
        self.status = .queued
        self.progress = 0.0
        self.startTime = Date()
        self.processingStartTime = nil
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
            modelName: self.modelName,
            sourceAudioPath: self.sourceAudioPath,
            status: status,
            progress: self.progress,
            startTime: self.startTime,
            processingStartTime: status == .processing ? Date() : nil,
            completionTime: status == .completed || status.isCancelled || status.isError ? Date() : self.completionTime,
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
            modelName: self.modelName,
            sourceAudioPath: self.sourceAudioPath,
            status: self.status,
            progress: progress,
            startTime: self.startTime,
            processingStartTime: self.processingStartTime,
            completionTime: self.completionTime,
            chunks: self.chunks,
            error: self.error
        )
    }

    init(id: UUID, type: JobType, recordingPath: String, recordingName: String, modelName: String? = nil, sourceAudioPath: String? = nil, status: JobProcessingStatus, progress: Double, startTime: Date, processingStartTime: Date? = nil, completionTime: Date?, chunks: [AudioChunk]?, error: String?) {
        self.id = id
        self.type = type
        self.recordingPath = recordingPath
        self.recordingName = recordingName
        self.modelName = modelName
        self.sourceAudioPath = sourceAudioPath
        self.status = status
        self.progress = progress
        self.startTime = startTime
        self.processingStartTime = processingStartTime
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
    
    var isTranscription: Bool {
        if case .transcription = self { return true }
        return false
    }

    var isSummarization: Bool {
        if case .summarization = self { return true }
        return false
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
    case ready
    case queued
    case processing
    case completed
    case failed(String)
    case cancelled
    case interrupted(String)

    var isError: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    var isCancelled: Bool {
        if case .cancelled = self {
            return true
        }
        return false
    }

    var isInterrupted: Bool {
        if case .interrupted = self {
            return true
        }
        return false
    }

    var isResumable: Bool {
        if case .interrupted = self {
            return true
        }
        return false
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    var errorMessage: String? {
        switch self {
        case .failed(let message):
            return message
        case .interrupted(let reason):
            return reason
        default:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .ready:
            return "Ready"
        case .queued:
            return "Queued"
        case .processing:
            return "Processing"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .interrupted:
            return "Interrupted"
        }
    }
}

// MARK: - Background Processing Manager

@MainActor
class BackgroundProcessingManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var activeJobs: [ProcessingJob] = []
    @Published var processingStatus: JobProcessingStatus = .ready
    @Published var currentJob: ProcessingJob?
    
    // MARK: - Completion Handlers
    
    var onTranscriptionCompleted: ((TranscriptData, ProcessingJob) -> Void)?
    
    // MARK: - Private Properties

    private var currentTaskHandle: Task<Void, Never>?
    private var externalTaskHandles: [UUID: Task<Void, Never>] = [:]
    /// Reason for the current cancellation — nil means user-initiated cancel
    private var cancellationReason: String?
    /// Maps job ID → old summary ID for regeneration jobs (delete old summary before saving new)
    private var regenerationSummaryIds: [UUID: UUID] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskStartTime: Date?
    private var backgroundTimeMonitor: Task<Void, Never>?
    private var staleJobMonitor: Task<Void, Never>?
    private var isCleaningUpStaleJobs = false
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
        startStaleJobMonitoring()
        
        // Resume interrupted jobs and start processing queued jobs on initialization
        Task {
            await resumeInterruptedJobs()
            if !activeJobs.filter({ $0.status == .queued }).isEmpty {
                await processNextJob()
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        staleJobMonitor?.cancel() // Defensive: class is a singleton so deinit rarely fires
    }
    
    // MARK: - Performance Optimization Setup
    
    /// Starts a periodic monitor that reconciles stale/orphaned processing jobs every 60s.
    /// The initial 60s sleep is intentional — `init` already handles the first pass via `resumeInterruptedJobs()`.
    private func startStaleJobMonitoring() {
        staleJobMonitor?.cancel()
        staleJobMonitor = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                if !Task.isCancelled {
                    await cleanupStaleJobs()
                }
            }
        }
    }

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

        // Start periodic monitoring every 10 seconds to catch tasks that need refreshing
        // We refresh at 25s, so checking every 10s ensures we catch them before the 30s iOS warning
        backgroundTimeMonitor = Task {
            while !Task.isCancelled && backgroundTaskID != .invalid {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds

                if !Task.isCancelled {
                    monitorBackgroundTime()
                }
            }
        }
    }
    
    // MARK: - Job Management
    
    func startTranscriptionJob(recordingURL: URL, recordingName: String, engine: TranscriptionEngine, modelName: String? = nil, sourceAudioURL: URL? = nil, chunks: [AudioChunk]? = nil) async throws {
        // Queue size limit
        let queuedCount = activeJobs.filter { $0.status == .queued }.count
        guard queuedCount < 20 else {
            throw BackgroundProcessingError.queueFull
        }

        // Ensure recording exists in Core Data (always use the original recording URL)
        await ensureRecordingExists(recordingURL: recordingURL, recordingName: recordingName)

        let job = ProcessingJob(
            type: .transcription(engine: engine),
            recordingURL: recordingURL,
            recordingName: recordingName,
            modelName: modelName,
            sourceAudioURL: sourceAudioURL,
            chunks: chunks
        )

        // For transcription jobs, check if we need to replace an existing job
        await addTranscriptionJob(job)
        await processNextJob()
    }

    @discardableResult
    func startSummarizationJob(recordingURL: URL, recordingName: String, engine: String, modelName: String? = nil, replacingSummaryId: UUID? = nil) async throws -> UUID {
        // Queue size limit
        let queuedCount = activeJobs.filter { $0.status == .queued }.count
        guard queuedCount < 20 else {
            throw BackgroundProcessingError.queueFull
        }

        let job = ProcessingJob(
            type: .summarization(engine: engine),
            recordingURL: recordingURL,
            recordingName: recordingName,
            modelName: modelName
        )

        // Track old summary ID for regeneration (delete before saving new)
        if let oldSummaryId = replacingSummaryId {
            regenerationSummaryIds[job.id] = oldSummaryId
        }

        // Remove old terminal summarization jobs for this recording to prevent stale matches
        activeJobs.removeAll { existingJob in
            if case .summarization = existingJob.type,
               existingJob.recordingPath == job.recordingPath,
               existingJob.status.isTerminal {
                return true
            }
            return false
        }

        await addJob(job)
        await processNextJob()
        return job.id
    }
    
    func cancelActiveJob() async {
        guard currentJob != nil else { return }

        // Cancel the running task — the Task's catch block will handle
        // status update, cleanup, and processing the next queued job
        currentTaskHandle?.cancel()
    }

    func cancelQueuedJob(id: UUID) async {
        guard let index = activeJobs.firstIndex(where: { $0.id == id && $0.status == .queued }) else { return }
        let cancelledJob = activeJobs[index].withStatus(.cancelled)
        await updateJob(cancelledJob)
    }

    func cancelJob(id: UUID) async {
        if let job = currentJob, job.id == id {
            await cancelActiveJob()
        } else if let task = externalTaskHandles[id] {
            task.cancel()
            externalTaskHandles.removeValue(forKey: id)
            if let index = activeJobs.firstIndex(where: { $0.id == id }) {
                let cancelledJob = activeJobs[index].withStatus(.cancelled)
                await updateJob(cancelledJob)
            }
        } else {
            await cancelQueuedJob(id: id)
        }
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
            job.status.isTerminal
        }
    }

    // MARK: - External Job Tracking

    func trackExternalJob(_ job: ProcessingJob) async {
        print("📊 trackExternalJob called: \(job.recordingName) (\(job.type.displayName)) - activeJobs count before: \(activeJobs.count)")
        await addJob(job)
        print("📊 trackExternalJob done: activeJobs count after: \(activeJobs.count)")
        objectWillChange.send()
    }

    func trackExternalTask(_ jobId: UUID, task: Task<Void, Never>) {
        externalTaskHandles[jobId] = task
    }

    func updateExternalJob(_ job: ProcessingJob) async {
        print("📊 updateExternalJob: \(job.recordingName) status=\(job.status.displayName) - activeJobs count: \(activeJobs.count)")
        await updateJob(job)
        // Clean up task handle if job is terminal
        if job.status.isTerminal {
            externalTaskHandles.removeValue(forKey: job.id)
        }
        objectWillChange.send()
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
            print("⚠️ Job already exists for \(job.recordingName) (\(job.type.displayName)). Skipping duplicate. Existing: \(existingJobs.map { "\($0.id) status=\($0.status.displayName)" })")
            return
        }
        print("📊 addJob: No duplicate found, adding \(job.recordingName) (\(job.type.displayName)) id=\(job.id)")

        // Create Core Data entry
        let jobEntry = coreDataManager.createProcessingJob(
            id: job.id,
            jobType: job.type.displayName,
            engine: getEngineString(from: job.type),
            recordingURL: job.recordingURL,
            recordingName: job.recordingName,
            modelName: job.modelName
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
            existingJob.type.isTranscription
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
            recordingName: job.recordingName,
            modelName: job.modelName
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

                if updatedJob.status.isTerminal {
                    jobEntry.completionTime = Date()
                }

                if let errorMsg = updatedJob.status.errorMessage {
                    jobEntry.error = errorMsg
                }

                coreDataManager.updateProcessingJob(jobEntry)
            }
        }
    }
    
    func processNextJob() async {
        // Don't start a new job if one is already running
        guard currentJob == nil else { return }

        // Find the next queued job
        guard let nextJob = activeJobs.first(where: { $0.status == .queued }) else {
            processingStatus = .ready
            await endBackgroundTask()
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
        if let model = nextJob.modelName {
            print("   - Model: \(model)")
        }
        print("   - Recording URL: \(nextJob.recordingURL)")
        print("   - Audio source: \(nextJob.audioSourceURL)")
        print("   - File exists: \(FileManager.default.fileExists(atPath: nextJob.audioSourceURL.path))")

        // Store the task handle so it can be cancelled
        currentTaskHandle = Task {
            do {
                try Task.checkCancellation()

                // Apply battery-aware processing settings
                await applyBatteryOptimization(for: processingJob)

                try Task.checkCancellation()

                switch nextJob.type {
                case .transcription(let engine):
                    print("📝 Processing transcription job with \(engine.rawValue)")
                    try await processTranscriptionJob(processingJob, engine: engine)
                case .summarization(let engine):
                    print("📋 Processing summarization job with \(engine)")
                    try await processSummarizationJob(processingJob, engine: engine)
                }

                try Task.checkCancellation()

                // Job completed successfully
                let completedJob = processingJob.withStatus(.completed).withProgress(1.0)
                await updateJob(completedJob)

                print("✅ Job completed: \(nextJob.type.displayName) for \(nextJob.recordingName)")

                // Post-processing cleanup
                await performCleanupTasks(for: processingJob)
                await updateFileMetadata(for: processingJob)

            } catch is CancellationError {
                // If the job was already moved to a terminal state (e.g., timed out by the
                // stale job monitor), don't overwrite it — just clear the cancellation reason.
                let currentStatus = activeJobs.first(where: { $0.id == nextJob.id })?.status
                if let currentStatus, currentStatus.isTerminal {
                    print("⏭️ Job already terminal (\(currentStatus.displayName)): \(nextJob.type.displayName) for \(nextJob.recordingName)")
                    cancellationReason = nil
                } else if let reason = cancellationReason {
                    let interruptedJob = processingJob.withStatus(.interrupted(reason))
                    await updateJob(interruptedJob)
                    print("⏸️ Job interrupted (\(reason)): \(nextJob.type.displayName) for \(nextJob.recordingName)")

                    // Send detailed notification for interruptions
                    let jobTypeDesc = switch nextJob.type {
                    case .transcription: "Transcription"
                    case .summarization: "Summarization"
                    }
                    let modelInfo = nextJob.modelName.map { " (\($0))" } ?? ""
                    await sendNotification(
                        title: "\(jobTypeDesc) Paused",
                        body: "\(nextJob.recordingName) — \(nextJob.type.engineName)\(modelInfo). Open the app to resume."
                    )
                    cancellationReason = nil
                } else {
                    let cancelledJob = processingJob.withStatus(.cancelled)
                    await updateJob(cancelledJob)
                    print("🛑 Job cancelled: \(nextJob.type.displayName) for \(nextJob.recordingName)")
                }

            } catch {
                // Clear any stale cancellation reason so it doesn't leak to the next job.
                cancellationReason = nil

                // If the job was already moved to a terminal state (e.g., timed out by the
                // stale job monitor), don't overwrite it or attempt recovery.
                let currentStatus = activeJobs.first(where: { $0.id == nextJob.id })?.status
                if let currentStatus, currentStatus.isTerminal {
                    print("⏭️ Job already terminal (\(currentStatus.displayName)): \(nextJob.type.displayName) for \(nextJob.recordingName) (error was: \(error.localizedDescription))")
                } else {
                    let failedJob = processingJob.withStatus(.failed(error.localizedDescription))
                    await updateJob(failedJob)

                    print("❌ Job failed: \(nextJob.type.displayName) for \(nextJob.recordingName)")
                    print("   - Error: \(error)")
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
            }

            // Clean up source audio file on any terminal state (failure, cancellation, etc.)
            // Success cleanup is handled in performCleanupTasks, but we also need to clean up
            // on failure/cancellation so cleaned audio files don't leak.
            if let sourcePath = nextJob.sourceAudioPath, sourcePath.hasPrefix("cleaned_") {
                let sourceURL = nextJob.audioSourceURL
                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    try? FileManager.default.removeItem(at: sourceURL)
                    print("🗑️ Cleaned up source audio file after job ended: \(sourcePath)")
                }
            }

            // Clear current job and task handle
            regenerationSummaryIds.removeValue(forKey: nextJob.id)
            currentJob = nil
            currentTaskHandle = nil

            // Check if there are more queued jobs before ending background task
            let hasMoreJobs = activeJobs.contains(where: { $0.status == .queued })
            if hasMoreJobs {
                // Refresh the background task timer between jobs instead of end+restart
                // This avoids audio session teardown/setup overhead
                await refreshBackgroundTask()
            } else {
                await endBackgroundTask()
            }

            // Process next queued job
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

        try Task.checkCancellation()

        // Use the source audio URL (cleaned file) if available, otherwise the recording URL
        let audioURL = job.audioSourceURL
        if job.sourceAudioPath != nil {
            print("🎛️ Using cleaned audio source: \(job.sourceAudioPath!) (recording identity: \(job.recordingPath))")
        }

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
            let needsChunking = try await chunkingService.shouldChunkFile(audioURL, for: engine)

            if needsChunking {
                EnhancedLogger.shared.logBackgroundProcessing("File needs chunking for \(engine.rawValue)", level: .info)
                let chunkingResult = try await chunkingService.chunkAudioFile(audioURL, for: engine)
                chunks = chunkingResult.chunks
            } else {
                // Create a single "chunk" for the whole file
                let fileInfo = try await chunkingService.getAudioFileInfo(audioURL)
                chunks = [AudioChunk(
                    originalURL: audioURL,
                    chunkURL: audioURL,
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
            try Task.checkCancellation()
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

            case .fluidAudio:
                print("🤖 Using FluidAudio (Parakeet) for transcription")
                let fluidAudioManager = FluidAudioManager.shared
                guard fluidAudioManager.isAvailableInCurrentBuild else {
                    throw BackgroundProcessingError.processingFailed("FluidAudio SDK is not available in this build.")
                }
                guard fluidAudioManager.isModelReady else {
                    throw BackgroundProcessingError.processingFailed("On-device model not downloaded. Please download the Parakeet model in Settings > Transcription > On Device.")
                }
                result = try await fluidAudioManager.transcribe(audioURL: chunk.chunkURL)

            case .mistralAI:
                print("🤖 Using Mistral AI for transcription")
                let config = getMistralTranscribeConfig()
                let service = MistralTranscribeService(config: config, chunkingService: chunkingService)
                let mistralResult = try await service.transcribeAudioFile(at: chunk.chunkURL, recordingId: recordingId)
                result = TranscriptionResult(
                    fullText: mistralResult.transcriptText,
                    segments: mistralResult.segments,
                    processingTime: mistralResult.processingTime,
                    chunkCount: 1,
                    success: mistralResult.success,
                    error: mistralResult.error
                )

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
            
        } catch is CancellationError {
            print("🛑 Transcription cancelled for \(engine.rawValue)")
            throw CancellationError()
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
    
    private func getMistralTranscribeConfig() -> MistralTranscribeConfig {
        let apiKey = UserDefaults.standard.string(forKey: "mistralAPIKey") ?? ""
        let modelString = UserDefaults.standard.string(forKey: "mistralTranscribeModel") ?? MistralTranscribeModel.voxtralMiniLatest.rawValue
        let baseURL = UserDefaults.standard.string(forKey: "mistralBaseURL") ?? "https://api.mistral.ai/v1"
        let diarize = UserDefaults.standard.bool(forKey: "mistralTranscribeDiarize")
        let language = UserDefaults.standard.string(forKey: "mistralTranscribeLanguage") ?? ""

        let model = MistralTranscribeModel(rawValue: modelString) ?? .voxtralMiniLatest

        return MistralTranscribeConfig(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            diarize: diarize,
            language: language.isEmpty ? nil : language
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

        try Task.checkCancellation()

        // Update progress
        let progressJob = job.withProgress(0.1)
        await updateJob(progressJob)

        // Look up the recording in Core Data to get IDs
        let recording = coreDataManager.getRecording(url: job.recordingURL)
        guard let recordingId = recording?.id else {
            throw BackgroundProcessingError.processingFailed("Recording not found in Core Data for \(job.recordingName)")
        }

        // Get transcript data
        guard let transcriptEntry = recording?.transcript,
              let transcriptId = transcriptEntry.id else {
            throw BackgroundProcessingError.processingFailed("No transcript found for \(job.recordingName). Transcribe the recording first.")
        }

        // Parse transcript to get text for summarization
        let transcriptText: String
        if let segmentsJSON = transcriptEntry.segments,
           let segmentsData = segmentsJSON.data(using: .utf8),
           let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData) {
            // Parse speaker mappings if available
            var speakerMappings: [String: String] = [:]
            if let mappingsJSON = transcriptEntry.speakerMappings,
               let mappingsData = mappingsJSON.data(using: .utf8) {
                speakerMappings = (try? JSONDecoder().decode([String: String].self, from: mappingsData)) ?? [:]
            }
            // Build TranscriptData to use textForSummarization (includes speaker labels)
            let transcriptData = TranscriptData(
                recordingURL: job.recordingURL,
                recordingName: job.recordingName,
                recordingDate: recording?.recordingDate ?? Date(),
                segments: segments,
                speakerMappings: speakerMappings
            )
            transcriptText = transcriptData.textForSummarization
        } else {
            throw BackgroundProcessingError.processingFailed("Could not read transcript text for \(job.recordingName)")
        }

        guard !transcriptText.isEmpty else {
            throw BackgroundProcessingError.processingFailed("Transcript is empty for \(job.recordingName)")
        }

        print("📝 Found transcript with \(transcriptText.count) characters")

        // Update progress after getting transcript
        let transcriptProgressJob = job.withProgress(0.3)
        await updateJob(transcriptProgressJob)

        try Task.checkCancellation()

        // Generate summary using SummaryManager (same path as SummariesView)
        let recordingDate = recording?.recordingDate ?? Date()
        let enhancedSummary: EnhancedSummaryData
        do {
            enhancedSummary = try await SummaryManager.shared.generateEnhancedSummary(
                from: transcriptText,
                for: job.recordingURL,
                recordingName: job.recordingName,
                recordingDate: recordingDate,
                engineName: engine
            )
        } catch {
            // If the task was cancelled but the error got wrapped, re-throw as CancellationError
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }

        try Task.checkCancellation()

        // Update progress after summarization
        let summaryProgressJob = job.withProgress(0.8)
        await updateJob(summaryProgressJob)

        // Clear regeneration tracking (cleanup now happens in RecordingWorkflowManager.createSummary)
        regenerationSummaryIds.removeValue(forKey: job.id)

        // Save summary to Core Data using RecordingWorkflowManager
        let workflowManager = RecordingWorkflowManager()
        let summaryId = workflowManager.createSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: enhancedSummary.summary,
            tasks: enhancedSummary.tasks,
            reminders: enhancedSummary.reminders,
            titles: enhancedSummary.titles,
            contentType: enhancedSummary.contentType,
            aiEngine: enhancedSummary.aiEngine,
            aiModel: enhancedSummary.aiModel,
            originalLength: enhancedSummary.originalLength,
            processingTime: enhancedSummary.processingTime
        )

        guard summaryId != nil else {
            throw BackgroundProcessingError.processingFailed("Failed to save summary for \(job.recordingName)")
        }

        print("💾 Summary saved with ID: \(summaryId?.uuidString ?? "nil")")

        // Update recording name if the AI generated a better one
        if enhancedSummary.recordingName != job.recordingName {
            print("📝 Updating recording name: '\(job.recordingName)' → '\(enhancedSummary.recordingName)'")
            try? coreDataManager.updateRecordingName(for: recordingId, newName: enhancedSummary.recordingName)
        }

        // Update progress to near-complete (processNextJob sets final .completed status)
        let nearCompleteJob = job.withProgress(0.95)
        await updateJob(nearCompleteJob)

        // Send completion notification
        let taskCount = enhancedSummary.tasks.count
        let reminderCount = enhancedSummary.reminders.count
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
            
        case "Local LLM (Ollama)", "ollama", "local":
            // TODO: Integrate with Ollama service when available
            summary = "Summary generated using local Ollama service (not yet implemented)"

        default:
            // Use the SummaryManager's currently selected engine
            let summaryManager = SummaryManager.shared
            let result = try await summaryManager.generateEnhancedSummary(
                from: transcriptText,
                for: recordingURL,
                recordingName: recordingName,
                recordingDate: Date()
            )
            summary = result.summary
            tasks = result.tasks
            reminders = result.reminders
            titles = result.titles
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
        } else if lowerEngine.contains("device") {
            engineType = "On-Device AI"
        } else if lowerEngine.contains("ollama") {
            engineType = "Ollama"
        } else if lowerEngine.contains("apple") {
            engineType = "Apple Native"
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
            // Use the currently selected engine for title generation
            let selectedEngineName = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "On-Device AI"
            let engineType = AIEngineType.allCases.first(where: { $0.rawValue == selectedEngineName }) ?? .onDeviceLLM
            let engine = AIEngineFactory.createEngine(type: engineType)
            let titles = try await engine.extractTitles(from: transcriptText)
            
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

        // Clean up source audio file (e.g. cleaned audio copy) now that the job is done
        if let sourcePath = job.sourceAudioPath, sourcePath.hasPrefix("cleaned_") {
            let sourceURL = job.audioSourceURL
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try? FileManager.default.removeItem(at: sourceURL)
                print("🗑️ Cleaned up source audio file: \(sourcePath)")
            }
        }

        // Clean up temporary chunk files
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

        // Send a detailed notification about ongoing processing
        if let job = currentJob {
            let jobTypeDesc = switch job.type {
            case .transcription: "Transcription"
            case .summarization: "Summarization"
            }
            let modelInfo = job.modelName.map { " (\($0))" } ?? ""
            let queuedCount = activeJobs.filter { $0.status == .queued }.count
            let queueInfo = queuedCount > 0 ? " + \(queuedCount) queued" : ""

            await sendNotification(
                title: "\(jobTypeDesc) in Background",
                body: "\(job.recordingName) — \(job.type.engineName)\(modelInfo)\(queueInfo)"
            )
        } else if !activeJobs.filter({ $0.status == .queued }).isEmpty {
            let queuedCount = activeJobs.filter { $0.status == .queued }.count
            await sendNotification(
                title: "Jobs Queued",
                body: "\(queuedCount) job\(queuedCount == 1 ? "" : "s") will continue when you return to the app."
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

        // Clear notification badge
        await clearNotificationBadge()

        // Check if any jobs completed while in background
        await checkForCompletedJobs()

        // Resume processing of any interrupted jobs (with engine availability checks)
        await resumeInterruptedJobs()

        // Post notification for other components to check for unprocessed recordings
        NotificationCenter.default.post(name: NSNotification.Name("CheckForUnprocessedRecordings"), object: nil)

        // Resume processing if needed (interrupted jobs that were re-queued + existing queued jobs)
        if currentJob == nil && !activeJobs.filter({ $0.status == .queued }).isEmpty {
            print("🚀 Resuming queued background processing jobs")
            await processNextJob()
        }
    }
    
    /// Resume jobs that were interrupted due to background limitations
    private func resumeInterruptedJobs(notify: Bool = true) async {
        // Find interrupted jobs (using the new .interrupted status)
        let interruptedJobs = activeJobs.filter { $0.status.isInterrupted }

        // Also find legacy interrupted jobs (from old .failed status messages)
        let legacyInterruptedJobs = activeJobs.filter { job in
            if case .failed(let message) = job.status {
                return message.contains("interrupted") || message.contains("App was terminated") || message.contains("App was closed")
            }
            return false
        }

        let allInterrupted = interruptedJobs + legacyInterruptedJobs

        guard !allInterrupted.isEmpty else { return }

        print("🔄 Found \(allInterrupted.count) interrupted jobs to resume")

        // Deduplicate by recording path
        var seenRecordings: Set<String> = []
        var jobsToResume: [ProcessingJob] = []
        var jobsToRemove: [ProcessingJob] = []

        for job in allInterrupted {
            if !seenRecordings.contains(job.recordingPath) {
                seenRecordings.insert(job.recordingPath)
                jobsToResume.append(job)
            } else {
                jobsToRemove.append(job)
                print("🗑️ Removing duplicate interrupted job: \(job.type.displayName) for \(job.recordingName)")
            }
        }

        // Remove duplicate jobs
        for job in jobsToRemove {
            if let index = activeJobs.firstIndex(where: { $0.id == job.id }) {
                activeJobs.remove(at: index)
            }
            if let jobEntry = coreDataManager.getProcessingJob(id: job.id) {
                coreDataManager.deleteProcessingJob(jobEntry)
            }
        }

        // Check engine availability and resume each job
        var resumedCount = 0
        var waitingCount = 0

        for job in jobsToResume {
            let availability = await checkEngineAvailability(for: job.type)

            if availability.available {
                let resumedJob = job.withStatus(.queued).withProgress(0.0)
                await updateJob(resumedJob)
                resumedCount += 1
                print("↻ Resumed job: \(job.type.displayName) for \(job.recordingName)")
            } else {
                // Keep as interrupted with updated reason
                let reason = availability.reason ?? "Engine unavailable"
                let waitingJob = job.withStatus(.interrupted(reason))
                await updateJob(waitingJob)
                waitingCount += 1
                print("⏸️ Job waiting: \(job.recordingName) — \(reason)")
            }
        }

        if notify && resumedCount > 0 {
            await sendNotification(
                title: "Jobs Resumed",
                body: "Resumed \(resumedCount) interrupted job\(resumedCount == 1 ? "" : "s")."
            )
        }
        if notify && waitingCount > 0 {
            await sendNotification(
                title: "Jobs Waiting",
                body: "\(waitingCount) job\(waitingCount == 1 ? "" : "s") waiting for engine availability."
            )
        }

        if jobsToRemove.count > 0 {
            print("✅ Cleaned up \(jobsToRemove.count) duplicate interrupted jobs")
        }
    }

    // MARK: - Engine Availability Checking

    private func checkEngineAvailability(for jobType: JobType) async -> (available: Bool, reason: String?) {
        switch jobType {
        case .transcription(let engine):
            return await checkTranscriptionEngineAvailability(engine)
        case .summarization(let engine):
            return await checkSummarizationEngineAvailability(engine)
        }
    }

    private func checkTranscriptionEngineAvailability(_ engine: TranscriptionEngine) async -> (available: Bool, reason: String?) {
        switch engine {
        case .fluidAudio:
            // On-device engine is always available
            return (true, nil)
        case .openAI, .openAIAPICompatible, .awsTranscribe, .mistralAI:
            // Cloud engines need network
            return await checkNetworkAvailability(engineName: engine.rawValue)
        case .whisper:
            // Local server needs connectivity check
            return await checkLocalServerAvailability(engineName: "Whisper Local Server")
        case .notConfigured:
            return (false, "No transcription engine configured")
        }
    }

    private func checkSummarizationEngineAvailability(_ engine: String) async -> (available: Bool, reason: String?) {
        let lowerEngine = engine.lowercased()

        // On-device engines
        if lowerEngine.contains("on-device") || lowerEngine.contains("apple intelligence") ||
           lowerEngine.contains("apple native") || lowerEngine.contains("foundation") {
            return (true, nil)
        }

        // Local server engines
        if lowerEngine.contains("ollama") || lowerEngine.contains("local") {
            return await checkLocalServerAvailability(engineName: engine)
        }

        // Cloud engines (OpenAI, AWS Bedrock, Google AI, Mistral)
        return await checkNetworkAvailability(engineName: engine)
    }

    private func checkNetworkAvailability(engineName: String) async -> (available: Bool, reason: String?) {
        // Simple reachability check using URLSession
        let url = URL(string: "https://www.apple.com/library/test/success.html")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                return (true, nil)
            }
            return (false, "\(engineName) requires network. Check your connection.")
        } catch {
            return (false, "\(engineName) requires network. Check your connection.")
        }
    }

    private func checkLocalServerAvailability(engineName: String) async -> (available: Bool, reason: String?) {
        // For local servers, we check if the default port is reachable
        // Ollama default: localhost:11434
        // Whisper local: configured port
        let ollamaURL = URL(string: "http://localhost:11434/api/tags")!
        var request = URLRequest(url: ollamaURL)
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                return (true, nil)
            }
            return (false, "\(engineName) server is not available. Start the server and reopen the app.")
        } catch {
            return (false, "\(engineName) server is not available. Start the server and reopen the app.")
        }
    }
    
    private func handleAppTermination() async {
        print("🔄 Handling app termination")

        // Set reason so the Task's CancellationError catch uses .interrupted instead of .cancelled
        cancellationReason = "App was closed"
        currentTaskHandle?.cancel()

        // Note: For termination, the Task may not get a chance to run its catch block,
        // so also directly mark the job as interrupted as a safety net
        if let job = currentJob {
            let interruptedJob = job.withStatus(.interrupted("App was closed"))
            await updateJob(interruptedJob)

            let jobTypeDesc = switch job.type {
            case .transcription: "Transcription"
            case .summarization: "Summarization"
            }
            let modelInfo = job.modelName.map { " (\($0))" } ?? ""
            await sendNotification(
                title: "\(jobTypeDesc) Stopped",
                body: "\(job.recordingName) — \(job.type.engineName)\(modelInfo) was stopped because the app was closed. Open the app to resume."
            )
        }

        currentJob = nil
        cancellationReason = nil
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
            let engine = TranscriptionEngine(rawValue: jobEntry.engine ?? TranscriptionEngine.fluidAudio.rawValue) ?? .fluidAudio
            type = .transcription(engine: engine)
        } else {
            type = .summarization(engine: jobEntry.engine ?? "On-Device AI")
        }
        
        // Convert status string back to JobProcessingStatus enum
        let processingStatus: JobProcessingStatus
        switch status {
        case "Queued":
            processingStatus = .queued
        case "Processing":
            // A persisted "Processing" job means the previous app session ended before status was finalized.
            // Mark as interrupted so it can be resumed instead of appearing permanently active.
            processingStatus = .interrupted(jobEntry.error ?? "Recovered after app restart")
        case "Completed":
            processingStatus = .completed
        case "Failed":
            processingStatus = .failed(jobEntry.error ?? "Unknown error")
        case "Cancelled":
            processingStatus = .cancelled
        case "Interrupted":
            processingStatus = .interrupted(jobEntry.error ?? "App was closed")
        default:
            processingStatus = .queued
        }

        return ProcessingJob(
            id: id,
            type: type,
            recordingPath: recordingPath,
            recordingName: recordingName,
            modelName: jobEntry.modelName,
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

        // Set reason so the Task's CancellationError catch uses .interrupted instead of .cancelled
        cancellationReason = "App went to background"
        currentTaskHandle?.cancel()

        print("✅ Background task expiration handled — Task catch block will complete cleanup")
    }
    
    private func monitorBackgroundTime() {
        guard backgroundTaskID != .invalid else { return }

        let remainingTime = UIApplication.shared.backgroundTimeRemaining

        // Skip monitoring and refreshing if we have unlimited time (app is likely in foreground or has special privileges/audio session active)
        guard remainingTime != Double.greatestFiniteMagnitude else { return }

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
        let badgeCount = getActiveJobCount()
        content.badge = NSNumber(value: badgeCount)
        
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
    
    /// Returns the count used for the app icon badge.
    ///
    /// Only jobs that are actively pending work should contribute to the badge.
    /// Interrupted/failed/cancelled jobs should not keep a stale badge visible,
    /// because there is no active notification workload for the user to clear.
    private func getActiveJobCount() -> Int {
        activeJobs.filter { job in
            switch job.status {
            case .ready, .queued, .processing:
                return true
            case .completed, .failed, .cancelled, .interrupted:
                return false
            }
        }.count
    }
    
    private func clearNotificationBadge() async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(0)
        } catch {
            print("⚠️ Failed to clear notification badge: \(error)")
        }
    }
    
    // MARK: - Stale Job Cleanup
    
    /// Reconciles jobs that are stuck in `processing` without a live task, or exceed timeout.
    func cleanupStaleJobs() async {
        guard !isCleaningUpStaleJobs else { return }
        isCleaningUpStaleJobs = true
        defer { isCleaningUpStaleJobs = false }

        let processingTimeoutThreshold: TimeInterval = 3600 // 1 hour hard timeout
        let orphanedProcessingThreshold: TimeInterval = 120 // 2 minute grace period
        let now = Date()
        var reconciledCount = 0

        for job in activeJobs where job.status == .processing {
            // Use processingStartTime (when the job actually began processing) for timeout,
            // falling back to startTime for jobs rehydrated from Core Data where it's unavailable.
            let effectiveStart = job.processingStartTime ?? job.startTime
            let timeSinceProcessingBegan = now.timeIntervalSince(effectiveStart)
            let isCurrentInProcess = currentJob?.id == job.id
            let hasExternalTask = externalTaskHandles[job.id] != nil

            if timeSinceProcessingBegan > processingTimeoutThreshold {
                let timeoutMessage = "Job timed out after \(Int(timeSinceProcessingBegan/60)) minutes"

                // Write the failure status first, before cancelling the task.
                let failedJob = job.withStatus(.failed(timeoutMessage))
                await updateJobInMemoryAndCoreData(failedJob)
                reconciledCount += 1

                // Cancel live task handles. Set cancellationReason so the task's
                // CancellationError catch block doesn't overwrite .failed with .cancelled.
                // Keep currentJob/currentTaskHandle bound — the task's natural exit path
                // (after the do/catch) will clear them and schedule the next queued job,
                // preventing overlapping execution if cancellation takes time to propagate.
                if isCurrentInProcess {
                    cancellationReason = timeoutMessage
                    currentTaskHandle?.cancel()
                }
                if let externalTask = externalTaskHandles.removeValue(forKey: job.id) {
                    externalTask.cancel()
                }
                continue
            }

            // If no task is actively associated with this processing job, reconcile it out of active state.
            if !isCurrentInProcess && !hasExternalTask && timeSinceProcessingBegan > orphanedProcessingThreshold {
                let interruptedJob = job.withStatus(.interrupted("Processing stopped unexpectedly"))
                await updateJobInMemoryAndCoreData(interruptedJob)
                reconciledCount += 1
            }
        }

        if reconciledCount > 0 {
            print("🧹 Reconciled \(reconciledCount) stale/orphaned processing job(s)")
            objectWillChange.send()

            // Re-queue interrupted jobs after reconciliation (suppress notifications from periodic monitor).
            await resumeInterruptedJobs(notify: false)
            if currentJob == nil && activeJobs.contains(where: { $0.status == .queued }) {
                await processNextJob()
            }
        }
    }
    
    /// Updates job both in memory and Core Data
    private func updateJobInMemoryAndCoreData(_ updatedJob: ProcessingJob) async {
        // Update in memory
        if let index = activeJobs.firstIndex(where: { $0.id == updatedJob.id }) {
            activeJobs[index] = updatedJob
        }

        // Keep currentJob in sync so the UI reflects the update immediately
        if updatedJob.id == currentJob?.id {
            currentJob = updatedJob
            processingStatus = updatedJob.status
        }

        // Update in Core Data — use displayName for status (title-case) to match
        // convertToProcessingJob's expected format, and store error separately.
        if let jobEntry = coreDataManager.getProcessingJob(id: updatedJob.id) {
            jobEntry.status = updatedJob.status.displayName
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
    
    // MARK: - Manual Cleanup Functions
    
    /// Manually cleanup all failed and completed jobs
    func cleanupCompletedJobs() async {
        let jobsToRemove = activeJobs.filter { job in
            job.status.isTerminal
        }

        for job in jobsToRemove {
            // Remove from Core Data
            if let jobEntry = coreDataManager.getProcessingJob(id: job.id) {
                coreDataManager.deleteProcessingJob(jobEntry)
            }
        }

        // Remove from memory
        activeJobs.removeAll { job in
            job.status.isTerminal
        }
        
        print("🧹 Cleaned up \(jobsToRemove.count) completed/failed jobs")
        
        // Update UI
        await MainActor.run {
            self.objectWillChange.send()
        }
    }
    
    /// Cancel all processing and queued jobs
    func cancelAllJobs() async {
        // Cancel the running task handle — the Task's catch block will handle
        // status update and cleanup for the active job
        currentTaskHandle?.cancel()

        // Cancel all external task handles
        for (id, task) in externalTaskHandles {
            task.cancel()
            // Update external job status to cancelled
            if let index = activeJobs.firstIndex(where: { $0.id == id }) {
                let cancelledJob = activeJobs[index].withStatus(.cancelled)
                await updateJob(cancelledJob)
            }
        }
        let externalCount = externalTaskHandles.count
        externalTaskHandles.removeAll()

        // Cancel all queued jobs (these don't have task handles)
        let queuedJobs = activeJobs.filter { $0.status == .queued }
        for job in queuedJobs {
            let cancelledJob = job.withStatus(.cancelled)
            await updateJob(cancelledJob)
        }

        let totalCancelled = (currentJob != nil ? 1 : 0) + externalCount + queuedJobs.count
        if totalCancelled > 0 {
            print("🛑 Cancelling \(totalCancelled) jobs")
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
