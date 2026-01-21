//
//  RecordingCombiner.swift
//  BisonNotes AI
//
//  Service for combining multiple audio recordings into a single file
//

import Foundation
import AVFoundation
import os.log

class RecordingCombiner {
    static let shared = RecordingCombiner()
    private let logger = Logger(subsystem: "com.audiojournal.app", category: "RecordingCombiner")
    
    private init() {}
    
    /// Combine two audio recordings into a single file
    /// - Parameters:
    ///   - firstURL: URL of the first recording (will be first in the combined file)
    ///   - secondURL: URL of the second recording (will be second in the combined file)
    ///   - outputURL: URL where the combined file should be saved
    /// - Returns: The URL of the combined file
    func combineRecordings(firstURL: URL, secondURL: URL, outputURL: URL) async throws -> URL {
        logger.info("Starting to combine recordings: \(firstURL.lastPathComponent) + \(secondURL.lastPathComponent)")
        
        // Load both audio assets
        let firstAsset = AVURLAsset(url: firstURL)
        let secondAsset = AVURLAsset(url: secondURL)
        
        // Create composition
        let composition = AVMutableComposition()
        
        // Get audio tracks from both assets
        guard let firstAudioTrack = try await firstAsset.loadTracks(withMediaType: .audio).first,
              let secondAudioTrack = try await secondAsset.loadTracks(withMediaType: .audio).first else {
            throw RecordingCombinerError.noAudioTrack
        }
        
        // Get durations
        let firstDuration = try await firstAsset.load(.duration)
        let secondDuration = try await secondAsset.load(.duration)
        
        // Create mutable audio tracks in composition
        guard let firstCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ),
        let secondCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecordingCombinerError.compositionFailed
        }
        
        // Insert first track at the beginning
        let firstTimeRange = CMTimeRange(start: .zero, duration: firstDuration)
        try firstCompositionTrack.insertTimeRange(firstTimeRange, of: firstAudioTrack, at: .zero)
        
        // Insert second track after the first
        let secondTimeRange = CMTimeRange(start: .zero, duration: secondDuration)
        try secondCompositionTrack.insertTimeRange(secondTimeRange, of: secondAudioTrack, at: firstDuration)
        
        // Export the composition
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingCombinerError.exportSessionFailed
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        
        // Export asynchronously using iOS 18+ API
        if #available(iOS 18.0, *) {
            // Use new iOS 18+ API
            do {
                try await exportSession.export(to: outputURL, as: .m4a)
            } catch {
                logger.error("Export failed: \(error.localizedDescription)")
                throw RecordingCombinerError.exportFailed(error.localizedDescription)
            }
        } else {
            // Fallback to older API for iOS < 18
            await exportSession.export()
            
            guard exportSession.status == .completed else {
                if let error = exportSession.error {
                    logger.error("Export failed: \(error.localizedDescription)")
                    throw RecordingCombinerError.exportFailed(error.localizedDescription)
                } else {
                    throw RecordingCombinerError.exportFailed("Unknown export error")
                }
            }
        }
        
        logger.info("Successfully combined recordings to: \(outputURL.lastPathComponent)")
        return outputURL
    }
    
    /// Get the recording date from a file URL
    func getRecordingDate(from url: URL) -> Date? {
        // Try to get date from file attributes
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let creationDate = attributes[.creationDate] as? Date {
            return creationDate
        }
        
        // Try to get date from filename (common patterns)
        let filename = url.deletingPathExtension().lastPathComponent
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        if let date = dateFormatter.date(from: filename) {
            return date
        }
        
        // Fallback to modification date
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attributes[.modificationDate] as? Date {
            return modDate
        }
        
        return nil
    }
    
    /// Determine which recording should be first based on dates
    func determineFirstRecording(firstURL: URL, secondURL: URL) -> (first: URL, second: URL) {
        let firstDate = getRecordingDate(from: firstURL) ?? Date.distantPast
        let secondDate = getRecordingDate(from: secondURL) ?? Date.distantPast
        
        if firstDate <= secondDate {
            return (first: firstURL, second: secondURL)
        } else {
            return (first: secondURL, second: firstURL)
        }
    }
}

enum RecordingCombinerError: LocalizedError {
    case noAudioTrack
    case compositionFailed
    case exportSessionFailed
    case exportFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "One or both recordings do not contain audio tracks"
        case .compositionFailed:
            return "Failed to create audio composition"
        case .exportSessionFailed:
            return "Failed to create export session"
        case .exportFailed(let message):
            return "Failed to export combined recording: \(message)"
        }
    }
}
