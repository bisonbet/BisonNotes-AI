//
//  TranscriptionStarter.swift
//  BisonNotes AI
//
//  Shared entry point for starting transcription from any UI surface
//  (Recordings list, AudioPlayerView, Transcripts tab). Owns the serial
//  audio-cleanup queue so heavy cleanup work never runs concurrently.
//

import Foundation
import SwiftUI

@MainActor
final class TranscriptionStarter: ObservableObject {
    static let shared = TranscriptionStarter()

    /// Recordings waiting for their turn in the cleanup queue.
    @Published private(set) var queuedCleanupRecordings: [RecordingEntry] = []
    /// The recording currently undergoing audio cleanup, if any.
    @Published private(set) var activeCleaningRecordingId: UUID?

    private var isProcessingCleanupQueue: Bool = false
    private let backgroundProcessingManager = BackgroundProcessingManager.shared
    private let enhancedTranscriptionManager = EnhancedTranscriptionManager()

    private init() {}

    // MARK: - State queries

    func isCleaning(_ recordingId: UUID) -> Bool {
        activeCleaningRecordingId == recordingId
    }

    func isQueuedForCleanup(_ recordingId: UUID) -> Bool {
        queuedCleanupRecordings.contains { $0.id == recordingId }
    }

    /// True when the recording has a queued or processing transcription job in the background manager.
    /// Resolves the filename directly from the stored URL string — no disk I/O — so it is safe to
    /// call per row at list scale (List previously stalled on Mac Catalyst when this routed through
    /// AppDataCoordinator.getAbsoluteURL, which probes FileManager and may save the Core Data context).
    func hasActiveTranscriptionJob(for recording: RecordingEntry, appCoordinator: AppDataCoordinator) -> Bool {
        guard let filename = filename(for: recording) else { return false }
        return backgroundProcessingManager.activeJobs.contains { job in
            job.recordingPath == filename &&
            job.type.isTranscription &&
            (job.status == .queued || job.status == .processing)
        }
    }

    /// The current status of the active transcription job for this recording, if any.
    func activeTranscriptionJobStatus(for recording: RecordingEntry, appCoordinator: AppDataCoordinator) -> JobProcessingStatus? {
        guard let filename = filename(for: recording) else { return nil }
        return backgroundProcessingManager.activeJobs.first { job in
            job.recordingPath == filename &&
            job.type.isTranscription &&
            (job.status == .queued || job.status == .processing)
        }?.status
    }

    /// Cheap filename derivation from the stored URL string. Handles both legacy absolute URLs and
    /// relative paths. Does not touch the file system or Core Data context.
    private func filename(for recording: RecordingEntry) -> String? {
        guard let stored = recording.recordingURL else { return nil }
        if let url = URL(string: stored), url.scheme != nil {
            return url.lastPathComponent
        }
        return (stored as NSString).lastPathComponent
    }

    // MARK: - Entry point

    /// Begin transcription for a recording. Caller is responsible for asking the user
    /// whether to clean audio first; pass `cleanFirst` accordingly.
    func startTranscription(for recording: RecordingEntry,
                            cleanFirst: Bool,
                            appCoordinator: AppDataCoordinator) {
        guard !hasActiveTranscriptionJob(for: recording, appCoordinator: appCoordinator) else { return }

        if cleanFirst {
            queuedCleanupRecordings.append(recording)
            processCleanupQueueIfNeeded(appCoordinator: appCoordinator)
        } else {
            performEnhancedTranscription(for: recording, sourceAudioURL: nil, appCoordinator: appCoordinator)
        }
    }

    // MARK: - Cleanup queue (serial)

