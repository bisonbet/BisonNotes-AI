//
//  MapSnapshotStorage.swift
//  BisonNotes AI
//
//  Shared storage utility for map snapshots across export services
//

import Foundation
import UIKit

enum MapSnapshotStorage {
    private static let directoryName = "SummaryLocationSnapshots"
    
    /// Get the directory URL for storing map snapshots
    /// - Returns: Directory URL if successful, nil if directory creation fails
    private static func directoryURL() -> URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("❌ MapSnapshotStorage: Unable to access application support directory")
            return nil
        }
        
        let directory = baseURL.appendingPathComponent(directoryName, isDirectory: true)
        
        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                print("✅ MapSnapshotStorage: Created directory at \(directory.path)")
            } catch {
                print("❌ MapSnapshotStorage: Failed to create directory: \(error.localizedDescription)")
                return nil
            }
        }
        
        return directory
    }
    
    /// Get the file URL for a specific map snapshot
    /// - Parameters:
    ///   - summaryId: The unique ID of the summary
    ///   - locationSignature: The location signature string
    /// - Returns: File URL if directory exists, nil otherwise
    private static func fileURL(summaryId: UUID, locationSignature: String) -> URL? {
        // Sanitize the location signature to prevent path traversal attacks
        let sanitizedSignature = locationSignature.replacingOccurrences(
            of: "[^a-zA-Z0-9._-]", 
            with: "_", 
            options: .regularExpression
        )
        
        return directoryURL()?.appendingPathComponent("\(summaryId.uuidString)_\(sanitizedSignature).png")
    }
    
    /// Load raw image data for a map snapshot
    /// - Parameters:
    ///   - summaryId: The unique ID of the summary
    ///   - locationSignature: The location signature string
    /// - Returns: Image data if file exists and is readable, nil otherwise
    static func loadData(summaryId: UUID, locationSignature: String) -> Data? {
        guard let url = fileURL(summaryId: summaryId, locationSignature: locationSignature),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        
        do {
            return try Data(contentsOf: url)
        } catch {
            print("❌ MapSnapshotStorage: Failed to load data from \(url.path): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Load a UIImage for a map snapshot
    /// - Parameters:
    ///   - summaryId: The unique ID of the summary
    ///   - locationSignature: The location signature string
    ///   - scale: The scale factor for the image
    /// - Returns: UIImage if file exists and is valid image data, nil otherwise
    static func loadImage(summaryId: UUID, locationSignature: String, scale: CGFloat) -> UIImage? {
        guard let data = loadData(summaryId: summaryId, locationSignature: locationSignature) else {
            return nil
        }
        
        return UIImage(data: data, scale: scale)
    }
    
    /// Save image data to storage
    /// - Parameters:
    ///   - data: The image data to save
    ///   - summaryId: The unique ID of the summary
    ///   - locationSignature: The location signature string
    /// - Returns: true if save successful, false otherwise
    static func saveImageData(_ data: Data, summaryId: UUID, locationSignature: String) -> Bool {
        guard let url = fileURL(summaryId: summaryId, locationSignature: locationSignature) else {
            print("❌ MapSnapshotStorage: Unable to create file URL for saving")
            return false
        }
        
        do {
            try data.write(to: url)
            print("✅ MapSnapshotStorage: Saved image data to \(url.path)")
            return true
        } catch {
            print("❌ MapSnapshotStorage: Failed to save image data: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Delete a specific map snapshot
    /// - Parameters:
    ///   - summaryId: The unique ID of the summary
    ///   - locationSignature: The location signature string
    /// - Returns: true if deletion successful or file doesn't exist, false if error occurred
    static func deleteImage(summaryId: UUID, locationSignature: String) -> Bool {
        guard let url = fileURL(summaryId: summaryId, locationSignature: locationSignature) else {
            return true // If we can't create the URL, consider it "deleted"
        }
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            return true // File doesn't exist, so it's effectively deleted
        }
        
        do {
            try FileManager.default.removeItem(at: url)
            print("✅ MapSnapshotStorage: Deleted image at \(url.path)")
            return true
        } catch {
            print("❌ MapSnapshotStorage: Failed to delete image: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Get the size of the snapshots directory in bytes
    /// - Returns: Directory size in bytes, or 0 if unable to calculate
    static func getDirectorySize() -> Int64 {
        guard let directoryURL = directoryURL() else { return 0 }
        
        do {
            let resourceKeys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
            let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles], 
                errorHandler: { (url, error) -> Bool in
                    print("❌ MapSnapshotStorage: Error enumerating \(url): \(error)")
                    return true
                }
            )
            
            var totalSize: Int64 = 0
            if let enumerator = enumerator {
                for case let fileURL as URL in enumerator {
                    let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                    if resourceValues.isDirectory != true {
                        totalSize += Int64(resourceValues.fileSize ?? 0)
                    }
                }
            }
            
            return totalSize
        } catch {
            print("❌ MapSnapshotStorage: Failed to calculate directory size: \(error.localizedDescription)")
            return 0
        }
    }
}