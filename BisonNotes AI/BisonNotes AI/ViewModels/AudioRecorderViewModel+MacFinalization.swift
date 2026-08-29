//
//  AudioRecorderViewModel+MacFinalization.swift
//  BisonNotes AI
//
//  Validates independent Mac capture tracks, selects the safest available
//  finalization path, and preserves source media if finalization fails.
//

#if os(macOS)

import Foundation
@preconcurrency import AVFoundation

extension AudioRecorderViewModel {
    /// Persist a Mac recording to Core Data after the capture engines stop.
    @MainActor
    func finalizeMacRecording(at url: URL) async {
        let scratchURLs = allMacScratchURLs()
        let usableMicrophoneURLs = await usableAudioURLs(from: scratchURLs)
        let usableSystemAudioURL = await usableSystemAudioURL()
        let plan = MacRecordingFinalizationPlan.choose(
            hasMicrophoneAudio: !usableMicrophoneURLs.isEmpty,
            hasSystemAudio: usableSystemAudioURL != nil
        )
        AppLog.shared.recording(
            "Mac recording finalization plan: \(plan) " +
            "(usableMicrophoneSegments=\(usableMicrophoneURLs.count), " +
            "systemAudio=\(usableSystemAudioURL != nil))"
        )

        do {
            try await executeFinalizationPlan(
                plan,
                microphoneURLs: usableMicrophoneURLs,
                systemAudioURL: usableSystemAudioURL,
                finalURL: url
            )

            let finalization = await RecordingFinalizationPolicy.inspect(url: url, delegateSucceeded: true)
            guard case .usable(let fileSize, let duration) = finalization else {
                let description: String
                if case .rejected(let rejection) = finalization {
                    description = rejection.userMessage
                } else {
                    description = "The finalized recording did not contain usable audio."
                }
                throw NSError(
                    domain: "AudioRecorderViewModel.Mac",
                    code: -18,
                    userInfo: [NSLocalizedDescriptionKey: description]
                )
            }

            removeMacScratchFiles(scratchURLs)
            if let systemAudioURL = macSystemAudioURL {
                try? FileManager.default.removeItem(at: systemAudioURL)
            }
            saveFinalizedMacRecording(at: url, fileSize: fileSize, duration: duration)
            return
        } catch {
            handleMacFinalizationFailure(error, scratchURLs: scratchURLs, finalURL: url)
            return
        }
    }

    private func usableSystemAudioURL() async -> URL? {
        guard let systemAudioURL = macSystemAudioURL,
              await audioAssetHasUsableAudio(at: systemAudioURL) else { return nil }
        return systemAudioURL
    }

    private func executeFinalizationPlan(
        _ plan: MacRecordingFinalizationPlan,
        microphoneURLs: [URL],
        systemAudioURL: URL?,
        finalURL: URL
    ) async throws {
        switch plan {
        case .mixMicrophoneAndSystem:
            guard let systemAudioURL else { throw CocoaError(.fileNoSuchFile) }
            try await exportAndMixMacRecording(
                microphoneScratchURLs: microphoneURLs,
                systemAudioURL: systemAudioURL,
                finalURL: finalURL
            )
        case .microphoneOnly:
            try await exportMacScratchRecordings(from: microphoneURLs, to: finalURL)
        case .systemOnly:
            guard let systemAudioURL else { throw CocoaError(.fileNoSuchFile) }
            try await exportMacScratchRecording(from: systemAudioURL, to: finalURL)
            errorMessage = "The microphone track was unavailable. Saved meeting/system audio only."
        case .unavailable:
            throw NSError(
                domain: "AudioRecorderViewModel.Mac",
                code: -17,
                userInfo: [NSLocalizedDescriptionKey: "No captured microphone or system audio was usable."]
            )
        }
    }

    private func usableAudioURLs(from urls: [URL]) async -> [URL] {
        var usableURLs: [URL] = []
        for url in urls where await audioAssetHasUsableAudio(at: url) {
            usableURLs.append(url)
        }
        return usableURLs
    }

    private func audioAssetHasUsableAudio(at url: URL) async -> Bool {
        switch await RecordingFinalizationPolicy.inspect(url: url, delegateSucceeded: true) {
        case .usable:
            return true
        case .rejected(let rejection):
            AppLog.shared.recording(
                "Could not inspect captured audio \(url.lastPathComponent): \(rejection)",
                level: .error
            )
            return false
        }
    }