    private func processCleanupQueueIfNeeded(appCoordinator: AppDataCoordinator) {
        guard !isProcessingCleanupQueue, !queuedCleanupRecordings.isEmpty else { return }
        isProcessingCleanupQueue = true

        let recording = queuedCleanupRecordings.removeFirst()
        activeCleaningRecordingId = recording.id

        Task { @MainActor in
            defer {
                activeCleaningRecordingId = nil
                isProcessingCleanupQueue = false
                processCleanupQueueIfNeeded(appCoordinator: appCoordinator)
            }

            guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
                performEnhancedTranscription(for: recording, sourceAudioURL: nil, appCoordinator: appCoordinator)
                return
            }
            do {
                let tempCleanedURL = try await AudioCleanupService.shared.cleanAudio(at: recordingURL)
                AppLog.shared.transcription("Cleaned audio created at temp location: \(tempCleanedURL.lastPathComponent)", level: .debug)

                // Copy cleaned file into Documents so ProcessingJob can resolve it.
                guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                    AppLog.shared.transcription("Could not access Documents directory, using original file", level: .error)
                    performEnhancedTranscription(for: recording, sourceAudioURL: nil, appCoordinator: appCoordinator)
                    return
                }

                let cleanedFilename = tempCleanedURL.lastPathComponent
                let documentsCleanedURL = documentsURL.appendingPathComponent(cleanedFilename)
                try? FileManager.default.removeItem(at: documentsCleanedURL)
                try FileManager.default.copyItem(at: tempCleanedURL, to: documentsCleanedURL)
                AppLog.shared.transcription("Copied cleaned audio to Documents: \(cleanedFilename)", level: .debug)
                await AudioCleanupService.shared.removeTempFile(at: tempCleanedURL)

                performEnhancedTranscription(for: recording, sourceAudioURL: documentsCleanedURL, appCoordinator: appCoordinator)
            } catch {
                AppLog.shared.transcription("Audio cleanup failed, falling back to original: \(error)", level: .error)
                performEnhancedTranscription(for: recording, sourceAudioURL: nil, appCoordinator: appCoordinator)
            }
        }
    }

    // MARK: - Transcription start (BG manager + direct fallback)

    private func performEnhancedTranscription(for recording: RecordingEntry,
                                              sourceAudioURL: URL?,
                                              appCoordinator: AppDataCoordinator) {
        Task { @MainActor in
            let selectedEngine = TranscriptionEngine(
                rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionEngine") ?? TranscriptionEngine.fluidAudio.rawValue
            ) ?? .fluidAudio

            do {
                guard let recordingURL = appCoordinator.getAbsoluteURL(for: recording) else {
                    AppLog.shared.transcription("Invalid recording URL", level: .error)
                    throw NSError(domain: "Transcription", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Invalid recording URL"])
                }

                try await backgroundProcessingManager.startTranscriptionJob(
                    recordingURL: recordingURL,
                    recordingName: recording.recordingName ?? "Unknown Recording",
                    engine: selectedEngine,
                    sourceAudioURL: sourceAudioURL
                )

                AppLog.shared.transcription("Transcription job started through BackgroundProcessingManager")
            } catch {
                AppLog.shared.transcription("Failed to start transcription job: \(error)", level: .error)

                // Fallback to direct transcription if background processing fails.
                AppLog.shared.transcription("Falling back to direct transcription...", level: .debug)
                do {
                    let transcriptionURL = sourceAudioURL ?? appCoordinator.getAbsoluteURL(for: recording)
                    guard let transcriptionURL else {
                        AppLog.shared.transcription("Invalid recording URL for fallback transcription", level: .error)
                        return
                    }

                    let result = try await enhancedTranscriptionManager.transcribeAudioFile(at: transcriptionURL, using: selectedEngine)
                    AppLog.shared.transcription("Transcription result: success=\(result.success), textLength=\(result.fullText.count)", level: .debug)

                    if result.success && !result.fullText.isEmpty {
                        let identityURL = appCoordinator.getAbsoluteURL(for: recording) ?? transcriptionURL
                        let transcriptData = TranscriptData(
                            recordingURL: identityURL,
                            recordingName: recording.recordingName ?? "Unknown Recording",
                            recordingDate: recording.recordingDate ?? Date(),
                            segments: result.segments
                        )
                        guard let recordingId = transcriptData.recordingId else {
                            AppLog.shared.transcription("Transcript data missing recording ID", level: .error)
                            return
                        }
                        let transcriptId = appCoordinator.addTranscript(
                            for: recordingId,
                            segments: transcriptData.segments,
                            speakerMappings: transcriptData.speakerMappings,
                            engine: transcriptData.engine,
                            processingTime: transcriptData.processingTime,
                            confidence: transcriptData.confidence
                        )
                        if transcriptId != nil {
                            AppLog.shared.transcription("Transcript saved to Core Data with ID: \(transcriptId!)")
                        } else {
                            AppLog.shared.transcription("Failed to save transcript to Core Data", level: .error)
                        }

                        NotificationCenter.default.post(
                            name: NSNotification.Name("TranscriptionCompleted"), object: nil
                        )
                    } else {
                        AppLog.shared.transcription("Transcription failed or returned empty result", level: .error)
                    }
                } catch {
                    AppLog.shared.transcription("Fallback transcription also failed: \(error)", level: .error)
                }

                // Clean up source audio on fallback-path failure (no BG manager to do it).
                if let cleanupURL = sourceAudioURL, cleanupURL.lastPathComponent.hasPrefix("cleaned_") {
                    try? FileManager.default.removeItem(at: cleanupURL)
                    AppLog.shared.transcription("Cleaned up source audio file after fallback: \(cleanupURL.lastPathComponent)", level: .debug)
                }
            }
        }
    }
}
