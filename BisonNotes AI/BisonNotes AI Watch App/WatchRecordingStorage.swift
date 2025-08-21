//
//  WatchRecordingStorage.swift
//  BisonNotes AI Watch App
//
//  Created by Claude on 2025-08-21.
//

import Foundation
import CryptoKit
import Combine

#if canImport(WatchKit)
import WatchKit
#endif

/// Manages local recording storage and metadata on Apple Watch
@MainActor
class WatchRecordingStorage: ObservableObject {
    
    // MARK: - Published Properties
    @Published var localRecordings: [WatchRecordingMetadata] = []
    @Published var storageUsed: Int64 = 0
    @Published var availableStorage: Int64 = 0
    
    // MARK: - Private Properties
    private let fileManager = FileManager.default
    private let recordingsDirectoryName = "WatchRecordings"
    private let metadataFileName = "metadata.json"
    private let maxStorageUsage: Int64 = 50 * 1024 * 1024 // 50MB max storage
    private let maxRecordings = 20 // Keep at most 20 recordings
    
    // Directory URLs
    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    private var recordingsDirectoryURL: URL {
        documentsURL.appendingPathComponent(recordingsDirectoryName)
    }
    
    private var recordingsSubdirectoryURL: URL {
        recordingsDirectoryURL.appendingPathComponent("recordings")
    }
    
    private var metadataFileURL: URL {
        recordingsDirectoryURL.appendingPathComponent(metadataFileName)
    }
    
    // MARK: - Initialization
    
    init() {
        setupStorageDirectories()
        loadRecordingsMetadata()
        updateStorageInfo()
    }
    
    // MARK: - Setup
    
    private func setupStorageDirectories() {
        do {
            try fileManager.createDirectory(at: recordingsDirectoryURL, 
                                          withIntermediateDirectories: true, 
                                          attributes: nil)
            try fileManager.createDirectory(at: recordingsSubdirectoryURL, 
                                          withIntermediateDirectories: true, 
                                          attributes: nil)
            print("⌚ Storage directories created successfully")
        } catch {
            print("❌ Failed to create storage directories: \(error)")
        }
    }
    
    // MARK: - Recording Management
    