    private func handleMacFinalizationFailure(
        _ error: Error,
        scratchURLs: [URL],
        finalURL: URL
    ) {
        AppLog.shared.recording(
            "Mac finalize: failed to export recording: \(error.localizedDescription)",
            level: .error
        )
        let recoveryURL = preserveMacRecoveryFiles(
            scratchURLs: scratchURLs,
            systemAudioURL: macSystemAudioURL,
            finalURL: finalURL,
            reason: error.localizedDescription
        )
        errorMessage = "Recording could not be finalized: \(error.localizedDescription)" +
            (recoveryURL == nil ? "" : " Recovery files were preserved for support.")
        resetMacFinalizationState()
    }

    @MainActor
    private func saveFinalizedMacRecording(at url: URL, fileSize: Int64, duration: TimeInterval) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLog.shared.recording(
                "Mac finalize: recording file is missing at \(url.lastPathComponent)",
                level: .error
            )
            errorMessage = "Recording was lost — file was not written."
            return
        }

        saveLocationData(for: url)
        guard let workflowManager else {
            AppLog.shared.recording("WorkflowManager not set - Mac recording not saved", level: .error)
            return
        }

        let recordingId = workflowManager.createRecording(
            url: url,
            name: generateAppRecordingDisplayName(),
            date: currentRecordingDate(for: url),
            fileSize: fileSize,
            duration: duration,
            quality: AudioRecorderViewModel.getCurrentAudioQuality(),
            locationData: recordingLocationSnapshot()
        )
        AppLog.shared.recording("Mac recording created with workflow manager, ID: \(recordingId)")

        // A meeting recording (system-audio capture) suppresses the live mic-only
        // transcription path at start. If Live Transcription is enabled, honor that
        // intent by queuing a file-based transcription so the recording still gets a
        // transcript. Reaching this path with enableLiveTranscription == true implies a
        // meeting recording — non-meeting recordings with the setting on take the live
        // path and never finalize here.
        if UserDefaults.standard.bool(forKey: "enableLiveTranscription"),
           let coordinator = appCoordinator,
           let entry = coordinator.getRecording(id: recordingId) {
            TranscriptionStarter.shared.startTranscription(
                for: entry,
                cleanFirst: false,
                appCoordinator: coordinator
            )
            AppLog.shared.recording("Mac meeting recording queued for file-based transcription")
        }

        resetMacFinalizationState()
    }

    private func resetMacFinalizationState() {
        resetRecordingLocation()
        recordingStartedAt = nil
        recordingBeingProcessed = false
        macScratchRecordingURL = nil
        macScratchSegmentURLs = []
        macSystemAudioURL = nil
        macMicrophoneStartOffset = 0
        resetRecordingAttemptArtifacts()
    }

    func allMacScratchURLs() -> [URL] {
        var scratchURLs = macScratchSegmentURLs
        if let currentScratchURL = macScratchRecordingURL,
           !scratchURLs.contains(currentScratchURL) {
            scratchURLs.append(currentScratchURL)
        }
        return scratchURLs
    }

    private func removeMacScratchFiles(_ scratchURLs: [URL]) {
        for scratchURL in scratchURLs {
            try? FileManager.default.removeItem(at: scratchURL)
        }
    }

    @discardableResult
    func preserveMacRecoveryFiles(
        scratchURLs: [URL],
        systemAudioURL: URL?,
        finalURL: URL?,
        reason: String
    ) -> URL? {
        guard let finalURL else { return nil }
        var files = scratchURLs
        if let systemAudioURL, !files.contains(systemAudioURL) {
            files.append(systemAudioURL)
        }
        if FileManager.default.fileExists(atPath: finalURL.path), !files.contains(finalURL) {
            files.append(finalURL)
        }

        do {
            let result = try RecordingRecoveryStore.preserve(
                files: files,
                intendedFinalURL: finalURL,
                reason: reason
            )
            for fileURL in result.preservedFileURLs {
                AppFileProtection.apply(to: fileURL)
            }
            AppLog.shared.recording(
                "Preserved \(result.preservedFileURLs.count) recording recovery files at " +
                "\(result.directoryURL.path)",
                level: .error
            )
            return result.directoryURL
        } catch {
            AppLog.shared.recording(
                "Failed to preserve recording recovery files: \(error.localizedDescription)",
                level: .fault
            )
            return nil
        }
    }
}

#endif
