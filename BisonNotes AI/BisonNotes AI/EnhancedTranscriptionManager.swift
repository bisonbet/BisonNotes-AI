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
#if canImport(UIKit)
import UIKit
#endif

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
    /// Absolute ASR word timings are present only for FluidAudio results.
    /// The field is optional so every existing engine initializer remains valid.
    let timedWords: [TimedTranscriptWord]?
    /// Stable speaker IDs and their default display names after local labeling.
    let speakerMappings: [String: String]?
    /// A completed transcript can succeed while local labels are unavailable.
    let speakerLabelWarning: LocalSpeakerLabelWarning?

    init(
        fullText: String,
        segments: [TranscriptSegment],
        processingTime: TimeInterval,
        chunkCount: Int,
        success: Bool,
        error: Error?,
        timedWords: [TimedTranscriptWord]? = nil,
        speakerMappings: [String: String]? = nil,
        speakerLabelWarning: LocalSpeakerLabelWarning? = nil
    ) {
        self.fullText = fullText
        self.segments = segments
        self.processingTime = processingTime
        self.chunkCount = chunkCount
        self.success = success
        self.error = error
        self.timedWords = timedWords
        self.speakerMappings = speakerMappings
        self.speakerLabelWarning = speakerLabelWarning
    }

    func with(
        timedWords: [TimedTranscriptWord]? = nil,
        speakerMappings: [String: String]? = nil,
        speakerLabelWarning: LocalSpeakerLabelWarning? = nil,
        segments: [TranscriptSegment]? = nil
    ) -> TranscriptionResult {
        TranscriptionResult(
            fullText: fullText,
            segments: segments ?? self.segments,
            processingTime: processingTime,
            chunkCount: chunkCount,
            success: success,
            error: error,
            timedWords: timedWords ?? self.timedWords,
            speakerMappings: speakerMappings ?? self.speakerMappings,
            speakerLabelWarning: speakerLabelWarning
        )
    }
}

extension LocalSpeakerLabelsConfiguration {
    /// Read the two user choices once at a completed Parakeet job boundary.
    /// Model readiness, download state, and cache paths are intentionally not
    /// part of this snapshot.
    static func currentUserChoice(from defaults: UserDefaults = .standard) -> LocalSpeakerLabelsConfiguration {
        let enabled = defaults.object(forKey: FluidAudioModelInfo.SettingsKeys.localSpeakerLabelsEnabled) as? Bool
            ?? FluidAudioModelInfo.LocalSpeakerLabels.defaultEnabled
        let rawMethod = defaults.string(forKey: FluidAudioModelInfo.SettingsKeys.selectedLocalSpeakerLabelMethod)
        let normalizedMethod = FluidAudioModelInfo.LocalSpeakerLabels.normalizedMethodRawValue(rawMethod)
        let method = LocalDiarizationMethod(rawValue: normalizedMethod) ?? .defaultMethod
        return LocalSpeakerLabelsConfiguration(isEnabled: enabled, method: method)
    }
}

/// Applies local labels to a completed, unlabeled Parakeet result. This is the
/// only Package C diarization seam: it checks readiness, invokes one complete
/// source-file pass, aligns absolute ASR words, and returns the base result
/// with a structured warning on recoverable label failures.
struct LocalSpeakerLabelingCoordinator {
    private let modelManager: any LocalDiarizationModelManaging
    private let diarizer: any LocalDiarizing
    private let aligner: SpeakerTranscriptAligner

    init(
        modelManager: any LocalDiarizationModelManaging = LocalDiarizationManager.shared,
        diarizer: any LocalDiarizing = LocalDiarizationManager.shared,
        aligner: SpeakerTranscriptAligner = SpeakerTranscriptAligner()
    ) {
        self.modelManager = modelManager
        self.diarizer = diarizer
        self.aligner = aligner
    }

    func apply(
        to baseResult: TranscriptionResult,
        configuration: LocalSpeakerLabelsConfiguration,
        sourceAudioURL: URL,
        audioDuration: TimeInterval
    ) async throws -> TranscriptionResult {
        guard configuration.isEnabled, baseResult.success else {
            return baseResult
        }
        try Task.checkCancellation()

        guard let words = baseResult.timedWords,
              !words.isEmpty || baseResult.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return baseResult.with(speakerLabelWarning: .timingUnavailable)
        }

        if configuration.method == .experimentalLSEEND,
           audioDuration > (configuration.method.maximumSupportedDuration ?? .greatestFiniteMagnitude) {
            return baseResult.with(
                speakerLabelWarning: .experimentalDurationLimit(
                    duration: audioDuration,
                    maximumDuration: configuration.method.maximumSupportedDuration ?? 3_600
                )
            )
        }

