//
//  AudioRecorderViewModel+MacFinalization.swift
//  BisonNotes AI
//
//  Validates independent Mac capture tracks, selects the safest available
//  finalization path, and preserves source media if finalization fails.
//

#if targetEnvironment(macCatalyst) || os(macOS)

import Foundation
@preconcurrency import AVFoundation

extension AudioRecorderViewModel {
    /// Persist a Mac recording to Core Data after the capture engines stop.
    @MainActor
    func finalizeCatalystRecording(at url: URL) async {
        let scratchURLs = allCatalystScratchURLs()
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
            guard await audioAssetHasUsableAudio(at: url) else {
                throw NSError(
                    domain: "AudioRecorderViewModel.Catalyst",
                    code: -18,
                    userInfo: [NSLocalizedDescriptionKey: "The finalized recording did not contain usable audio."]
                )
            }
        } catch {
            handleCatalystFinalizationFailure(error, scratchURLs: scratchURLs, finalURL: url)
            return
        }

        removeCatalystScratchFiles(scratchURLs)
        if let systemAudioURL = catalystSystemAudioURL {
            try? FileManager.default.removeItem(at: systemAudioURL)
        }
        saveFinalizedCatalystRecording(at: url)
    }

    private func usableSystemAudioURL() async -> URL? {
        guard let systemAudioURL = catalystSystemAudioURL,
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
            try await exportAndMixCatalystRecording(
                microphoneScratchURLs: microphoneURLs,
                systemAudioURL: systemAudioURL,
                finalURL: finalURL
            )
        case .microphoneOnly:
            try await exportCatalystScratchRecordings(from: microphoneURLs, to: finalURL)
        case .systemOnly:
            guard let systemAudioURL else { throw CocoaError(.fileNoSuchFile) }
            try await exportCatalystScratchRecording(from: systemAudioURL, to: finalURL)
            errorMessage = "The microphone track was unavailable. Saved meeting/system audio only."
        case .unavailable:
            throw NSError(
                domain: "AudioRecorderViewModel.Catalyst",
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
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { return false }
            return !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        } catch {
            AppLog.shared.recording(
                "Could not inspect captured audio \(url.lastPathComponent): \(error.localizedDescription)",
                level: .error
            )
            return false
        }
    }

    private func handleCatalystFinalizationFailure(
        _ error: Error,
        scratchURLs: [URL],
        finalURL: URL
    ) {
        AppLog.shared.recording(
            "Catalyst finalize: failed to export recording: \(error.localizedDescription)",
            level: .error
        )
        let recoveryURL = preserveCatalystRecoveryFiles(
            scratchURLs: scratchURLs,
            systemAudioURL: catalystSystemAudioURL,
            finalURL: finalURL,
            reason: error.localizedDescription
        )
        errorMessage = "Recording could not be finalized: \(error.localizedDescription)" +
            (recoveryURL == nil ? "" : " Recovery files were preserved for support.")
        resetCatalystFinalizationState()
    }

    @MainActor
    private func saveFinalizedCatalystRecording(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLog.shared.recording(
                "Catalyst finalize: recording file is missing at \(url.lastPathComponent)",
                level: .error
            )
            errorMessage = "Recording was lost — file was not written."
            return
        }

        saveLocationData(for: url)
        guard let workflowManager else {
            AppLog.shared.recording("WorkflowManager not set - Catalyst recording not saved", level: .error)
            return
        }

        let recordingId = workflowManager.createRecording(
            url: url,
            name: generateAppRecordingDisplayName(),
            date: currentRecordingDate(for: url),
            fileSize: getFileSize(url: url),
            duration: getRecordingDuration(url: url),
            quality: AudioRecorderViewModel.getCurrentAudioQuality(),
            locationData: recordingLocationSnapshot()
        )
        AppLog.shared.recording("Catalyst recording created with workflow manager, ID: \(recordingId)")
        resetCatalystFinalizationState()
    }

    private func resetCatalystFinalizationState() {
        resetRecordingLocation()
        recordingStartedAt = nil
        recordingBeingProcessed = false
        catalystScratchRecordingURL = nil
        catalystScratchSegmentURLs = []
        catalystSystemAudioURL = nil
    }

    func allCatalystScratchURLs() -> [URL] {
        var scratchURLs = catalystScratchSegmentURLs
        if let currentScratchURL = catalystScratchRecordingURL,
           !scratchURLs.contains(currentScratchURL) {
            scratchURLs.append(currentScratchURL)
        }
        return scratchURLs
    }

    private func removeCatalystScratchFiles(_ scratchURLs: [URL]) {
        for scratchURL in scratchURLs {
            try? FileManager.default.removeItem(at: scratchURL)
        }
    }

    @discardableResult
    func preserveCatalystRecoveryFiles(
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
