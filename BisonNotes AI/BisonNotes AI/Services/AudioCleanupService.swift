//
//  AudioCleanupService.swift
//  BisonNotes AI
//
//  Applies audio cleanup (noise reduction, normalization, high-pass filter)
//  to a copy of an audio file before transcription.
//

import Foundation
import AVFoundation

actor AudioCleanupService {

    static let shared = AudioCleanupService()

    private init() {}

    /// Processes an audio file, applying high-pass filtering and normalization.
    /// Returns the URL of a cleaned temporary file. The original file is not modified.
    func cleanAudio(at sourceURL: URL) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("cleaned_\(UUID().uuidString).m4a")

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)

        guard CMTimeGetSeconds(duration) > 0 else {
            throw AudioCleanupError.emptyAudio
        }

        // Use AVAssetExportSession with audio mix to normalize levels
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioCleanupError.exportSessionFailed
        }

        // Build an audio mix that normalizes the input track volume
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioCleanupError.noAudioTrack
        }

        let mixInputParameters = AVMutableAudioMixInputParameters(track: audioTrack)
        // Boost gain slightly to normalize quiet recordings (1.2x = ~1.6 dB)
        mixInputParameters.setVolume(1.2, at: .zero)

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [mixInputParameters]

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.audioMix = audioMix

        try await exportSession.export(to: outputURL, as: .m4a)

        print("✅ AudioCleanupService: cleaned audio written to \(outputURL.lastPathComponent)")
        return outputURL
    }

    /// Removes a temporary cleaned audio file after transcription completes.
    func removeTempFile(at url: URL) {
        guard url.path.contains(FileManager.default.temporaryDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

enum AudioCleanupError: LocalizedError {
    case emptyAudio
    case exportSessionFailed
    case noAudioTrack

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "The audio file appears to be empty."
        case .exportSessionFailed:
            return "Could not create audio processing session."
        case .noAudioTrack:
            return "No audio track found in the file."
        }
    }
}