    /// Save a completed recording to local storage
    func saveRecording(audioFileURL: URL, sessionId: UUID, duration: TimeInterval) -> WatchRecordingMetadata? {
        // Generate filename with correct extension for AAC format
        let timestamp = Date()
        let filename = "recording-\(sessionId.uuidString).m4a"
        let destinationURL = recordingsSubdirectoryURL.appendingPathComponent(filename)
        
        do {
            // Copy recording file to storage location
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: audioFileURL, to: destinationURL)
            
            // Get file size
            let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            
            // Create metadata
            let metadata = WatchRecordingMetadata(
                id: sessionId,
                filename: filename,
                duration: duration,
                createdAt: timestamp,
                fileSize: fileSize,
                syncStatus: .local,
                syncAttempts: 0
            )
            
            // Add to collection and save
            localRecordings.append(metadata)
            saveRecordingsMetadata()
            updateStorageInfo()
            
            // Clean up old recordings if needed
            performStorageCleanup()
            
            print("✅ Saved recording: \(filename) (\(fileSize) bytes)")
            return metadata
            
        } catch {
            print("❌ Failed to save recording: \(error)")
            return nil
        }
    }
    
    /// Get the file URL for a recording
    func fileURL(for recording: WatchRecordingMetadata) -> URL {
        return recordingsSubdirectoryURL.appendingPathComponent(recording.filename)
    }
    
    /// Delete a recording from local storage
    func deleteRecording(_ recording: WatchRecordingMetadata) {
        let fileURL = self.fileURL(for: recording)
        
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            
            // Remove from metadata
            localRecordings.removeAll { $0.id == recording.id }
            saveRecordingsMetadata()
            updateStorageInfo()
            
            print("🗑 Deleted recording: \(recording.filename)")
            
        } catch {
            print("❌ Failed to delete recording: \(error)")
        }
    }
    
    /// Update sync status for a recording
    func updateSyncStatus(_ recordingId: UUID, status: WatchRecordingSyncStatus, attempts: Int? = nil) {
        if let index = localRecordings.firstIndex(where: { $0.id == recordingId }) {
            var metadata = localRecordings[index]
            metadata.syncStatus = status
            if let attempts = attempts {
                metadata.syncAttempts = attempts
            }
            metadata.lastSyncAttempt = Date()
            
            localRecordings[index] = metadata
            saveRecordingsMetadata()
            
            print("📊 Updated sync status for \(metadata.filename): \(status.rawValue)")
        }
    }
    
    /// Get recordings that need syncing
    func getRecordingsPendingSync() -> [WatchRecordingMetadata] {
        return localRecordings.filter { recording in
            return recording.syncStatus == .local || 
                   recording.syncStatus == .syncFailed || 
                   recording.syncStatus == .pendingSync
        }
    }
    
    /// Get synced recordings that can be cleaned up
    func getSyncedRecordings() -> [WatchRecordingMetadata] {
        return localRecordings.filter { $0.syncStatus == .synced }
    }
    
    // MARK: - Metadata Management
    
    private func loadRecordingsMetadata() {
        guard fileManager.fileExists(atPath: metadataFileURL.path) else {
            localRecordings = []
            return
        }
        
        do {
            let data = try Data(contentsOf: metadataFileURL)
            localRecordings = try JSONDecoder().decode([WatchRecordingMetadata].self, from: data)
            
            // Verify files still exist and clean up orphaned metadata
            cleanupOrphanedMetadata()
            
            print("📱 Loaded \(localRecordings.count) recordings from metadata")
            
        } catch {
            print("❌ Failed to load recordings metadata: \(error)")
            localRecordings = []
        }
    }
    
    private func saveRecordingsMetadata() {
        do {
            let data = try JSONEncoder().encode(localRecordings)
            try data.write(to: metadataFileURL)
            print("💾 Saved recordings metadata")
        } catch {
            print("❌ Failed to save recordings metadata: \(error)")
        }
    }
    
    private func cleanupOrphanedMetadata() {
        let originalCount = localRecordings.count
        
        localRecordings = localRecordings.filter { metadata in
            let fileURL = recordingsSubdirectoryURL.appendingPathComponent(metadata.filename)
            let exists = fileManager.fileExists(atPath: fileURL.path)
            if !exists {
                print("🧹 Removing orphaned metadata for: \(metadata.filename)")
            }
            return exists
        }
        
        if localRecordings.count != originalCount {
            saveRecordingsMetadata()
            print("🧹 Cleaned up \(originalCount - localRecordings.count) orphaned metadata entries")
        }
    }
    
    // MARK: - Storage Management
    
    private func updateStorageInfo() {
        // Calculate storage used by recordings
        storageUsed = localRecordings.reduce(0) { $0 + $1.fileSize }
        
        // Calculate available storage (simple approximation)
        do {
            let attributes = try fileManager.attributesOfFileSystem(forPath: documentsURL.path)
            let _ = attributes[.systemSize] as? Int64 ?? 0  // totalSpace not needed for calculation
            let freeSpace = attributes[.systemFreeSize] as? Int64 ?? 0
            
            // Available for recordings is limited by our max usage policy
            availableStorage = min(freeSpace, maxStorageUsage - storageUsed)
            
        } catch {
            print("❌ Failed to get storage info: \(error)")
            availableStorage = max(0, maxStorageUsage - storageUsed)
        }
    }
    
    private func performStorageCleanup() {
        var needsCleanup = false
        
        // Check if we exceed storage limits
        if storageUsed > maxStorageUsage || localRecordings.count > maxRecordings {
            needsCleanup = true
        }
        
        // Check if free space is critically low
        if availableStorage < 5 * 1024 * 1024 { // Less than 5MB
            needsCleanup = true
        }
        
        if needsCleanup {
            performAutomaticCleanup()
        }
    }
    
    private func performAutomaticCleanup() {
        print("🧹 Performing automatic storage cleanup...")
        
        // First, remove synced recordings (oldest first)
        let syncedRecordings = getSyncedRecordings()
            .sorted { $0.createdAt < $1.createdAt }
        
        for recording in syncedRecordings {
            deleteRecording(recording)
            updateStorageInfo()
            
            // Check if we're now within limits
            if storageUsed <= (maxStorageUsage * 8 / 10) && // 80% of max
               localRecordings.count <= (maxRecordings * 8 / 10) { // 80% of max
                break
            }
        }
        
        // If still over limits, remove failed sync recordings (oldest first)
        if storageUsed > maxStorageUsage || localRecordings.count > maxRecordings {
            let failedRecordings = localRecordings
                .filter { $0.syncStatus == .syncFailed && $0.syncAttempts >= 3 }
                .sorted { $0.createdAt < $1.createdAt }
            
            for recording in failedRecordings {
                deleteRecording(recording)
                updateStorageInfo()
                
                if storageUsed <= maxStorageUsage && localRecordings.count <= maxRecordings {
                    break
                }
            }
        }
        
        print("🧹 Cleanup complete. Storage: \(storageUsed) bytes, Recordings: \(localRecordings.count)")
    }
    
    // MARK: - Utilities
    
    /// Calculate MD5 checksum for a recording file
    func calculateChecksum(for recording: WatchRecordingMetadata) -> String? {
        let fileURL = self.fileURL(for: recording)
        
        do {
            let data = try Data(contentsOf: fileURL)
            let digest = Insecure.MD5.hash(data: data)
            return digest.map { String(format: "%02hhx", $0) }.joined()
        } catch {
            print("❌ Failed to calculate checksum: \(error)")
            return nil
        }
    }
    
    /// Get formatted storage info string
    var storageInfoString: String {
        let usedMB = Double(storageUsed) / (1024 * 1024)
        let availableMB = Double(availableStorage) / (1024 * 1024)
        return String(format: "Used: %.1f MB, Available: %.1f MB", usedMB, availableMB)
    }
    
    /// Check if there's enough space for a recording
    func hasSpaceForRecording(estimatedSize: Int64) -> Bool {
        return availableStorage >= estimatedSize
    }
}

