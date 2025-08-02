//
//  FileImportManager.swift
//  Audio Journal
//
//  Handles importing audio files from the device
//

import Foundation
import AVFoundation
import UIKit
import SwiftUI

// MARK: - File Import Manager

@MainActor
class FileImportManager: NSObject, ObservableObject {
    
    @Published var isImporting = false
    @Published var importProgress: Double = 0.0
    @Published var currentlyImporting: String = ""
    @Published var importResults: ImportResults?
    @Published var showingImportAlert = false
    
    private let supportedExtensions = ["m4a", "mp3", "wav"]
    
    // MARK: - Import Methods
    
    func importAudioFiles(from urls: [URL]) async {
        guard !isImporting else { return }
        
        isImporting = true
        importProgress = 0.0
        currentlyImporting = "Preparing..."
        
        let totalCount = urls.count
        guard totalCount > 0 else {
            completeImport(with: ImportResults(total: 0, successful: 0, failed: 0, errors: []))
            return
        }
        
        var successful = 0
        var failed = 0
        var errors: [String] = []
        
        for (index, sourceURL) in urls.enumerated() {
            currentlyImporting = "Importing \(sourceURL.lastPathComponent)..."
            importProgress = Double(index) / Double(totalCount)
            
            do {
                try await importAudioFile(from: sourceURL)
                successful += 1
            } catch {
                failed += 1
                errors.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
            
            // Small delay to show progress
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        importProgress = 1.0
        currentlyImporting = "Complete"
        
        let results = ImportResults(
            total: totalCount,
            successful: successful,
            failed: failed,
            errors: errors
        )
        
        completeImport(with: results)
    }
    
    private func importAudioFile(from sourceURL: URL) async throws {
        // Validate file extension
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw ImportError.unsupportedFormat(fileExtension)
        }
        
        // Get documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // Generate unique filename
        let filename = generateUniqueFilename(for: sourceURL)
        let destinationURL = documentsPath.appendingPathComponent(filename)
        
        // Check if file already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw ImportError.fileAlreadyExists(filename)
        }
        
        // Copy file to documents directory with comprehensive error handling for thumbnail issues
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            // Check if this is a thumbnail-related error that we can ignore
            if error.isThumbnailGenerationError {
                print("⚠️ Thumbnail generation warning (can be ignored): \(error.localizedDescription)")
                // Continue with import even if thumbnail generation fails
                // The file copy operation itself succeeded, only thumbnail generation failed
            } else {
                throw ImportError.copyFailed(error.localizedDescription)
            }
        }
        
        // Validate the copied file
        try validateAudioFile(at: destinationURL)
        
        print("✅ Successfully imported: \(filename)")
    }
    
    private func generateUniqueFilename(for sourceURL: URL) -> String {
        let originalName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension
        
        // Generate timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        
        // Create base filename
        let baseFilename = "\(originalName)_\(timestamp).\(fileExtension)"
        
        // Check if file exists and append number if needed
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsPath.appendingPathComponent(baseFilename)
        
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            var counter = 1
            var newFilename = baseFilename
            
            repeat {
                let nameWithoutExt = originalName
                newFilename = "\(nameWithoutExt)_\(timestamp)_\(counter).\(fileExtension)"
                let newURL = documentsPath.appendingPathComponent(newFilename)
                
                if !FileManager.default.fileExists(atPath: newURL.path) {
                    break
                }
                counter += 1
            } while true
            
            return newFilename
        }
        
        return baseFilename
    }
    
    private func validateAudioFile(at url: URL) throws {
        // Try to create an AVAudioPlayer to validate the file
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            if player.duration <= 0 {
                throw ImportError.invalidAudioFile("File has no audio content")
            }
        } catch {
            throw ImportError.invalidAudioFile("Unable to read audio file: \(error.localizedDescription)")
        }
    }
    
    private func completeImport(with results: ImportResults) {
        importResults = results
        isImporting = false
        showingImportAlert = true
    }
    
    // MARK: - Progress Tracking
    
    var progressText: String {
        if isImporting {
            return "\(Int(importProgress * 100))% - \(currentlyImporting)"
        }
        return ""
    }
    
    var canImport: Bool {
        return !isImporting
    }
}

// MARK: - Import Errors

enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    case fileAlreadyExists(String)
    case invalidAudioFile(String)
    case copyFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Unsupported audio format: \(format). Supported formats: m4a, mp3, wav"
        case .fileAlreadyExists(let filename):
            return "File already exists: \(filename)"
        case .invalidAudioFile(let reason):
            return "Invalid audio file: \(reason)"
        case .copyFailed(let reason):
            return "Failed to copy file: \(reason)"
        }
    }
}



// MARK: - Supporting Structures

struct ImportResults {
    let total: Int
    let successful: Int
    let failed: Int
    let errors: [String]
    
    var successRate: Double {
        return total > 0 ? Double(successful) / Double(total) : 0.0
    }
    
    var formattedSuccessRate: String {
        return String(format: "%.1f%%", successRate * 100)
    }
    
    var summary: String {
        if total == 0 {
            return "No files selected for import"
        } else if failed == 0 {
            return "Successfully imported all \(successful) files"
        } else {
            return "Imported \(successful) of \(total) files successfully"
        }
    }
} 