        let status = await modelManager.modelStatus(for: configuration.method)
        try Task.checkCancellation()
        guard status.isReady else {
            return baseResult.with(
                speakerLabelWarning: .modelNotReady(method: configuration.method)
            )
        }

        do {
            let diarization = try await diarizer.diarize(
                audioURL: sourceAudioURL,
                method: configuration.method,
                audioDuration: audioDuration,
                progress: { _ in }
            )
            try Task.checkCancellation()
            await modelManager.unloadModel(for: configuration.method)

            let labeling = aligner.align(
                words: words,
                intervals: diarization.intervals,
                audioDuration: diarization.audioDuration ?? audioDuration
            )
            guard !labeling.segments.isEmpty || baseResult.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return baseResult.with(speakerLabelWarning: .timingUnavailable)
            }

            guard normalizedText(baseResult.fullText) == normalizedText(
                SpeakerTranscriptAligner.normalizedPlainText(from: labeling.segments)
            ) else {
                return baseResult.with(speakerLabelWarning: .timingUnavailable)
            }

            let segments = labeling.segments.map { segment in
                TranscriptSegment(
                    speaker: segment.speakerID,
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            }
            let speakerMappings = defaultSpeakerMappings(for: labeling.segments)
            return baseResult.with(
                speakerMappings: speakerMappings,
                speakerLabelWarning: nil,
                segments: segments
            )
        } catch is CancellationError {
            await modelManager.unloadModel(for: configuration.method)
            throw CancellationError()
        } catch {
            await modelManager.unloadModel(for: configuration.method)
            return baseResult.with(
                speakerLabelWarning: .diarizationFailed(method: configuration.method)
            )
        }
    }

    private func defaultSpeakerMappings(
        for segments: [LocalSpeakerLabeledSegment]
    ) -> [String: String] {
        var mappings: [String: String] = [:]
        for speakerID in segments.map(\.speakerID) where speakerID != LocalSpeakerLabeledSegment.unknownSpeakerID {
            guard mappings[speakerID] == nil else { continue }
            if speakerID.hasPrefix("speaker_") {
                mappings[speakerID] = "Speaker \(speakerID.dropFirst("speaker_".count))"
            } else {
                mappings[speakerID] = speakerID
            }
        }
        return mappings
    }

    private func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
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
    private let localSpeakerLabelingCoordinator = LocalSpeakerLabelingCoordinator()
    private var backgroundTaskID: PlatformBackgroundTask.ID = .invalid
    private var backgroundTaskStartTime: Date?
    private var backgroundTaskRefreshTimer: Task<Void, Never>?

    // Configuration - Always use enhanced transcription
    private var enableEnhancedTranscription: Bool {
        return true
    }

    private var maxChunkDuration: TimeInterval {
        UserDefaults.standard.double(forKey: "maxChunkDuration").nonZero ?? 30 // 30 seconds per chunk
    }

    private var maxTranscriptionTime: TimeInterval {
        UserDefaults.standard.double(forKey: "maxTranscriptionTime").nonZero ?? 3600 // 1 hour total timeout
    }

    private var chunkOverlap: TimeInterval {
        UserDefaults.standard.double(forKey: "chunkOverlap").nonZero ?? 2.0 // 2 second overlap between chunks
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

    // Mistral Transcribe Configuration
    private var mistralTranscribeConfig: MistralTranscribeConfig? {
        let apiKey = KeychainSecretStore.shared.string(forKey: KeychainSecretStore.mistralAPIKey) ?? ""
        let modelString = UserDefaults.standard.string(forKey: "mistralTranscribeModel") ?? MistralTranscribeModel.voxtralMiniLatest.rawValue
        let baseURL = UserDefaults.standard.string(forKey: "mistralBaseURL") ?? "https://api.mistral.ai/v1"
        let diarize = UserDefaults.standard.bool(forKey: "mistralTranscribeDiarize")
        let language = UserDefaults.standard.string(forKey: "mistralTranscribeLanguage") ?? ""

        guard !apiKey.isEmpty else {
            AppLog.shared.transcription("Mistral API key is not configured for transcription")
            return nil
        }

        let model = MistralTranscribeModel(rawValue: modelString) ?? .voxtralMiniLatest

        return MistralTranscribeConfig(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            diarize: diarize,
            language: language.isEmpty ? nil : language
        )
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
        _ = port > 0 ? port : 9000

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

    // Alert states for user notifications
    @Published var showingWhisperFallbackAlert = false
    @Published var whisperFallbackMessage = ""

    // MARK: - Initialization

    override init() {
        super.init()
        setupSpeechRecognizer()
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
            AppLog.shared.transcription("Speech recognizer created with locale: \(recognizer.locale.identifier)")
            // Note: Speech authorization will be requested when user actually tries to use native speech recognition transcription
        } else {
            AppLog.shared.transcription("Failed to create speech recognizer with any locale", level: .error)
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
        backgroundTaskID = PlatformBackgroundTask.begin(name: "WhisperTranscription") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTask()
            }
        }

        if backgroundTaskID != .invalid {
            backgroundTaskStartTime = Date()
            AppLog.shared.transcription("Started background task for Whisper: \(backgroundTaskID.rawValue)", level: .debug)

            #if os(iOS)
            // Only iOS background tasks expire. Mac uses one ProcessInfo activity
            // for the full transcription instead of refreshing every 25 seconds.
            startBackgroundTaskRefreshTimer()
            #endif
        }
    }

    private func endBackgroundTask() {
        // Cancel refresh timer first
        backgroundTaskRefreshTimer?.cancel()
        backgroundTaskRefreshTimer = nil

        if backgroundTaskID != .invalid {
            AppLog.shared.transcription("Ending background task for Whisper: \(backgroundTaskID.rawValue)", level: .debug)
            PlatformBackgroundTask.end(backgroundTaskID)
            backgroundTaskID = .invalid
            backgroundTaskStartTime = nil
        }
    }

    private func startBackgroundTaskRefreshTimer() {
        // Cancel any existing timer
        backgroundTaskRefreshTimer?.cancel()

        // Check every 20 seconds and refresh at 25 seconds to avoid iOS 30-second warning
        backgroundTaskRefreshTimer = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000) // 20 seconds

                if !Task.isCancelled, let startTime = backgroundTaskStartTime {
                    let taskAge = Date().timeIntervalSince(startTime)
                    if taskAge > 25 {
                        await refreshBackgroundTask()
                    }
                }
            }
        }
    }

    @MainActor
    private func refreshBackgroundTask() async {
        guard backgroundTaskID != .invalid else { return }

        AppLog.shared.transcription("Refreshing Whisper background task to avoid iOS 30-second warning", level: .debug)

        // End the current task
        let oldTaskID = backgroundTaskID
        PlatformBackgroundTask.end(backgroundTaskID)
        backgroundTaskID = .invalid
        backgroundTaskStartTime = nil
        AppLog.shared.transcription("Ended old task: \(oldTaskID.rawValue)", level: .debug)

        // Immediately start a new one
        backgroundTaskID = PlatformBackgroundTask.begin(name: "WhisperTranscription") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTask()
            }
        }

        if backgroundTaskID != .invalid {
            backgroundTaskStartTime = Date()
            AppLog.shared.transcription("Started new task: \(backgroundTaskID.rawValue)", level: .debug)
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
        AppLog.shared.transcription("App memory usage: \(memoryUsageMB) MB", level: .debug)

        // Only warn about high memory usage, don't cancel transcriptions
        // iOS will handle memory pressure automatically
        let warningThresholdMB: UInt64 = 500 // 500 MB warning threshold
        if memoryUsageMB > warningThresholdMB {
            AppLog.shared.transcription("High app memory usage detected (\(memoryUsageMB) MB), but continuing transcription")
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

    func transcribeAudioFile(at url: URL, using engine: TranscriptionEngine? = nil, recordingId: UUID) async throws -> TranscriptionResult {

        // Check if already transcribing
        guard !isTranscribing else {
    throw TranscriptionError.recognitionFailed(NSError(domain: "AlreadyTranscribing", code: -1, userInfo: nil))
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLog.shared.transcription("File not found: \(url.path)", level: .error)
            throw TranscriptionError.fileNotFound
        }

        // Snapshot local speaker-label choices at the start of the completed
        // Parakeet job. Later settings changes cannot switch this job's method.
        let selectedEngine = engine ?? .fluidAudio // Default fallback
        let localSpeakerLabelsConfiguration = selectedEngine == .fluidAudio
            ? LocalSpeakerLabelsConfiguration.currentUserChoice()
            : nil

        // Validate audio file before transcription
        do {
            let testPlayer = try AVAudioPlayer(contentsOf: url)
            guard testPlayer.duration > 0 else {
    throw TranscriptionError.noSpeechDetected
            }

            // Check if duration is reasonable
            let durationMinutes = testPlayer.duration / 60
if durationMinutes > 120 { // 2 hours max
                AppLog.shared.transcription("Audio file is very long (\(durationMinutes) minutes), this may cause memory issues")
            }
        } catch {
            AppLog.shared.transcription("Audio file validation failed: \(error)", level: .error)
            throw TranscriptionError.audioExtractionFailed
        }

        // Check file duration
        let duration = try await getAudioDuration(url: url)

        // Select the configured transcription engine
        switch selectedEngine {
        case .notConfigured:
            AppLog.shared.transcription("Transcription engine not configured", level: .error)
            throw TranscriptionError.engineNotConfigured

        case .fluidAudio:
            switchToFluidAudioTranscription()
            return try await transcribeWithFluidAudio(
                url: url,
                duration: duration,
                configuration: localSpeakerLabelsConfiguration ?? LocalSpeakerLabelsConfiguration()
            )

        case .whisper:
            switchToWhisperTranscription()

            // Validate Whisper configuration and availability
            if !isWhisperProperlyConfigured() {
                AppLog.shared.transcription("Whisper not properly configured, falling back to native speech recognition")
            return try await transcribeWithNativeSpeech(url: url, duration: duration, recordingId: recordingId)
            }

            let isWhisperAvailable = await validateWhisperService()
if isWhisperAvailable {
                if let config = whisperConfig {
                    return try await transcribeWithWhisper(url: url, config: config, recordingId: recordingId)
                } else {
                    return try await transcribeWithNativeSpeech(url: url, duration: duration, recordingId: recordingId)
                }
            } else {
                return try await transcribeWithNativeSpeech(url: url, duration: duration, recordingId: recordingId)
            }

        case .mistralAI:
            // Validate Mistral configuration
            if let config = mistralTranscribeConfig {
                return try await transcribeWithMistral(url: url, config: config, recordingId: recordingId)
            } else {
                // Ensure speech recognizer is available for fallback
                guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                    throw TranscriptionError.speechRecognizerUnavailable
                }
                return try await transcribeWithNativeSpeech(url: url, duration: duration, recordingId: recordingId)
            }

        }
    }

    private func transcribeWithNativeSpeech(url: URL, duration: TimeInterval, recordingId: UUID) async throws -> TranscriptionResult {
        // Ensure transcription state is properly initialized
        await MainActor.run {
            isTranscribing = true
            currentStatus = "Initializing native speech recognition transcription..."
        }

        AppLog.shared.transcription("Starting native speech recognition for file: \(url.lastPathComponent), duration: \(duration)s")

        // Request speech recognition authorization if needed
        let authStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        AppLog.shared.transcription("Speech recognition authorization status: \(authStatus.rawValue)", level: .debug)

        guard authStatus == .authorized else {
            await MainActor.run {
                isTranscribing = false
                currentStatus = "Speech recognition not authorized"
            }

            let statusMessage: String
            switch authStatus {
            case .denied:
                statusMessage = "Speech recognition access denied. Enable in Settings > Privacy & Security > Speech Recognition."
            case .restricted:
                statusMessage = "Speech recognition is restricted on this device."
            case .notDetermined:
                statusMessage = "Speech recognition permission not requested. Please try again."
            case .authorized:
                statusMessage = "Speech recognition authorized but failed."
            @unknown default:
                statusMessage = "Speech recognition authorization failed."
            }

            AppLog.shared.transcription("Speech recognition authorization failed: \(statusMessage)", level: .error)
            throw TranscriptionError.speechRecognitionNotAuthorized
        }

        // Double-check speech recognizer availability right before transcription
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            await MainActor.run {
                isTranscribing = false
                currentStatus = "Speech recognition service unavailable"
            }
            AppLog.shared.transcription("Speech recognizer service check failed at transcription start", level: .error)
            throw TranscriptionError.speechRecognizerUnavailable
        }

        // Use the existing logic for native speech recognition transcription
        if !enableEnhancedTranscription || duration <= maxChunkDuration {
            AppLog.shared.transcription("Using single chunk transcription (duration: \(duration)s <= \(maxChunkDuration)s)")
            return try await transcribeSingleChunk(url: url)
        } else {
            AppLog.shared.transcription("Using large file transcription (duration: \(duration)s > \(maxChunkDuration)s)")
            return try await transcribeLargeFile(url: url, duration: duration, recordingId: recordingId)
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
            AppLog.shared.transcription("Speech recognizer is not available", level: .error)
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
                    weak let weakSelf = self
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
                                            AppLog.shared.transcription("Transcript contains 'error' text -- may indicate a transcription error was saved as content")
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

    private func transcribeLargeFile(url: URL, duration: TimeInterval, recordingId: UUID) async throws -> TranscriptionResult {
        let startTime = Date()
        isTranscribing = true
        currentStatus = "Processing large file..."

        // Check if file is too large to process safely
        let maxSafeDuration: TimeInterval = 3600 // 1 hour max for chunked processing
        if duration > maxSafeDuration {
            AppLog.shared.transcription("File duration (\(duration/60) minutes) exceeds safe limit (\(maxSafeDuration/60) minutes)", level: .error)
            throw TranscriptionError.fileTooLarge(duration: duration, maxDuration: maxSafeDuration)
        }

        // Check file size to prevent memory issues
do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0
            let fileSizeMB = fileSize / 1024 / 1024

            let maxFileSizeMB: Int64 = 500 // 500 MB max
            if fileSizeMB > maxFileSizeMB {
                AppLog.shared.transcription("File size (\(fileSizeMB) MB) exceeds safe limit (\(maxFileSizeMB) MB)", level: .error)
                throw TranscriptionError.fileTooLarge(duration: duration, maxDuration: maxSafeDuration)
            }
        } catch {
            AppLog.shared.transcription("Could not check file size: \(error)", level: .debug)
        }

        // Check available disk space
do {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let documentsAttributes = try FileManager.default.attributesOfFileSystem(forPath: documentsPath.path)
            let freeSpace = documentsAttributes[.systemFreeSize] as? Int64 ?? 0
            let freeSpaceMB = freeSpace / 1024 / 1024

            let minFreeSpaceMB: Int64 = 1000 // 1 GB min
            if freeSpaceMB < minFreeSpaceMB {
                AppLog.shared.transcription("Insufficient disk space (\(freeSpaceMB) MB), need at least \(minFreeSpaceMB) MB", level: .error)
                throw TranscriptionError.audioExtractionFailed
            }
        } catch {
            AppLog.shared.transcription("Could not check disk space: \(error)", level: .debug)
        }

// Calculate chunks
        let chunks = calculateChunks(duration: duration)

        // Limit the number of chunks to prevent memory issues
        let maxChunks = 20 // Maximum number of chunks to process
        if chunks.count > maxChunks {
            AppLog.shared.transcription("Too many chunks (\(chunks.count)), limiting to \(maxChunks)", level: .error)
            throw TranscriptionError.fileTooLarge(duration: duration, maxDuration: maxSafeDuration)
        }

        var transcriptChunks: [TranscriptChunk] = []
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
                    AppLog.shared.transcription("Transcription cancelled during chunk \(index + 1) processing")
                    throw TranscriptionError.recognitionFailed(NSError(domain: "TranscriptionCancelled", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transcription was cancelled by user or system"]))
                }

                // Check if speech recognizer is still available
                guard let recognizer = speechRecognizer else {
                    AppLog.shared.transcription("Speech recognizer is nil during chunk \(index + 1)", level: .error)
                    isTranscribing = false
                    currentStatus = "Speech recognition unavailable - recognizer is nil"
                    throw TranscriptionError.speechRecognizerUnavailable
                }

                guard recognizer.isAvailable else {
                    AppLog.shared.transcription("Speech recognizer became unavailable during chunk \(index + 1), locale: \(recognizer.locale.identifier), authStatus: \(SFSpeechRecognizer.authorizationStatus().rawValue)", level: .error)
                    isTranscribing = false
                    currentStatus = "Speech recognition unavailable"
                    throw TranscriptionError.speechRecognizerUnavailable
                }

                let chunkURL = try await extractAudioChunk(
                    from: url,
                    startTime: chunk.start,
                    endTime: chunk.end
                )
                defer {
                    try? FileManager.default.removeItem(at: chunkURL)
                }
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: chunkURL.path)[.size] as? Int64) ?? 0
                let audioChunk = AudioChunk(
                    originalURL: url,
                    chunkURL: chunkURL,
                    sequenceNumber: transcriptChunks.count,
                    startTime: chunk.start,
                    endTime: chunk.end,
                    fileSize: fileSize
                )

                // Add timeout for individual chunk processing
                let chunkResult = try await withThrowingTaskGroup(of: TranscriptionResult.self) { group in
                    group.addTask {
                        try await self.transcribeChunkInternal(url: chunkURL, startTime: Date())
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

                // Check if this chunk had any content
                if chunkResult.fullText.isEmpty {
                    AppLog.shared.transcription("Chunk \(index + 1) was silent/empty, skipping", level: .debug)
                } else {
                    let transcriptChunk = chunkingService.createTranscriptChunk(
                        from: chunkResult.fullText,
                        audioChunk: audioChunk,
                        segments: chunkResult.segments
                    )
                    transcriptChunks.append(transcriptChunk)
                    allText.append(chunkResult.fullText)
                }

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
                AppLog.shared.transcription("Transcription was cancelled during delay")
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

        AppLog.shared.transcription("Large file transcription completed in \(processingTime/60) minutes")

        // Check if we got any content at all
        if fullText.isEmpty {
            AppLog.shared.transcription("No speech detected in any of \(chunks.count) chunks -- audio may contain only silence or non-speech content")
        }

        // Debug: Check if the transcript contains placeholder text
        if fullText.lowercased().contains("loading") {
            AppLog.shared.transcription("Transcript contains 'loading' text -- may indicate placeholder text in output")
        }

        guard !transcriptChunks.isEmpty else {
            throw TranscriptionError.noSpeechDetected
        }

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let recordingDate = (fileAttributes[.creationDate] as? Date) ?? Date()
        let reassembly = try await chunkingService.reassembleTranscript(
            from: transcriptChunks,
            originalURL: url,
            recordingName: url.deletingPathExtension().lastPathComponent,
            recordingDate: recordingDate,
            recordingId: recordingId
        )

        return TranscriptionResult(
            fullText: reassembly.transcriptData.plainText,
            segments: reassembly.transcriptData.segments,
            processingTime: processingTime,
            chunkCount: transcriptChunks.count,
            success: true,
            error: nil
        )
    }

    /// Internal method for transcribing a chunk without managing the isTranscribing flag
    /// This is used by transcribeLargeFile to avoid cancellation issues between chunks
    private func transcribeChunkInternal(url: URL, startTime: Date) async throws -> TranscriptionResult {
        // Check if speech recognizer is available
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            AppLog.shared.transcription("Speech recognizer is not available", level: .error)
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
                    weak let weakSelf = self
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
                                // Check if this is "no speech detected" error (code 1110)
                                let nsError = error as NSError
                                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                                    AppLog.shared.transcription("No speech detected in chunk - returning empty result to continue processing", level: .debug)
                                    // Return an empty but successful result for silent chunks
                                    let emptyResult = TranscriptionResult(
                                        fullText: "",
                                        segments: [],
                                        processingTime: Date().timeIntervalSince(startTime),
                                        chunkCount: 1,
                                        success: true,
                                        error: nil
                                    )
                                    continuation.resume(returning: emptyResult)
                                    return
                                }

                                // Check if this is a non-critical error that can be safely ignored
                                if self.handleSpeechRecognitionError(error) {
                                    // Non-critical error, continue processing
                                    hasResumed = false
                                    return
                                }

                                // Check if speech recognizer became unavailable
                                if !recognizer.isAvailable {
                                    continuation.resume(throwing: TranscriptionError.speechRecognizerUnavailable)
                                    return
                                }

                                // Critical error, stop processing
                                continuation.resume(throwing: TranscriptionError.recognitionFailed(error))
                            } else if let result = result {
                                if result.isFinal {
                                    let processingTime = Date().timeIntervalSince(startTime)
                                    let transcriptText = result.bestTranscription.formattedString

                                    if transcriptText.isEmpty {
                                        // Return an empty but successful result for silent chunks
                                        AppLog.shared.transcription("Empty transcript for chunk - returning empty result to continue processing", level: .debug)
                                        let emptyResult = TranscriptionResult(
                                            fullText: "",
                                            segments: [],
                                            processingTime: processingTime,
                                            chunkCount: 1,
                                            success: true,
                                            error: nil
                                        )
                                        continuation.resume(returning: emptyResult)
                                    } else {
                                        let segments = self.createSegments(from: result.bestTranscription)
                                        let transcriptionResult = TranscriptionResult(
                                            fullText: transcriptText,
                                            segments: segments,
                                            processingTime: processingTime,
                                            chunkCount: 1,
                                            success: true,
                                            error: nil
                                        )

                                        // DON'T set isTranscribing = false here - let transcribeLargeFile manage it
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

    private func extractAudioChunk(from url: URL, startTime: TimeInterval, endTime: TimeInterval) async throws -> URL {
        AppLog.shared.transcription("Creating audio composition", level: .debug)
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

        AppLog.shared.transcription("Exporting chunk to: \(outputURL.lastPathComponent)", level: .debug)

        exportSession?.outputURL = outputURL
        exportSession?.outputFileType = .m4a

        guard let session = exportSession else {
            AppLog.shared.transcription("Failed to create export session", level: .error)
            throw TranscriptionError.audioExtractionFailed
        }

        AppLog.shared.transcription("Starting export", level: .debug)

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
                AppLog.shared.transcription("Chunk export timeout reached, cancelling", level: .error)
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

        // Limit chunk size to prevent memory issues during transcription
        let maxSafeChunkDuration: TimeInterval = 60 // 60 seconds max per chunk (safety limit)
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
                AppLog.shared.transcription("Breaking chunk calculation to prevent infinite loop")
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

    // MARK: - Whisper Transcription

    private func transcribeWithWhisper(url: URL, config: WhisperConfig, recordingId: UUID) async throws -> TranscriptionResult {
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
                result = try await whisperService.transcribeAudioInChunks(
                    url: url,
                    chunkDuration: maxChunkDuration,
                    recordingId: recordingId
                )
            } else {
                result = try await whisperService.transcribeAudio(url: url, recordingId: recordingId)
            }

return result

        } catch {
            throw TranscriptionError.whisperTranscriptionFailed(error)
        }
    }

    // MARK: - FluidAudio (Parakeet) Transcription

    private func transcribeWithFluidAudio(
        url: URL,
        duration: TimeInterval,
        configuration: LocalSpeakerLabelsConfiguration
    ) async throws -> TranscriptionResult {
        beginBackgroundTask()
        defer { endBackgroundTask() }

        let manager = FluidAudioManager.shared

        guard manager.isAvailableInCurrentBuild else {
            throw TranscriptionError.fluidAudioNotAvailable
        }

        // Check if model is ready
        guard manager.isModelReady else {
            throw TranscriptionError.fluidAudioNotReady
        }

        await MainActor.run {
            isTranscribing = true
            currentStatus = "Preparing Parakeet transcription..."
        }

        do {
            let timedOutput = try await manager.transcribeWithTimingData(audioURL: url)
            let resultWithTiming = timedOutput.result.with(timedWords: timedOutput.timedWords)
            let result = try await localSpeakerLabelingCoordinator.apply(
                to: resultWithTiming,
                configuration: configuration,
                sourceAudioURL: url,
                audioDuration: duration
            )

            await MainActor.run {
                isTranscribing = false
                currentStatus = result.speakerLabelWarning?.userVisibleMessage ?? "Transcription complete"
            }

            return result
        } catch is CancellationError {
            await MainActor.run {
                isTranscribing = false
                currentStatus = "Transcription cancelled"
            }
            throw CancellationError()
        } catch {
            await MainActor.run {
                isTranscribing = false
                currentStatus = "Parakeet transcription failed"
            }
            throw TranscriptionError.fluidAudioTranscriptionFailed(error)
        }
    }

    // MARK: - Mistral Transcription

    private func transcribeWithMistral(url: URL, config: MistralTranscribeConfig, recordingId: UUID) async throws -> TranscriptionResult {
        let mistralService = MistralTranscribeService(config: config, chunkingService: chunkingService)

        do {
            // Test connection first
            try await mistralService.testConnection()

            // Use chunking for large files
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0
            let maxSize: Int64 = 24 * 1024 * 1024 // 24MB conservative limit

            if fileSize > maxSize {
                return try await transcribeWithChunkedMistral(url: url, recordingId: recordingId)
            }

            let mistralResult = try await mistralService.transcribeAudioFile(at: url, recordingId: recordingId)

            // Convert Mistral result to our TranscriptionResult format
            return TranscriptionResult(
                fullText: mistralResult.transcriptText,
                segments: mistralResult.segments,
                processingTime: mistralResult.processingTime,
                chunkCount: 1,
                success: mistralResult.success,
                error: mistralResult.error
            )
        } catch {
            AppLog.shared.transcription("Mistral transcription failed: \(error)", level: .error)
            throw TranscriptionError.mistralTranscriptionFailed(error)
        }
    }

    private func transcribeWithChunkedMistral(url: URL, recordingId: UUID) async throws -> TranscriptionResult {
        guard let mistralConfig = mistralTranscribeConfig else {
            throw TranscriptionError.mistralTranscriptionFailed(TranscriptionError.engineNotConfigured)
        }

        do {
            let mistralService = MistralTranscribeService(config: mistralConfig, chunkingService: chunkingService)

            // Use the chunking service
            let chunkingResult = try await chunkingService.chunkAudioFile(url, for: .mistralAI)
            let chunks = chunkingResult.chunks

            var transcriptChunks: [TranscriptChunk] = []

            for chunk in chunks {
                let mistralResult = try await mistralService.transcribeAudioFile(
                    at: chunk.chunkURL,
                    recordingId: recordingId
                )
                let transcriptChunk = chunkingService.createTranscriptChunk(
                    from: mistralResult.transcriptText,
                    audioChunk: chunk,
                    segments: mistralResult.segments
                )
                transcriptChunks.append(transcriptChunk)
            }

            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let recordingDate = (fileAttributes[.creationDate] as? Date) ?? Date()
            let reassembly = try await chunkingService.reassembleTranscript(
                from: transcriptChunks,
                originalURL: url,
                recordingName: url.deletingPathExtension().lastPathComponent,
                recordingDate: recordingDate,
                recordingId: recordingId
            )

            return TranscriptionResult(
                fullText: reassembly.transcriptData.plainText,
                segments: reassembly.transcriptData.segments,
                processingTime: reassembly.reassemblyTime,
                chunkCount: transcriptChunks.count,
                success: true,
                error: nil
            )
        } catch {
            AppLog.shared.transcription("Chunked Mistral transcription failed: \(error)", level: .error)
            throw TranscriptionError.mistralTranscriptionFailed(error)
        }
    }

    // MARK: - Engine Management

    private func switchToWhisperTranscription() {
        if whisperConfig != nil {
            AppLog.shared.general("Whisper transcription configured and ready")
        } else {
            AppLog.shared.general("Whisper transcription selected but not configured", level: .error)
        }
    }

    private func switchToFluidAudioTranscription() {
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose(
                "FluidAudio (Parakeet) transcription selected",
                category: "EnhancedTranscriptionManager"
            )
        }
    }

    /// Updates manager state when the user changes the selected transcription engine.
    func updateTranscriptionEngine(_ engine: TranscriptionEngine) {
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose(
                "Updating transcription engine to: \(engine.rawValue)",
                category: "EnhancedTranscriptionManager"
            )
        }

        switch engine {
        case .fluidAudio:
            switchToFluidAudioTranscription()
        case .whisper:
            switchToWhisperTranscription()
        case .notConfigured, .mistralAI:
            break
        }
    }

    // MARK: - Error Handling

    private func isNonCriticalSpeechRecognitionError(_ error: Error) -> Bool {
        let nsError = error as NSError

        // Known non-critical errors that can be safely ignored
        let nonCriticalErrors: [(domain: String, code: Int)] = [
            ("kAFAssistantErrorDomain", 1101), // Local speech recognition service error
            ("kAFAssistantErrorDomain", 1100), // Another common local speech recognition error
            ("kAFAssistantErrorDomain", 1107), // Speech recognition authorization/service unavailable
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
            AppLog.shared.transcription("Non-critical speech recognition error (safe to ignore): \(error.localizedDescription)", level: .debug)
            return true // Error was handled
        }

        AppLog.shared.transcription("Critical speech recognition error: \(error)", level: .error)
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
    case speechRecognitionNotAuthorized
    case recognitionFailed(Error)
    case noSpeechDetected
    case chunkProcessingFailed(chunk: Int, error: Error)
    case audioExtractionFailed
    case timeout
    case fileTooLarge(duration: TimeInterval, maxDuration: TimeInterval)
    case whisperConnectionFailed
    case whisperTranscriptionFailed(Error)
    case fluidAudioNotAvailable
    case fluidAudioNotReady
    case fluidAudioTranscriptionFailed(Error)
    case engineNotConfigured
    case mistralTranscriptionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Audio file not found"
        case .speechRecognizerUnavailable:
            return "Speech recognition is not available. This may be due to simulator limitations, missing permissions, or device restrictions. Try running on a physical device or check Settings > Privacy & Security > Speech Recognition."
        case .speechRecognitionNotAuthorized:
            return "Speech recognition permission denied. Please enable Speech Recognition in Settings > Privacy & Security > Speech Recognition to use native speech recognition transcription."
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
        case .whisperConnectionFailed:
            return "Failed to connect to Whisper service"
        case .whisperTranscriptionFailed(let error):
            return "Whisper transcription failed: \(error.localizedDescription)"
        case .fluidAudioNotAvailable:
            return "FluidAudio is not available in this build. Add the FluidAudio Swift package and rebuild."
        case .fluidAudioNotReady:
            return "On-device model is not ready. Download and initialize the Parakeet model in Settings > Transcription > On Device."
        case .fluidAudioTranscriptionFailed(let error):
            return "Parakeet transcription failed: \(error.localizedDescription)"
        case .fileTooLarge(let duration, let maxDuration):
            return "File too large for processing (\(Int(duration/60)) minutes, max \(Int(maxDuration/60)) minutes)"
        case .engineNotConfigured:
            return "Transcription engine not configured. Please configure a transcription engine in Settings."
        case .mistralTranscriptionFailed(let error):
            return "Mistral transcription failed: \(error.localizedDescription)"
        }
    }
}