// MARK: - Supporting Types

/// Metadata for a locally stored recording
struct WatchRecordingMetadata: Codable, Identifiable, Equatable {
    let id: UUID
    let filename: String
    let duration: TimeInterval
    let createdAt: Date
    let fileSize: Int64
    var syncStatus: WatchRecordingSyncStatus
    var syncAttempts: Int
    var lastSyncAttempt: Date?
    
    init(id: UUID, filename: String, duration: TimeInterval, createdAt: Date, 
         fileSize: Int64, syncStatus: WatchRecordingSyncStatus, syncAttempts: Int) {
        self.id = id
        self.filename = filename
        self.duration = duration
        self.createdAt = createdAt
        self.fileSize = fileSize
        self.syncStatus = syncStatus
        self.syncAttempts = syncAttempts
        self.lastSyncAttempt = nil
    }
}

/// Sync status for local recordings
enum WatchRecordingSyncStatus: String, Codable, CaseIterable {
    case local = "local"               // Stored locally, not synced
    case pendingSync = "pending_sync"   // Queued for sync
    case syncing = "syncing"           // Currently transferring
    case synced = "synced"             // Successfully synced
    case syncFailed = "sync_failed"    // Sync failed, needs retry
    
    var description: String {
        switch self {
        case .local:
            return "Local"
        case .pendingSync:
            return "Pending Sync"
        case .syncing:
            return "Syncing"
        case .synced:
            return "Synced"
        case .syncFailed:
            return "Sync Failed"
        }
    }
    
    var needsSync: Bool {
        return self == .local || self == .pendingSync || self == .syncFailed
    }
}