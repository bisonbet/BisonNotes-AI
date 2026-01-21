import Foundation
import CloudKit
import SwiftUI
import Network

// MARK: - Sync Status

enum SyncStatus: Equatable {
    case idle
    case syncing
    case completed
    case failed(String)
    
    var description: String {
        switch self {
        case .idle:
            return "Ready"
        case .syncing:
            return "Syncing..."
        case .completed:
            return "Synced"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
    
    var isError: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

// MARK: - CloudKit Summary Record

struct CloudKitSummaryRecord {
    static let recordType = "CD_EnhancedSummary"
    
    // CloudKit record fields
    static let recordingIdField = "recordingId"
    static let transcriptIdField = "transcriptId"
    static let recordingURLField = "recordingURL"
    static let recordingNameField = "recordingName"
    static let recordingDateField = "recordingDate"
    static let summaryField = "summary"
    static let tasksField = "tasks"
    static let remindersField = "reminders"
    static let titlesField = "titles"
    static let contentTypeField = "contentType"
    static let aiMethodField = "aiMethod"
    static let generatedAtField = "generatedAt"
    static let versionField = "version"
    static let wordCountField = "wordCount"
    static let originalLengthField = "originalLength"
    static let compressionRatioField = "compressionRatio"
    static let confidenceField = "confidence"
    static let processingTimeField = "processingTime"
    static let deviceIdentifierField = "deviceIdentifier"
    static let lastModifiedField = "lastModified"
}

// MARK: - Conflict Resolution Strategy

enum ConflictResolutionStrategy {
    case newerWins          // Use the record with the most recent lastModified date
    case deviceWins         // Always prefer the local device's version
    case cloudWins          // Always prefer the cloud version
    case manual             // Present conflict to user for manual resolution
}

// MARK: - Sync Conflict

struct SyncConflict {
    let summaryId: UUID
    let localSummary: EnhancedSummaryData
    let cloudSummary: EnhancedSummaryData
    let conflictType: ConflictType
    
    enum ConflictType {
        case contentMismatch    // Different content for same recording
        case timestampMismatch  // Different modification times
        case deviceMismatch     // Modified on different devices
    }
}

// MARK: - Network Status

enum NetworkStatus {
    case available
    case unavailable
    case limited
    
    var canSync: Bool {
        switch self {
        case .available:
            return true
        case .unavailable, .limited:
            return false
        }
    }
}

// MARK: - iCloud Storage Manager

@MainActor
class iCloudStorageManager: ObservableObject {
    
    // Preview-safe instance for SwiftUI previews
    static let preview: iCloudStorageManager = {
        let manager = iCloudStorageManager()
        manager.isEnabled = false
        manager.syncStatus = .idle
        manager.networkStatus = .available
        return manager
    }()
    
    // MARK: - Properties
    
    @Published var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "iCloudSyncEnabled")
            if isEnabled {
                Task {
                    await enableiCloudSync()
                }
            } else {
                Task {
                    await disableiCloudSync()
                }
            }
        }
    }
    
    // MARK: - Sync Control Properties
    
    /// Controls whether to perform full sync on app startup (should only be true for new installs or user request)
    @Published var shouldPerformFullSyncOnStartup: Bool = false {
        didSet {
            UserDefaults.standard.set(shouldPerformFullSyncOnStartup, forKey: "shouldPerformFullSyncOnStartup")
        }
    }
    
    /// Tracks if this is a first install that might need iCloud data download
    private var isFirstInstall: Bool {
        return !UserDefaults.standard.bool(forKey: "hasCompletedInitialSetup")
    }
    
    /// Controls automatic sync behavior
    enum AutoSyncMode: String, CaseIterable {
        case disabled = "disabled"
        case changesOnly = "changesOnly"  // Only sync when summaries are modified (default)
        case periodic = "periodic"        // Sync all summaries periodically (legacy behavior)
        
        var description: String {
            switch self {
            case .disabled: return "Disabled"
            case .changesOnly: return "Changes Only"
            case .periodic: return "Full Periodic Sync"
            }
        }
    }
    
    /// Current auto-sync mode
    @Published var autoSyncMode: AutoSyncMode = .changesOnly {
        didSet {
            UserDefaults.standard.set(autoSyncMode.rawValue, forKey: "autoSyncMode")
        }
    }
    
    @Published var syncStatus: SyncStatus = .idle
    @Published var networkStatus: NetworkStatus = .available
    @Published var pendingSyncCount: Int = 0
    @Published var lastSyncDate: Date?
    @Published var pendingConflicts: [SyncConflict] = []
    
    // MARK: - Sync State Management
    
    /// Tracks which summaries are currently being synced to prevent duplicate syncs
    private var syncingSummaries: Set<UUID> = []
    
    /// Tracks recently synced summaries to prevent rapid re-syncing
    private var recentlySyncedSummaries: [UUID: Date] = [:]
    
    /// Minimum time between syncing the same summary (5 minutes)
    private let syncCooldownInterval: TimeInterval = 300
    
    /// Debounce timer for batch syncing
    private var syncDebounceTimer: Timer?
    
    /// Queue of summaries waiting to be synced
    private var pendingSyncQueue: [EnhancedSummaryData] = []
    
    /// Maximum number of summaries to sync in a single batch
    private let maxBatchSize = 10
    
    /// Minimum delay between batch syncs (30 seconds)
    private let batchSyncDelay: TimeInterval = 30
    
    // MARK: - Private Properties
    
    private var container: CKContainer?
    private var database: CKDatabase?
    private let deviceIdentifier: String
    private var syncTimer: Timer?
    private var networkMonitor: NetworkMonitor?
    private var isInitialized = false
    private let performanceOptimizer = PerformanceOptimizer.shared
    
    // Configuration
    private let conflictResolutionStrategy: ConflictResolutionStrategy = .newerWins
    private let maxRetryAttempts = 3
    private let retryDelay: TimeInterval = 2.0
    
    // Error tracking
    @Published var lastError: String?
    
    init() {
        self.deviceIdentifier = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        
        // Load saved settings
        self.isEnabled = UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
        self.shouldPerformFullSyncOnStartup = UserDefaults.standard.bool(forKey: "shouldPerformFullSyncOnStartup")
        
        // Load auto-sync mode (default to changesOnly for existing users)
        if let autoSyncModeString = UserDefaults.standard.string(forKey: "autoSyncMode"),
           let loadedAutoSyncMode = AutoSyncMode(rawValue: autoSyncModeString) {
            self.autoSyncMode = loadedAutoSyncMode
        } else {
            self.autoSyncMode = .changesOnly
        }
        
        // Load last sync date
        if let lastSyncTimestamp = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date {
            self.lastSyncDate = lastSyncTimestamp
        }
        
        // Check if we're in a preview environment
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ||
                       ProcessInfo.processInfo.processName.contains("PreviewShell") ||
                       ProcessInfo.processInfo.arguments.contains("--enable-previews")
        if isPreview {
            return
        }
        
        // Defer CloudKit initialization to avoid crashes during view setup
        Task {
            await initializeCloudKit()
        }
        
        // Enable performance tracking for iCloud operations
        EnhancedLogger.shared.enablePerformanceTracking(true)
    }
    
    private func initializeCloudKit() async {
        guard !isInitialized else { return }
        
        
        // Skip CloudKit initialization in preview environments
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ||
                       ProcessInfo.processInfo.processName.contains("PreviewShell") ||
                       ProcessInfo.processInfo.arguments.contains("--enable-previews")
        if isPreview {
            return
        }
        
        // Initialize CloudKit components safely
        self.container = CKContainer.default()
        self.database = container?.privateCloudDatabase
        
        // Verify CloudKit components were initialized
        guard container != nil, database != nil else {
            let error = NSError(domain: "iCloudStorageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize CloudKit components"])
            EnhancedLogger.shared.logiCloudSyncError("CloudKit Initialization", error: error)
            EnhancedErrorHandler().handleiCloudSyncError(error, context: "CloudKit Setup")
            await updateSyncStatus(.failed("CloudKit initialization failed"))
            return
        }
        
        // Set up network monitoring
        setupNetworkMonitoring()
        
        // Set up periodic sync if enabled
        if isEnabled {
            setupPeriodicSync()
        }
        
        isInitialized = true
        
    }
    
    // MARK: - Public Interface
    
    func enableiCloudSync() async {
        EnhancedLogger.shared.logiCloudSyncStart("Enable iCloud Sync")
        
        // Ensure CloudKit is initialized
        if !isInitialized {
            await initializeCloudKit()
        }
        
        guard let container = container else {
            let error = NSError(domain: "iCloudStorageManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "CloudKit not initialized"])
            EnhancedLogger.shared.logiCloudSyncError("Enable iCloud Sync", error: error)
            EnhancedErrorHandler().handleiCloudSyncError(error, context: "Enable Sync")
            await updateSyncStatus(.failed("CloudKit not initialized"))
            return
        }
        
        do {
            // Check CloudKit availability
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                let error = NSError(domain: "iCloudStorageManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "iCloud account not available"])
                EnhancedLogger.shared.logiCloudSyncError("Enable iCloud Sync", error: error)
                EnhancedErrorHandler().handleiCloudSyncError(error, context: "Enable Sync")
                await updateSyncStatus(.failed("iCloud account not available"))
                return
            }
            
            // Note: userDiscoverability permission is deprecated in iOS 17.0 and not needed for private database operations
            EnhancedLogger.shared.logiCloudSync("CloudKit account available, proceeding with setup", level: .info)
            
            // Set up CloudKit schema if needed
            await setupCloudKitSchema()
            
            // Start periodic sync
            setupPeriodicSync()
            
            // Only perform full sync if explicitly requested or first install
            if shouldPerformFullSyncOnStartup || isFirstInstall {
                print("🔄 Performing initial full sync (first install: \(isFirstInstall), requested: \(shouldPerformFullSyncOnStartup))")
                do {
                    try await performOneTimeFullSync()
                } catch {
                    print("⚠️ Initial full sync failed: \(error)")
                    // Don't fail the entire enablement process
                }
            } else {
            }
            
            await updateSyncStatus(.completed)
            EnhancedLogger.shared.logiCloudSyncComplete("Enable iCloud Sync", itemCount: 0)
            
        } catch {
            EnhancedLogger.shared.logiCloudSyncError("Enable iCloud Sync", error: error)
            EnhancedErrorHandler().handleiCloudSyncError(error, context: "Enable Sync")
            await updateSyncStatus(.failed(error.localizedDescription))
            await MainActor.run {
                self.isEnabled = false
            }
        }
    }
    
    func disableiCloudSync() async {
        print("🔄 Disabling iCloud sync...")
        
        // Stop periodic sync
        syncTimer?.invalidate()
        syncTimer = nil
        
        await updateSyncStatus(.idle)
        print("✅ iCloud sync disabled")
    }
    
    func syncSummary(_ summary: EnhancedSummaryData) async throws {
        guard isEnabled else {
            print("⚠️ iCloud sync is disabled, skipping summary sync")
            return
        }
        
        // Check if this summary is already being synced
        if syncingSummaries.contains(summary.id) {
            print("🔄 Summary already being synced: \(summary.recordingName)")
            return
        }
        
        // Check if this summary was recently synced
        if let lastSync = recentlySyncedSummaries[summary.id],
           Date().timeIntervalSince(lastSync) < syncCooldownInterval {
            let timeSince = Int(Date().timeIntervalSince(lastSync))
            print("⏳ Summary recently synced (\(timeSince)s ago), skipping: \(summary.recordingName)")
            return
        }
        
        // Add to pending queue and schedule batch sync
        pendingSyncQueue.append(summary)
        scheduleBatchSync()
        
        print("📋 Queued summary for batch sync: \(summary.recordingName) (Queue size: \(pendingSyncQueue.count))")
    }
    
    /// Schedules a batch sync operation with debouncing
    private func scheduleBatchSync() {
        // Cancel existing timer
        syncDebounceTimer?.invalidate()
        
        // Schedule new timer
        syncDebounceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task {
                await self?.performBatchSync()
            }
        }
    }
    
    /// Performs batch sync of queued summaries
    private func performBatchSync() async {
        guard !pendingSyncQueue.isEmpty else { return }
        
        // Take up to maxBatchSize summaries from the queue
        let batch = Array(pendingSyncQueue.prefix(maxBatchSize))
        pendingSyncQueue.removeFirst(min(maxBatchSize, pendingSyncQueue.count))
        
        print("🔄 Starting batch sync of \(batch.count) summaries...")
        
        await updateSyncStatus(.syncing)
        await MainActor.run {
            self.pendingSyncCount = batch.count
        }
        
        var syncedCount = 0
        var failedCount = 0
        
        for summary in batch {
            do {
                // Mark as syncing
                syncingSummaries.insert(summary.id)
                
                try await performIndividualSync(summary)
                syncedCount += 1
                
                // Mark as recently synced
                recentlySyncedSummaries[summary.id] = Date()
                
            } catch {
                print("❌ Failed to sync summary \(summary.recordingName): \(error)")
                failedCount += 1
            }
            
            // Remove from syncing set (always execute)
            syncingSummaries.remove(summary.id)
            
            await MainActor.run {
                self.pendingSyncCount = batch.count - syncedCount - failedCount
            }
            
            // Small delay between individual syncs to avoid overwhelming CloudKit
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        if failedCount == 0 {
            await updateSyncStatus(.completed)
            print("✅ Successfully synced batch: \(syncedCount) summaries")
        } else {
            await updateSyncStatus(.failed("Batch: \(syncedCount) synced, \(failedCount) failed"))
            print("⚠️ Batch sync completed with errors: \(syncedCount) synced, \(failedCount) failed")
        }
        
        // Schedule next batch if there are more items
        if !pendingSyncQueue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + batchSyncDelay) {
                Task {
                    await self.performBatchSync()
                }
            }
        }
    }
    
    /// Performs the actual individual sync operation (renamed from syncSummary)
    private func performIndividualSync(_ summary: EnhancedSummaryData) async throws {
        // Ensure CloudKit is initialized
        if !isInitialized {
            await initializeCloudKit()
        }
        
        guard database != nil else {
            throw NSError(domain: "iCloudStorageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "CloudKit not initialized"])
        }
        
        guard networkStatus.canSync else {
            throw NSError(domain: "iCloudStorageManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Network unavailable"])
        }
        
        print("🔄 Syncing summary: \(summary.recordingName)")
        
        var retryCount = 0
        
        while retryCount < maxRetryAttempts {
            do {
                let recordID = CKRecord.ID(recordName: summary.id.uuidString)
                let result = try await handleConflictResolution(for: recordID, with: summary)
                
                // Update last sync date
                await MainActor.run {
                    self.lastSyncDate = Date()
                    UserDefaults.standard.set(self.lastSyncDate, forKey: "lastSyncDate")
                }
                
                print("✅ Successfully synced summary: \(result.recordID)")
                return // Success, exit retry loop
                
            } catch {
                retryCount += 1
                
                // Handle specific CloudKit errors
                if let ckError = error as? CKError {
                    switch ckError.code {
                    case .serverRecordChanged:
                        print("🔄 Server record changed, refetching and retrying (attempt \(retryCount)/\(maxRetryAttempts))")
                        // Don't wait for server changed errors, retry immediately with fresh data
                        continue
                    case .networkFailure, .networkUnavailable, .serviceUnavailable:
                        if retryCount < maxRetryAttempts {
                            print("⚠️ Network error, retrying in \(retryDelay)s (attempt \(retryCount)/\(maxRetryAttempts))")
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            continue
                        }
                    case .unknownItem:
                        // Schema issue, ensure it exists and retry once
                        if retryCount == 1 {
                            print("⚠️ Unknown record type, setting up schema and retrying")
                            await setupCloudKitSchema()
                            continue
                        }
                    default:
                        if ckError.isRetryable && retryCount < maxRetryAttempts {
                            print("⚠️ Retryable CloudKit error, attempt \(retryCount)/\(maxRetryAttempts): \(ckError.localizedDescription)")
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            continue
                        }
                    }
                }
                
                print("❌ Failed to sync summary after \(retryCount) attempts: \(error)")
                throw error
            }
        }
    }
    
    /// Handles CloudKit conflict resolution by always fetching the latest server record
    private func handleConflictResolution(for recordID: CKRecord.ID, with summary: EnhancedSummaryData) async throws -> CKRecord {
        guard let database = database else {
            throw NSError(domain: "iCloudStorageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Database not available"])
        }
        
        // Always fetch the latest record from server to avoid conflicts
        var existingRecord: CKRecord?
        do {
            existingRecord = try await database.record(for: recordID)
            print("📥 Fetched existing record from server for conflict resolution")
        } catch {
            if let ckError = error as? CKError {
                switch ckError.code {
                case .unknownItem:
                    // Record doesn't exist, create new one
                    print("📝 Record doesn't exist, creating new record")
                    let newRecord = try createCloudKitRecord(from: summary)
                    return try await database.save(newRecord)
                case .invalidArguments:
                    // Schema issue, ensure schema exists and try creating new record
                    print("🔧 Schema issue detected, ensuring schema and creating record")
                    await setupCloudKitSchema()
                    let newRecord = try createCloudKitRecord(from: summary)
                    return try await database.save(newRecord)
                default:
                    throw error
                }
            } else {
                throw error
            }
        }
        
        if let existing = existingRecord {
            // Record exists, update it with our local data
            print("🔄 Updating existing record with local changes")
            updateCloudKitRecord(existing, from: summary)
            
            // Save the updated record
            return try await database.save(existing)
        } else {
            // Shouldn't reach here, but create new record as fallback
            print("⚠️ Unexpected state, creating new record")
            let newRecord = try createCloudKitRecord(from: summary)
            return try await database.save(newRecord)
        }
    }
    
    func syncAllSummaries(_ summaries: [EnhancedSummaryData]) async throws {
        guard isEnabled else {
            print("⚠️ iCloud sync is disabled, skipping batch sync")
            return
        }

        await updateSyncStatus(.syncing)
        await MainActor.run {
            self.pendingSyncCount = summaries.count
        }

        print("🔄 Starting batch sync of \(summaries.count) summaries...")

        var syncedCount = 0
        var failedCount = 0

        for summary in summaries {
            do {
                try await syncSummary(summary)
                syncedCount += 1
            } catch {
                print("❌ Failed to sync summary \(summary.recordingName): \(error)")
                failedCount += 1
            }

            await MainActor.run {
                self.pendingSyncCount = summaries.count - syncedCount - failedCount
            }
        }

        if failedCount == 0 {
            await updateSyncStatus(.completed)
            print("✅ Successfully synced all \(syncedCount) summaries")
        } else {
            await updateSyncStatus(.failed("Synced \(syncedCount), failed \(failedCount)"))
            print("⚠️ Batch sync completed with errors: \(syncedCount) synced, \(failedCount) failed")
        }

        await MainActor.run {
            self.pendingSyncCount = 0
        }
    }

    /// Convenience wrapper that loads all locally stored summaries and syncs them
    /// This should only be called manually or during initial setup
    func syncAllSummaries() async throws {
        print("🔄 Manual full sync requested")
        // Load summaries from the local store
        let allSummaries = SummaryManager.shared.enhancedSummaries
        try await syncAllSummaries(allSummaries)
    }
    
    /// Performs a one-time full sync for new installations or user request
    func performOneTimeFullSync() async throws {
        print("🔄 Performing one-time full sync...")
        try await syncAllSummaries()
        
        // Mark that initial setup is complete
        await MainActor.run {
            UserDefaults.standard.set(true, forKey: "hasCompletedInitialSetup")
            self.shouldPerformFullSyncOnStartup = false
        }
    }
    
    /// Checks if the user needs to be prompted for iCloud data download on first install
    func shouldPromptForInitialCloudDownload() -> Bool {
        return isFirstInstall && isEnabled
    }
    
    func deleteSummaryFromiCloud(_ summaryId: UUID) async throws {
        guard isEnabled else { return }
        
        // Ensure CloudKit is initialized
        if !isInitialized {
            await initializeCloudKit()
        }
        
        guard let database = database else {
            throw NSError(domain: "iCloudStorageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "CloudKit not initialized"])
        }
        
        print("🗑️ Deleting summary from iCloud: \(summaryId)")
        
        let recordID = CKRecord.ID(recordName: summaryId.uuidString)
        
        do {
            try await database.deleteRecord(withID: recordID)
            print("✅ Successfully deleted summary from iCloud")
        } catch {
            print("❌ Failed to delete summary from iCloud: \(error)")
            throw error
        }
    }
    
    func fetchSummariesFromiCloud(forRecovery: Bool = false) async throws -> [EnhancedSummaryData] {
        guard forRecovery || isEnabled else {
            print("⚠️ iCloud sync is disabled, returning empty array")
            return []
        }
        
        // Ensure CloudKit is initialized
        if !isInitialized {
            await initializeCloudKit()
        }
        
        guard let database = database else {
            throw NSError(domain: "iCloudStorageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "CloudKit not initialized"])
        }
        
        guard networkStatus.canSync else {
            print("⚠️ Network unavailable, cannot fetch from iCloud")
            throw NSError(domain: "iCloudStorageManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Network unavailable"])
        }
        
        print("📥 Fetching summaries from iCloud...")
        
        let query = CKQuery(recordType: CloudKitSummaryRecord.recordType, predicate: NSPredicate(value: true))
        // Note: Removed sortDescriptors to avoid CloudKit queryable field issues
        // CloudKit fields need to be explicitly marked as sortable in the schema
        
        var retryCount = 0
        
        while retryCount < maxRetryAttempts {
            do {
                let (matchResults, _) = try await database.records(matching: query)
                
                var summaries: [EnhancedSummaryData] = []
                
                for (_, result) in matchResults {
                    switch result {
                    case .success(let record):
                        if let summary = try? createEnhancedSummaryData(from: record) {
                            summaries.append(summary)
                        }
                    case .failure(let error):
                        print("❌ Failed to process record: \(error)")
                    }
                }
                
                print("✅ Fetched \(summaries.count) summaries from iCloud")
                return summaries
                
            } catch {
                retryCount += 1

                if let ckError = error as? CKError {
                    if ckError.code == .unknownItem || ckError.localizedDescription.contains("record type") {
                        await setupCloudKitSchema()
                        return []
                    } else if ckError.isRetryable && retryCount < maxRetryAttempts {
                        print("⚠️ Retryable error fetching from iCloud, attempt \(retryCount)/\(maxRetryAttempts): \(ckError.localizedDescription)")
                        try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                        continue
                    } else {
                        print("❌ Failed to fetch summaries from iCloud after \(retryCount) attempts: \(error)")
                        throw error
                    }
                } else {
                    print("❌ Failed to fetch summaries from iCloud after \(retryCount) attempts: \(error)")
                    throw error
                }
            }
        }
        
        // This should never be reached, but just in case
        throw NSError(domain: "iCloudStorageManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Max retry attempts exceeded"])
    }
    
    func performBidirectionalSync(localSummaries: [EnhancedSummaryData]) async throws {
        guard isEnabled && networkStatus.canSync else {
            print("⚠️ Cannot perform bidirectional sync - disabled or network unavailable")
            return
        }
        
        await updateSyncStatus(.syncing)
        
        do {
            // Fetch all summaries from iCloud
            let cloudSummaries = try await fetchSummariesFromiCloud()
            
            // Create lookup dictionaries
            let localLookup = Dictionary(uniqueKeysWithValues: localSummaries.map { ($0.id, $0) })
            let cloudLookup = Dictionary(uniqueKeysWithValues: cloudSummaries.map { ($0.id, $0) })
            
            var syncedCount = 0
            var conflictCount = 0
            
            // Process local summaries
            for localSummary in localSummaries {
                if let cloudSummary = cloudLookup[localSummary.id] {
                    // Summary exists in both - check for conflicts
                    if localSummary.summary != cloudSummary.summary ||
                       localSummary.tasks != cloudSummary.tasks ||
                       localSummary.reminders != cloudSummary.reminders {
                        
                        if let resolved = try await handleSyncConflict(localSummary: localSummary, cloudRecord: try createCloudKitRecord(from: cloudSummary)) {
                            try await syncSummary(resolved)
                            syncedCount += 1
                        } else {
                            conflictCount += 1
                        }
                    }
                } else {
                    // Local summary not in cloud - upload it
                    try await syncSummary(localSummary)
                    syncedCount += 1
                }
            }
            
            // Process cloud-only summaries (download them)
            for cloudSummary in cloudSummaries {
                if localLookup[cloudSummary.id] == nil {
                    // Cloud summary not local - would need to notify SummaryManager
                    // For now, just log it
                    print("📥 Found cloud-only summary: \(cloudSummary.recordingName)")
                }
            }
            
            if conflictCount == 0 {
                await updateSyncStatus(.completed)
                print("✅ Bidirectional sync completed: \(syncedCount) synced")
            } else {
                await updateSyncStatus(.failed("Synced \(syncedCount), \(conflictCount) conflicts pending"))
                print("⚠️ Bidirectional sync completed with conflicts: \(syncedCount) synced, \(conflictCount) conflicts")
            }
            
        } catch {
            await updateSyncStatus(.failed(error.localizedDescription))
            throw error
        }
    }
    
    func getSyncStatus() -> SyncStatus {
        return syncStatus
    }
    
    // MARK: - Cloud Management Functions
    
    
    /// Downloads all summaries from iCloud and imports them locally
    func downloadSummariesFromCloud(appCoordinator: AppDataCoordinator, forRecovery: Bool = false) async throws -> Int {
        guard forRecovery || isEnabled, let _ = database else {
            throw NSError(domain: "iCloudStorageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "iCloud sync not enabled or CloudKit not initialized"])
        }
        
        await updateSyncStatus(.syncing)
        
        do {
            print("🔍 Starting download process (forRecovery: \(forRecovery))")

            // Use the recovery-aware fetch method if this is for recovery, otherwise use the comprehensive method
            let cloudSummaries = forRecovery ?
                try await fetchSummariesFromiCloud(forRecovery: true) :
                try await fetchAllSummariesUsingRecordOperation(appCoordinator: appCoordinator)

            print("📊 Found \(cloudSummaries.count) summaries in iCloud")

            // Get local summary IDs from Core Data for comparison
            let localSummaries = appCoordinator.coreDataManager.getAllSummaries()
            let localSummaryIds = Set(localSummaries.compactMap { $0.id })

            print("📊 Found \(localSummaries.count) local summaries")

            // Find cloud-only summaries
            let cloudOnlySummaries = cloudSummaries.filter { !localSummaryIds.contains($0.id) }

            print("📥 Found \(cloudOnlySummaries.count) cloud summaries to download")
            
            var downloadedCount = 0
            for cloudSummary in cloudOnlySummaries {
                do {
                    // Try to create Core Data summary entry
                    try await createCoreDataSummary(from: cloudSummary, appCoordinator: appCoordinator)
                    downloadedCount += 1
                    print("📥 Downloaded cloud summary: \(cloudSummary.recordingName)")
                } catch {
                    print("❌ Failed to create Core Data entry for cloud summary \(cloudSummary.recordingName): \(error)")
                }
            }
            
            await updateSyncStatus(.completed)
            print("✅ Downloaded \(downloadedCount) summaries from iCloud")
            return downloadedCount
            
        } catch {
            await updateSyncStatus(.failed(error.localizedDescription))
            throw error
        }
    }
    
    func fetchAllSummariesFromCloud() async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }
        
        let query = CKQuery(recordType: CloudKitSummaryRecord.recordType, predicate: NSPredicate(value: true))
        let (matchResults, _) = try await database.records(matching: query)
        
        var summaries: [EnhancedSummaryData] = []
        
        for (_, result) in matchResults {
            switch result {
            case .success(let record):
                do {
                    let summary = try createEnhancedSummaryData(from: record)
                    summaries.append(summary)
                } catch {
                    print("❌ Failed to decode cloud summary: \(error)")
                }
            case .failure(let error):
                print("❌ Failed to fetch cloud summary record: \(error)")
            }
        }
        
        return summaries
    }
    
    
    /// Uses record discovery approach to avoid schema requirements entirely
    /// 
    /// CURRENT STATUS: CloudKit schema has 'recordName' field not marked as queryable,
    /// which prevents all query-based approaches from working. This method uses
    /// alternative approaches to find records:
    /// 
    /// 1. UUID Scanning + Change Tracking: Fetches records by known UUIDs + discovers cloud-only records
    /// 2. Zone Change Operations: Uses CKFetchRecordZoneChangesOperation to find all records
    /// 3. Brute Force Discovery: Attempts various discovery methods
    /// 
    /// The UUID + change tracking approach should find both local records and cloud-only records.
    func fetchAllSummariesUsingRecordOperation(appCoordinator: AppDataCoordinator? = nil) async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }
        
        print("🔍 Fetching all summaries using record discovery (schema-safe)")
        print("🔍 Database: \(database.databaseScope == .public ? "Public" : "Private")")
        print("🔍 Record type: \(CloudKitSummaryRecord.recordType)")
        
        var allSummaries: [EnhancedSummaryData] = []
        
        // Approach 1: UUID scanning + change tracking (most comprehensive)
        if let appCoordinator = appCoordinator {
            do {
                print("🔍 Attempting UUID scanning + change tracking approach...")
                let summaries = try await fetchSummariesByUUIDScanning(appCoordinator: appCoordinator)
                allSummaries.append(contentsOf: summaries)
                print("✅ UUID scanning + change tracking found \(summaries.count) summaries")
            } catch {
                print("⚠️ UUID scanning + change tracking failed: \(error)")
            }
        } else {
            print("⚠️ No appCoordinator provided, trying direct zone changes approach...")
        }
        
        // Approach 2: Brute force record scanning (works when change tracking fails)
        if allSummaries.isEmpty {
            do {
                print("🔍 Attempting brute force record scanning...")
                let scannedSummaries = try await bruteForceRecordDiscovery()
                allSummaries.append(contentsOf: scannedSummaries)
                print("✅ Brute force scanning found \(scannedSummaries.count) summaries")
            } catch {
                print("⚠️ Brute force scanning failed: \(error)")
            }
        }
        
        // Approach 2b: Direct zone changes (works without appCoordinator)
        if allSummaries.isEmpty {
            do {
                print("🔍 Attempting direct zone changes approach...")
                let zoneSummaries = try await fetchRecordsUsingZoneChanges()
                allSummaries.append(contentsOf: zoneSummaries)
                print("✅ Direct zone changes found \(zoneSummaries.count) summaries")
            } catch {
                print("⚠️ Direct zone changes failed: \(error)")
            }
        }
        
        // Approach 3: Database changes + zone scanning (fallback)
        if allSummaries.isEmpty {
            do {
                print("🔍 Attempting database changes + zone scanning...")
                let changesOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: nil)
                changesOperation.database = database
                
                var recordZoneIDs: [CKRecordZone.ID] = []
                changesOperation.recordZoneWithIDChangedBlock = { zoneID in
                    recordZoneIDs.append(zoneID)
                }
                
                _ = try await withCheckedThrowingContinuation { continuation in
                    changesOperation.fetchDatabaseChangesResultBlock = { result in
                        continuation.resume(with: result)
                    }
                    database.add(changesOperation)
                }
                
                // If no zones found, add the default zone
                if recordZoneIDs.isEmpty {
                    recordZoneIDs.append(CKRecordZone.default().zoneID)
                }
                
                // Use zone changes operation instead of queries
                for zoneID in recordZoneIDs {
                    do {
                        let zoneRecords = try await fetchRecordsFromZoneUsingChanges(zoneID)
                        allSummaries.append(contentsOf: zoneRecords)
                    } catch {
                        print("⚠️ Failed to fetch from zone \(zoneID) using changes: \(error)")
                    }
                }
                
                print("✅ Database changes + zone scanning found \(allSummaries.count) summaries")
                
            } catch {
                print("⚠️ Database changes + zone scanning failed: \(error)")
            }
        }
        
        // Remove duplicates based on ID
        let uniqueSummaries = Dictionary(grouping: allSummaries, by: { $0.id })
            .compactMapValues { $0.first }
            .values
            .map { $0 }
        
        print("🔍 Total unique summaries found: \(uniqueSummaries.count) (removed \(allSummaries.count - uniqueSummaries.count) duplicates)")
        
        return Array(uniqueSummaries)
    }
    
    /// Fetches summaries by scanning for common UUID patterns in record names
    /// This bypasses the need for queryable fields
    private func fetchSummariesByUUIDScanning(appCoordinator: AppDataCoordinator) async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }
        
        print("🔍 Scanning for summaries using UUID pattern matching...")
        
        // Get all summaries from Core Data to get their IDs
        let localSummaries = appCoordinator.coreDataManager.getAllSummaries()
        print("📱 Found \(localSummaries.count) local summaries to check")
        
        var foundSummaries: [EnhancedSummaryData] = []
        var checkedUUIDs: Set<String> = Set()
        
        // Phase 1: Try to fetch each local summary's CloudKit record
        for (index, localSummary) in localSummaries.enumerated() {
            guard let summaryId = localSummary.id else {
                print("⚠️ Local summary \(index + 1) has no ID, skipping")
                continue
            }
            
            let uuidString = summaryId.uuidString
            print("🔍 Checking local summary \(index + 1)/\(localSummaries.count): \(uuidString)")
            checkedUUIDs.insert(uuidString)
            
            do {
                let recordID = CKRecord.ID(recordName: uuidString)
                print("🔍 Attempting to fetch CloudKit record: \(recordID.recordName)")
                
                let record = try await database.record(for: recordID)
                print("✅ Successfully fetched CloudKit record: \(record.recordID)")
                
                // Verify this is actually a summary record before processing
                guard record.recordType == CloudKitSummaryRecord.recordType else {
                    print("⚠️ Found non-summary record for local summary: \(summaryId) (type: \(record.recordType))")
                    continue
                }
                
                // Convert to EnhancedSummaryData
                let summary = try createEnhancedSummaryData(from: record)
                foundSummaries.append(summary)
                print("✅ Successfully converted CloudKit record for local summary: \(summary.recordingName)")
                
            } catch {
                // This summary doesn't exist in CloudKit, which is fine
                print("ℹ️ No CloudKit record found for local summary: \(uuidString) - \(error.localizedDescription)")
            }
        }
        
        // Phase 2: Try to find cloud-only summaries using change tracking
        // This will help us discover CloudKit records that don't have local counterparts
        print("🔍 Phase 2: Looking for cloud-only summaries using change tracking...")
        
        do {
            let zoneChangesOperation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [CKRecordZone.default().zoneID], 
                configurationsByRecordZoneID: nil
            )
            
            var cloudOnlyRecords: [CKRecord] = []
            
            zoneChangesOperation.recordWasChangedBlock = { recordID, result in
                switch result {
                case .success(let record):
                    // Only process our summary records that we haven't already checked
                    if record.recordType == CloudKitSummaryRecord.recordType && 
                       !checkedUUIDs.contains(record.recordID.recordName) {
                        cloudOnlyRecords.append(record)
                        print("🆕 Found potential cloud-only record: \(record.recordID.recordName)")
                    }
                case .failure(let error):
                    print("⚠️ Failed to fetch cloud-only record \(recordID): \(error)")
                }
            }
            
            _ = try await withCheckedThrowingContinuation { continuation in
                zoneChangesOperation.fetchRecordZoneChangesResultBlock = { result in
                    continuation.resume(with: result)
                }
                database.add(zoneChangesOperation)
            }
            
            // Convert the cloud-only records
            for record in cloudOnlyRecords {
                do {
                    let summary = try createEnhancedSummaryData(from: record)
                    foundSummaries.append(summary)
                    print("✅ Successfully converted cloud-only record: \(summary.recordingName)")
                } catch {
                    print("❌ Failed to convert cloud-only record \(record.recordID): \(error)")
                }
            }
            
            print("🔍 Change tracking found \(cloudOnlyRecords.count) cloud-only records")
            
        } catch {
            print("⚠️ Change tracking failed: \(error)")
        }
        
        print("🔍 UUID scanning + change tracking found \(foundSummaries.count) total summaries")
        return foundSummaries
    }
    
    // Note: UUID pattern generation was removed to prevent integer overflow crashes
    // The current approach focuses on finding CloudKit records that correspond to local summaries
    
    /// Brute force record discovery - tries various approaches to find CloudKit records
    /// This method attempts to discover records when normal change tracking fails
    private func bruteForceRecordDiscovery() async throws -> [EnhancedSummaryData] {
        guard database != nil else { return [] }
        
        print("🔍 Starting brute force record discovery...")
        var foundSummaries: [EnhancedSummaryData] = []
        
        // Removed approach with hardcoded record IDs - not scalable or maintainable
        
        // Approach 2: Try with CKFetchRecordZoneChangesOperation but with specific configuration
        do {
            print("🔍 Trying configured zone changes...")
            let summaries = try await fetchRecordsWithSpecificConfiguration()
            foundSummaries.append(contentsOf: summaries)
        } catch {
            print("⚠️ Configured zone changes failed: \(error)")
        }
        
        print("🔍 Brute force discovery found \(foundSummaries.count) summaries")
        return foundSummaries
    }
    
    /// Fetches records using known IDs that were observed in sync operations
    
    /// Fetches records with specific zone configuration
    private func fetchRecordsWithSpecificConfiguration() async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }
        
        print("🔍 Using specific configuration for zone changes...")
        
        // Try with a specific configuration that might work better
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = nil  // Get all records
        configuration.resultsLimit = 1000  // Set a reasonable limit
        configuration.desiredKeys = nil  // Get all keys
        
        let configsByZoneID = [CKRecordZone.default().zoneID: configuration]
        
        let zoneChangesOperation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [CKRecordZone.default().zoneID], 
            configurationsByRecordZoneID: configsByZoneID
        )
        
        var foundRecords: [CKRecord] = []
        
        zoneChangesOperation.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record):
                if record.recordType == CloudKitSummaryRecord.recordType {
                    foundRecords.append(record)
                    print("📝 Configured fetch found record: \(record.recordID.recordName)")
                }
            case .failure(let error):
                print("⚠️ Failed to fetch record \(recordID) with configuration: \(error)")
            }
        }
        
        _ = try await withCheckedThrowingContinuation { continuation in
            zoneChangesOperation.fetchRecordZoneChangesResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(zoneChangesOperation)
        }
        
        // Convert records to summaries
        var summaries: [EnhancedSummaryData] = []
        for record in foundRecords {
            do {
                let summary = try createEnhancedSummaryData(from: record)
                summaries.append(summary)
            } catch {
                print("❌ Failed to convert configured record \(record.recordID): \(error)")
            }
        }
        
        return summaries
    }
    
    /// Fetches records using direct zone changes operation (works without appCoordinator)
    private func fetchRecordsUsingZoneChanges() async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }
        
        print("🔍 Using direct zone changes to find all records...")
        
        let zoneChangesOperation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [CKRecordZone.default().zoneID], 
            configurationsByRecordZoneID: nil
        )
        
        var foundRecords: [CKRecord] = []
        
        zoneChangesOperation.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record):
                if record.recordType == CloudKitSummaryRecord.recordType {
                    foundRecords.append(record)
                    print("📝 Found record: \(record.recordID.recordName)")
                }
            case .failure(let error):
                print("⚠️ Failed to fetch record \(recordID): \(error)")
            }
        }
        
        _ = try await withCheckedThrowingContinuation { continuation in
            zoneChangesOperation.fetchRecordZoneChangesResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(zoneChangesOperation)
        }
        
        // Convert records to summaries
        var summaries: [EnhancedSummaryData] = []
        for record in foundRecords {
            do {
                let summary = try createEnhancedSummaryData(from: record)
                summaries.append(summary)
            } catch {
                print("❌ Failed to convert record \(record.recordID): \(error)")
            }
        }
        
        print("✅ Direct zone changes found \(summaries.count) summaries")
        return summaries
    }
    
    /// Fetches records from a specific zone using zone changes operation
    private func fetchRecordsFromZoneUsingChanges(_ zoneID: CKRecordZone.ID) async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }
        
        print("🔍 Fetching records from zone \(zoneID) using changes operation...")
        
        let zoneChangesOperation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID], 
            configurationsByRecordZoneID: nil
        )
        
        var foundRecords: [CKRecord] = []
        
        zoneChangesOperation.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record):
                if record.recordType == CloudKitSummaryRecord.recordType {
                    foundRecords.append(record)
                    print("📝 Found record in zone \(zoneID): \(record.recordID.recordName)")
                }
            case .failure(let error):
                print("⚠️ Failed to fetch record \(recordID) in zone \(zoneID): \(error)")
            }
        }
        
        _ = try await withCheckedThrowingContinuation { continuation in
            zoneChangesOperation.fetchRecordZoneChangesResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(zoneChangesOperation)
        }
        
        // Convert records to summaries
        var summaries: [EnhancedSummaryData] = []
        for record in foundRecords {
            do {
                let summary = try createEnhancedSummaryData(from: record)
                summaries.append(summary)
            } catch {
                print("❌ Failed to convert record \(record.recordID): \(error)")
            }
        }
        
        print("✅ Zone changes found \(summaries.count) summaries in zone \(zoneID)")
        return summaries
    }
    
    /// Fetches records from a zone by scanning for existing records
    /// This bypasses the need for queryable fields
    private func fetchRecordsFromZoneByScanning(_ zoneID: CKRecordZone.ID) async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }
        
        print("🔍 Scanning zone \(zoneID) for existing records...")
        
        var foundRecords: [CKRecord] = []
        
        // Try to fetch records by attempting to access them with known patterns
        // This is a brute-force approach but should work when CloudKit queries fail
        
        // First, try to fetch any records that might exist in this zone
        // We'll use a very simple predicate that should work
        do {
            let query = CKQuery(recordType: CloudKitSummaryRecord.recordType, predicate: NSPredicate(value: true))
            
            // Try with a very small limit first
            let (matchResults, _) = try await database.records(matching: query, inZoneWith: zoneID, desiredKeys: nil, resultsLimit: 1)
            
            for (_, result) in matchResults {
                switch result {
                case .success(let record):
                    foundRecords.append(record)
                case .failure(let error):
                    print("⚠️ Record fetch error: \(error)")
                }
            }
            
        } catch {
            print("⚠️ Zone query failed: \(error)")
        }
        
        // If we found some records, try to fetch more with a larger limit
        if !foundRecords.isEmpty {
            do {
                let query = CKQuery(recordType: CloudKitSummaryRecord.recordType, predicate: NSPredicate(value: true))
                let (matchResults, _) = try await database.records(matching: query, inZoneWith: zoneID, desiredKeys: nil, resultsLimit: 1000)
                
                foundRecords.removeAll()
                for (_, result) in matchResults {
                    switch result {
                    case .success(let record):
                        foundRecords.append(record)
                    case .failure(let error):
                        print("⚠️ Record fetch error: \(error)")
                    }
                }
                
            } catch {
                print("⚠️ Extended zone query failed: \(error)")
            }
        }
        
        print("📥 Found \(foundRecords.count) records in zone \(zoneID)")
        
        // Convert records to summaries
        var summaries: [EnhancedSummaryData] = []
        for record in foundRecords {
            do {
                let summary = try createEnhancedSummaryData(from: record)
                summaries.append(summary)
            } catch {
                print("❌ Failed to decode record \(record.recordID): \(error)")
            }
        }
        
        return summaries
    }
    
    /// Creates a Core Data summary entry from cloud summary data
    private func createCoreDataSummary(from cloudSummary: EnhancedSummaryData, appCoordinator: AppDataCoordinator) async throws {
        // First, try to link to existing local recording/transcript if they exist
        if let recordingId = cloudSummary.recordingId,
           let transcriptId = cloudSummary.transcriptId,
           appCoordinator.coreDataManager.getRecording(id: recordingId) != nil,
           appCoordinator.coreDataManager.getTranscript(for: recordingId) != nil {
            
            // Full linking possible - use the workflow manager
            let summaryId = appCoordinator.addSummary(
                for: recordingId,
                transcriptId: transcriptId,
                summary: cloudSummary.summary,
                tasks: cloudSummary.tasks,
                reminders: cloudSummary.reminders,
                titles: cloudSummary.titles,
                contentType: cloudSummary.contentType,
                aiEngine: cloudSummary.aiEngine,
                aiModel: cloudSummary.aiModel,
                originalLength: cloudSummary.originalLength,
                processingTime: cloudSummary.processingTime
            )
            
            if summaryId != nil {
                print("✅ Created linked Core Data entry for cloud summary: \(cloudSummary.recordingName)")
            }
        } else {
            // Create orphaned summary entry (similar to "summary-only recordings")
            print("📥 Creating orphaned Core Data summary entry (no local recording/transcript): \(cloudSummary.recordingName)")
            try await createOrphanedSummaryEntry(cloudSummary, appCoordinator: appCoordinator)
        }
        
        // Also add to SummaryManager for UI compatibility (Core Data is source of truth for persistence)
        await MainActor.run {
            SummaryManager.shared.enhancedSummaries.append(cloudSummary)
        }
    }
    
    /// Creates an orphaned summary entry in Core Data (without recording/transcript links)
    private func createOrphanedSummaryEntry(_ cloudSummary: EnhancedSummaryData, appCoordinator: AppDataCoordinator) async throws {
        let context = PersistenceController.shared.container.viewContext
        
        // Create the Core Data SummaryEntry
        let summaryEntry = SummaryEntry(context: context)
        summaryEntry.id = cloudSummary.id
        summaryEntry.recordingId = cloudSummary.recordingId
        summaryEntry.transcriptId = cloudSummary.transcriptId
        summaryEntry.generatedAt = cloudSummary.generatedAt
        summaryEntry.aiMethod = SummaryMetadataCodec.encode(
            aiEngine: cloudSummary.aiEngine,
            aiModel: cloudSummary.aiModel
        )
        summaryEntry.processingTime = cloudSummary.processingTime
        summaryEntry.confidence = cloudSummary.confidence
        summaryEntry.summary = cloudSummary.summary
        summaryEntry.contentType = cloudSummary.contentType.rawValue
        summaryEntry.wordCount = Int32(cloudSummary.wordCount)
        summaryEntry.originalLength = Int32(cloudSummary.originalLength)
        summaryEntry.compressionRatio = cloudSummary.compressionRatio
        summaryEntry.version = Int32(cloudSummary.version)
        
        // Store structured data as JSON
        if let titlesData = try? JSONEncoder().encode(cloudSummary.titles),
           let titlesString = String(data: titlesData, encoding: .utf8) {
            summaryEntry.titles = titlesString
        }
        if let tasksData = try? JSONEncoder().encode(cloudSummary.tasks),
           let tasksString = String(data: tasksData, encoding: .utf8) {
            summaryEntry.tasks = tasksString
        }
        if let remindersData = try? JSONEncoder().encode(cloudSummary.reminders),
           let remindersString = String(data: remindersData, encoding: .utf8) {
            summaryEntry.reminders = remindersString
        }
        
        // Create a "summary-only" recording entry to maintain the pattern
        let recordingEntry = RecordingEntry(context: context)
        recordingEntry.id = cloudSummary.recordingId ?? UUID()
        recordingEntry.recordingName = cloudSummary.recordingName
        recordingEntry.recordingDate = cloudSummary.recordingDate
        recordingEntry.recordingURL = nil // No URL since there's no local audio file
        recordingEntry.duration = 0 // Unknown duration
        recordingEntry.fileSize = 0
        recordingEntry.summaryId = cloudSummary.id
        recordingEntry.summaryStatus = ProcessingStatus.completed.rawValue
        recordingEntry.lastModified = Date()
        
        // Link them together
        summaryEntry.recording = recordingEntry
        recordingEntry.summary = summaryEntry
        
        // Note: transcript remains nil since we don't have local transcript
        
        // Save to Core Data
        try context.save()
        
        print("✅ Created orphaned Core Data summary entry: \(cloudSummary.recordingName)")
    }
    
    // MARK: - Conflict Resolution Methods
    
    func resolveConflict(_ conflict: SyncConflict, useLocal: Bool) async throws {
        let resolvedSummary = useLocal ? conflict.localSummary : conflict.cloudSummary
        
        // Remove from pending conflicts
        await MainActor.run {
            self.pendingConflicts.removeAll { $0.summaryId == conflict.summaryId }
        }
        
        // Sync the resolved version
        try await syncSummary(resolvedSummary)
    }
    
    private func handleSyncConflict(localSummary: EnhancedSummaryData, cloudRecord: CKRecord) async throws -> EnhancedSummaryData? {
        let cloudSummary = try createEnhancedSummaryData(from: cloudRecord)
        
        // Check if there's actually a conflict
        if localSummary.summary == cloudSummary.summary &&
           localSummary.tasks == cloudSummary.tasks &&
           localSummary.reminders == cloudSummary.reminders {
            // No real conflict, just timestamp differences
            return localSummary
        }
        
        // Determine conflict type
        let conflictType: SyncConflict.ConflictType
        if localSummary.summary != cloudSummary.summary {
            conflictType = .contentMismatch
        } else if localSummary.generatedAt != cloudSummary.generatedAt {
            conflictType = .timestampMismatch
        } else {
            conflictType = .deviceMismatch
        }
        
        let conflict = SyncConflict(
            summaryId: localSummary.id,
            localSummary: localSummary,
            cloudSummary: cloudSummary,
            conflictType: conflictType
        )
        
        // Apply conflict resolution strategy
        switch conflictResolutionStrategy {
        case .newerWins:
            return localSummary.generatedAt > cloudSummary.generatedAt ? localSummary : cloudSummary
            
        case .deviceWins:
            return localSummary
            
        case .cloudWins:
            return cloudSummary
            
        case .manual:
            // Add to pending conflicts for user resolution
            await MainActor.run {
                self.pendingConflicts.append(conflict)
            }
            return nil
        }
    }
    
    // MARK: - Network Monitoring
    
    private func setupNetworkMonitoring() {
        // Skip network monitoring in preview environments
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ||
                       ProcessInfo.processInfo.processName.contains("PreviewShell") ||
                       ProcessInfo.processInfo.arguments.contains("--enable-previews")
        
        if isPreview {
            networkStatus = .available
            return
        }
        
        networkMonitor = NetworkMonitor { [weak self] status in
            Task { @MainActor in
                self?.networkStatus = status
                
                // Resume sync when network becomes available
                if status.canSync && self?.isEnabled == true {
                    await self?.performPeriodicSync()
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func updateSyncStatus(_ status: SyncStatus) async {
        await MainActor.run {
            self.syncStatus = status
            
            if case .failed(let error) = status {
                self.lastError = error
            } else {
                self.lastError = nil
            }
        }
    }
    
    private func setupPeriodicSync() {
        syncTimer?.invalidate()
        
        // Calculate adaptive sync interval based on battery and network conditions
        let syncInterval = calculateAdaptiveSyncInterval()
        
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { _ in
            Task {
                await self.performPeriodicSync()
            }
        }
        
    }
    
    private func calculateAdaptiveSyncInterval() -> TimeInterval {
        // Base interval
        var interval: TimeInterval = 300 // 5 minutes default
        
        // Adjust based on battery state
        if performanceOptimizer.batteryInfo.shouldOptimizeForBattery {
            interval = 600 // 10 minutes for battery optimization
        }
        
        // Adjust based on network status
        switch networkStatus {
        case .limited:
            interval *= 2 // Double interval for limited network
        case .unavailable:
            interval *= 4 // Quadruple interval for unavailable network
        case .available:
            break // Use calculated interval
        }
        
        // Adjust based on memory usage
        if performanceOptimizer.memoryUsage.isHighUsage {
            interval *= 1.5 // Increase interval when memory usage is high
        }
        
        return interval
    }
    
    private func performPeriodicSync() async {
        guard isEnabled else { return }
        
        // Check if we should skip sync based on current conditions
        if shouldSkipSync() {
            return
        }
        
        // Check auto-sync mode
        switch autoSyncMode {
        case .disabled:
            return
        case .changesOnly:
            // Use verbose logging instead of regular print to reduce console noise
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                print("⏭️ Skipping full periodic sync - only syncing changes as they occur")
            }
            // Only sync summaries that have been queued for sync
            if !pendingSyncQueue.isEmpty {
                print("🔄 Syncing queued changes (\(pendingSyncQueue.count) items)...")
                await performBatchSync()
            }
            return
        case .periodic:
            print("🔄 Performing full periodic sync (legacy mode)...")
            // Fall through to existing behavior
        }
        
        do {
            // Perform battery-aware sync (only in periodic mode)
            try await performBatteryAwareSync()
        } catch {
            print("❌ Periodic sync failed: \(error)")
            await updateSyncStatus(.failed(error.localizedDescription))
        }
    }
    
    private func shouldSkipSync() -> Bool {
        // Skip sync if battery is critically low
        if performanceOptimizer.batteryInfo.isLowBattery {
            return true
        }
        
        // Skip sync if network is unavailable
        if !networkStatus.canSync {
            return true
        }
        
        // Skip sync if memory usage is critical
        if performanceOptimizer.memoryUsage.usageLevel == .critical {
            return true
        }
        
        return false
    }
    
    private func performBatteryAwareSync() async throws {
        // Apply battery-aware network settings
        if performanceOptimizer.batteryInfo.shouldOptimizeForBattery {
            print("🔋 Using battery-optimized sync settings")
            
            // Use smaller batch sizes for battery optimization
            let batchSize = 5 // Reduced from default
            try await syncSummariesInBatches(batchSize: batchSize)
        } else {
            // Use standard sync
            try await syncAllSummaries()
        }
    }
    
    private func syncSummariesInBatches(batchSize: Int) async throws {
        // Implementation for batch-based sync to reduce network usage
        print("📦 Syncing summaries in batches of \(batchSize)")
        
        // This would implement batch processing for network efficiency
        // For now, just call the standard sync
        try await syncAllSummaries()
    }
    

    private func setupCloudKitSchema() async {
    
        guard let database = database else { return }
    
        // Create a temporary record to ensure the record type exists.
        let tempID = CKRecord.ID(recordName: UUID().uuidString)
        let tempRecord = CKRecord(recordType: CloudKitSummaryRecord.recordType, recordID: tempID)
    
        // Populate all known fields so the schema matches production usage
        tempRecord[CloudKitSummaryRecord.recordingIdField] = UUID().uuidString
        tempRecord[CloudKitSummaryRecord.transcriptIdField] = UUID().uuidString
        tempRecord[CloudKitSummaryRecord.recordingURLField] = ""
        tempRecord[CloudKitSummaryRecord.recordingNameField] = "SchemaInit"
        tempRecord[CloudKitSummaryRecord.recordingDateField] = Date()
        tempRecord[CloudKitSummaryRecord.summaryField] = ""
        tempRecord[CloudKitSummaryRecord.tasksField] = Data()
        tempRecord[CloudKitSummaryRecord.remindersField] = Data()
        tempRecord[CloudKitSummaryRecord.titlesField] = Data()
        tempRecord[CloudKitSummaryRecord.contentTypeField] = ContentType.general.rawValue
        tempRecord[CloudKitSummaryRecord.aiMethodField] = "schema"
        tempRecord[CloudKitSummaryRecord.generatedAtField] = Date()
        tempRecord[CloudKitSummaryRecord.versionField] = 1
        tempRecord[CloudKitSummaryRecord.wordCountField] = 0
        tempRecord[CloudKitSummaryRecord.originalLengthField] = 0
        tempRecord[CloudKitSummaryRecord.compressionRatioField] = 0.0
        tempRecord[CloudKitSummaryRecord.confidenceField] = 0.0
        tempRecord[CloudKitSummaryRecord.processingTimeField] = 0.0
        tempRecord[CloudKitSummaryRecord.deviceIdentifierField] = deviceIdentifier
        tempRecord[CloudKitSummaryRecord.lastModifiedField] = Date()
    
        do {
            _ = try await database.save(tempRecord)
            try await database.deleteRecord(withID: tempID)
        } catch {
            print("⚠️ Failed to set up CloudKit schema: \(error)")
        }
    }
    
    private func createCloudKitRecord(from summary: EnhancedSummaryData) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: summary.id.uuidString)
        let record = CKRecord(recordType: CloudKitSummaryRecord.recordType, recordID: recordID)
        
        // ID fields for linking
        record[CloudKitSummaryRecord.recordingIdField] = summary.recordingId?.uuidString
        record[CloudKitSummaryRecord.transcriptIdField] = summary.transcriptId?.uuidString
        
        // Basic fields
        record[CloudKitSummaryRecord.recordingURLField] = summary.recordingURL.absoluteString
        record[CloudKitSummaryRecord.recordingNameField] = summary.recordingName
        record[CloudKitSummaryRecord.recordingDateField] = summary.recordingDate
        record[CloudKitSummaryRecord.summaryField] = summary.summary
        record[CloudKitSummaryRecord.contentTypeField] = summary.contentType.rawValue
        record[CloudKitSummaryRecord.aiMethodField] = SummaryMetadataCodec.encode(
            aiEngine: summary.aiEngine,
            aiModel: summary.aiModel
        )
        record[CloudKitSummaryRecord.generatedAtField] = summary.generatedAt
        record[CloudKitSummaryRecord.versionField] = summary.version
        record[CloudKitSummaryRecord.wordCountField] = summary.wordCount
        record[CloudKitSummaryRecord.originalLengthField] = summary.originalLength
        record[CloudKitSummaryRecord.compressionRatioField] = summary.compressionRatio
        record[CloudKitSummaryRecord.confidenceField] = summary.confidence
        record[CloudKitSummaryRecord.processingTimeField] = summary.processingTime
        record[CloudKitSummaryRecord.deviceIdentifierField] = deviceIdentifier
        record[CloudKitSummaryRecord.lastModifiedField] = Date()
        
        // Encode complex objects as Data
        do {
            let tasksData = try JSONEncoder().encode(summary.tasks)
            record[CloudKitSummaryRecord.tasksField] = tasksData
            
            let remindersData = try JSONEncoder().encode(summary.reminders)
            record[CloudKitSummaryRecord.remindersField] = remindersData
            
            let titlesData = try JSONEncoder().encode(summary.titles)
            record[CloudKitSummaryRecord.titlesField] = titlesData
        } catch {
            print("❌ Failed to encode complex objects: \(error)")
            throw error
        }
        
        return record
    }
    
    private func updateCloudKitRecord(_ record: CKRecord, from summary: EnhancedSummaryData) {
        // Update basic fields
        record[CloudKitSummaryRecord.recordingURLField] = summary.recordingURL.absoluteString
        record[CloudKitSummaryRecord.recordingNameField] = summary.recordingName
        record[CloudKitSummaryRecord.recordingDateField] = summary.recordingDate
        record[CloudKitSummaryRecord.summaryField] = summary.summary
        record[CloudKitSummaryRecord.contentTypeField] = summary.contentType.rawValue
        record[CloudKitSummaryRecord.aiMethodField] = SummaryMetadataCodec.encode(
            aiEngine: summary.aiEngine,
            aiModel: summary.aiModel
        )
        record[CloudKitSummaryRecord.generatedAtField] = summary.generatedAt
        record[CloudKitSummaryRecord.versionField] = summary.version
        record[CloudKitSummaryRecord.wordCountField] = summary.wordCount
        record[CloudKitSummaryRecord.originalLengthField] = summary.originalLength
        record[CloudKitSummaryRecord.compressionRatioField] = summary.compressionRatio
        record[CloudKitSummaryRecord.confidenceField] = summary.confidence
        record[CloudKitSummaryRecord.processingTimeField] = summary.processingTime
        record[CloudKitSummaryRecord.deviceIdentifierField] = deviceIdentifier
        record[CloudKitSummaryRecord.lastModifiedField] = Date()
        
        // Encode complex objects as Data
        do {
            let tasksData = try JSONEncoder().encode(summary.tasks)
            record[CloudKitSummaryRecord.tasksField] = tasksData
            
            let remindersData = try JSONEncoder().encode(summary.reminders)
            record[CloudKitSummaryRecord.remindersField] = remindersData
            
            let titlesData = try JSONEncoder().encode(summary.titles)
            record[CloudKitSummaryRecord.titlesField] = titlesData
        } catch {
            print("❌ Failed to encode complex objects during update: \(error)")
        }
    }
    
    private func createEnhancedSummaryData(from record: CKRecord) throws -> EnhancedSummaryData {
        // Extract basic fields
        guard let recordingURLString = record[CloudKitSummaryRecord.recordingURLField] as? String,
              let recordingURL = URL(string: recordingURLString),
              let recordingName = record[CloudKitSummaryRecord.recordingNameField] as? String,
              let recordingDate = record[CloudKitSummaryRecord.recordingDateField] as? Date,
              let summary = record[CloudKitSummaryRecord.summaryField] as? String,
              let contentTypeString = record[CloudKitSummaryRecord.contentTypeField] as? String,
              let contentType = ContentType(rawValue: contentTypeString),
              let aiMethod = record[CloudKitSummaryRecord.aiMethodField] as? String,
              let originalLength = record[CloudKitSummaryRecord.originalLengthField] as? Int else {
            throw NSError(domain: "iCloudStorageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required fields in CloudKit record"])
        }
        
        // Extract IDs with proper UUID conversion
        let recordingId = UUID(uuidString: record.recordID.recordName)
        let transcriptId: UUID? = {
            if let transcriptIdString = record[CloudKitSummaryRecord.transcriptIdField] as? String {
                return UUID(uuidString: transcriptIdString)
            }
            return nil
        }()
        
        // Extract additional metadata fields
        let generatedAt = record[CloudKitSummaryRecord.generatedAtField] as? Date ?? Date()
        let version = record[CloudKitSummaryRecord.versionField] as? Int ?? 1
        let wordCount = record[CloudKitSummaryRecord.wordCountField] as? Int ?? 0
        let compressionRatio = record[CloudKitSummaryRecord.compressionRatioField] as? Double ?? 0.0
        let confidence = record[CloudKitSummaryRecord.confidenceField] as? Double ?? 0.0
        let processingTime = record[CloudKitSummaryRecord.processingTimeField] as? TimeInterval ?? 0
        
        // Decode complex objects
        var tasks: [TaskItem] = []
        var reminders: [ReminderItem] = []
        var titles: [TitleItem] = []
        
        if let tasksData = record[CloudKitSummaryRecord.tasksField] as? Data {
            tasks = (try? JSONDecoder().decode([TaskItem].self, from: tasksData)) ?? []
        }
        
        if let remindersData = record[CloudKitSummaryRecord.remindersField] as? Data {
            reminders = (try? JSONDecoder().decode([ReminderItem].self, from: remindersData)) ?? []
        }
        
        if let titlesData = record[CloudKitSummaryRecord.titlesField] as? Data {
            titles = (try? JSONDecoder().decode([TitleItem].self, from: titlesData)) ?? []
        }
        
        // Use the summary ID from the CloudKit record ID, or the recordingId if available
        let summaryId = UUID(uuidString: record.recordID.recordName) ?? UUID()
        
        let decodedMetadata = SummaryMetadataCodec.decode(aiMethod)
        let engine = decodedMetadata.engine ?? SummaryMetadataCodec.inferredEngine(from: decodedMetadata.model)
        
        return EnhancedSummaryData(
            id: summaryId,
            recordingId: recordingId ?? summaryId, // Use recordingId if available, otherwise use summary ID
            transcriptId: transcriptId,
            recordingURL: recordingURL,
            recordingName: recordingName,
            recordingDate: recordingDate,
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiEngine: engine,
            aiModel: decodedMetadata.model,
            originalLength: originalLength,
            processingTime: processingTime,
            generatedAt: generatedAt,
            version: version,
            wordCount: wordCount,
            compressionRatio: compressionRatio,
            confidence: confidence
        )
    }
    
    // MARK: - Cleanup
    
    deinit {
        syncDebounceTimer?.invalidate()
        syncDebounceTimer = nil
    }
    
    /// Clears all sync state (useful for testing or resetting)
    func clearSyncState() {
        syncingSummaries.removeAll()
        recentlySyncedSummaries.removeAll()
        pendingSyncQueue.removeAll()
        syncDebounceTimer?.invalidate()
        syncDebounceTimer = nil
    }
    
    /// Manually triggers a sync of all pending summaries (useful for testing)
    func triggerManualSync() async {
        print("🔧 Manual sync triggered")
        await performBatchSync()
    }
    
    /// Tests CloudKit fetch functionality (useful for debugging)
    func testCloudKitFetch() async -> String {
        print("🧪 Testing CloudKit fetch functionality...")
        
        do {
            let summaries = try await fetchAllSummariesUsingRecordOperation(appCoordinator: nil)
            return "✅ CloudKit fetch test successful: Found \(summaries.count) summaries"
        } catch {
            return "❌ CloudKit fetch test failed: \(error.localizedDescription)"
        }
    }
    
    /// Tests CloudKit connectivity and shows available record types
    func testCloudKitConnectivity() async -> String {
        guard let database = database else {
            return "❌ CloudKit database not available"
        }
        
        var result = "🧪 CloudKit Connectivity Test:\n"
        result += "Database Scope: \(database.databaseScope == .public ? "Public" : "Private")\n"
        result += "Record Type: \(CloudKitSummaryRecord.recordType)\n\n"
        
        // Test 1: Try to fetch a single record with a simple query
        result += "Test 1: Simple Query\n"
        do {
            let query = CKQuery(recordType: CloudKitSummaryRecord.recordType, predicate: NSPredicate(value: true))
            let (matchResults, _) = try await database.records(matching: query, resultsLimit: 1)
            result += "✅ Simple query successful: \(matchResults.count) results\n"
        } catch {
            result += "❌ Simple query failed: \(error.localizedDescription)\n"
            if let ckError = error as? CKError {
                result += "   Error Code: \(ckError.code.rawValue)\n"
                result += "   Error Description: \(ckError.localizedDescription)\n"
            }
        }
        
        // Test 2: Try to fetch with different predicates
        result += "\nTest 2: Different Predicates\n"
        let predicates = [
            NSPredicate(format: "TRUEPREDICATE"),
            NSPredicate(format: "FALSEPREDICATE"),
            NSPredicate(format: "recordType == %@", CloudKitSummaryRecord.recordType)
        ]
        
        for (index, predicate) in predicates.enumerated() {
            do {
                let query = CKQuery(recordType: CloudKitSummaryRecord.recordType, predicate: predicate)
                let (matchResults, _) = try await database.records(matching: query, resultsLimit: 1)
                result += "✅ Predicate \(index + 1) successful: \(matchResults.count) results\n"
            } catch {
                result += "❌ Predicate \(index + 1) failed: \(error.localizedDescription)\n"
            }
        }
        
        // Test 3: Try to fetch from specific zone
        result += "\nTest 3: Zone-Specific Query\n"
        do {
            let query = CKQuery(recordType: CloudKitSummaryRecord.recordType, predicate: NSPredicate(value: true))
            let (matchResults, _) = try await database.records(matching: query, inZoneWith: CKRecordZone.default().zoneID, desiredKeys: nil, resultsLimit: 1)
            result += "✅ Zone query successful: \(matchResults.count) results\n"
        } catch {
            result += "❌ Zone query failed: \(error.localizedDescription)\n"
        }
        
        // Test 4: Try to fetch with different record types
        result += "\nTest 4: Different Record Types\n"
        let recordTypes = ["CD_EnhancedSummary", "Summary", "EnhancedSummary", "CloudKitSummaryRecord"]
        
        for recordType in recordTypes {
            do {
                let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
                let (matchResults, _) = try await database.records(matching: query, resultsLimit: 1)
                result += "✅ Record type '\(recordType)': \(matchResults.count) results\n"
            } catch {
                result += "❌ Record type '\(recordType)': \(error.localizedDescription)\n"
            }
        }
        
        // Test 5: Try to fetch a record by ID (this should work regardless of schema)
        result += "\nTest 5: Record Fetch by ID\n"
        do {
            // Try to fetch a test record by ID
            let testUUID = UUID()
            let recordID = CKRecord.ID(recordName: testUUID.uuidString)
            let _ = try await database.record(for: recordID)
            result += "✅ Record fetch by ID successful (unexpected - record shouldn't exist)\n"
        } catch {
            if let ckError = error as? CKError {
                switch ckError.code {
                case .unknownItem:
                    result += "✅ Record fetch by ID working correctly (record doesn't exist, as expected)\n"
                default:
                    result += "❌ Record fetch by ID failed: \(ckError.localizedDescription)\n"
                }
            } else {
                result += "❌ Record fetch by ID failed: \(error.localizedDescription)\n"
            }
        }
        
        return result
    }
    
    /// Returns current sync statistics for debugging
    func getSyncStats() -> String {
        return """
        Sync Status: \(syncStatus)
        Currently Syncing: \(syncingSummaries.count)
        Recently Synced: \(recentlySyncedSummaries.count)
        Pending in Queue: \(pendingSyncQueue.count)
        Last Sync: \(lastSyncDate?.description ?? "Never")
        """
    }
    
    /// Diagnoses CloudKit schema and connectivity issues
    func diagnoseCloudKitIssues() async -> String {
        guard let database = database else {
            return "❌ CloudKit database not available"
        }
        
        var diagnosis = "🔍 CloudKit Diagnosis:\n"
        diagnosis += "Database Scope: \(database.databaseScope == .public ? "Public" : "Private")\n"
        diagnosis += "Record Type: \(CloudKitSummaryRecord.recordType)\n\n"
        
        // Run the comprehensive connectivity test
        diagnosis += await testCloudKitConnectivity()
        
        // Test zone discovery
        diagnosis += "\n🔍 Zone Discovery Test:\n"
        do {
            let changesOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: nil)
            changesOperation.database = database
            
            var zoneCount = 0
            changesOperation.recordZoneWithIDChangedBlock = { _ in
                zoneCount += 1
            }
            
            _ = try await withCheckedThrowingContinuation { continuation in
                changesOperation.fetchDatabaseChangesResultBlock = { result in
                    continuation.resume(with: result)
                }
                database.add(changesOperation)
            }
            
            diagnosis += "✅ Zone discovery successful: \(zoneCount) zones found\n"
        } catch {
            diagnosis += "❌ Zone discovery failed: \(error.localizedDescription)\n"
        }
        
        // Test UUID scanning approach
        diagnosis += "\n🔍 UUID Scanning Test:\n"
        diagnosis += "⚠️ UUID scanning requires appCoordinator parameter, skipping test\n"
        // Note: This test would require an appCoordinator instance to work properly
        
        return diagnosis
    }
    
    
    /// Performs a complete CloudKit reset and fresh sync
    /// 1. Deletes ALL summary records from CloudKit
    /// 2. Uploads all current Core Data summaries fresh
    func performFullCloudKitResetAndSync(appCoordinator: AppDataCoordinator) async throws -> (deleted: Int, uploaded: Int) {
        guard isEnabled, database != nil else {
            throw NSError(domain: "iCloudStorageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "iCloud sync not enabled or CloudKit not initialized"])
        }
        
        await updateSyncStatus(.syncing)
        
        print("🧹 Starting FULL CloudKit reset and fresh sync...")
        print("⚠️ This will DELETE ALL summaries from CloudKit and upload fresh copies")
        
        var deletedCount = 0
        var uploadedCount = 0
        
        do {
            // Step 1: Find and delete ALL CloudKit summary records
            print("📤 Step 1: Deleting ALL CloudKit summary records...")
            deletedCount = try await deleteAllCloudKitSummaries()
            
            // Step 2: Upload all current Core Data summaries
            print("📥 Step 2: Uploading all Core Data summaries...")
            let localSummaries = appCoordinator.getAllSummaries()
            
            for localSummary in localSummaries {
                // Convert Core Data summary to EnhancedSummaryData for upload
                if let enhancedSummary = try? convertCoreDataToEnhancedSummary(localSummary, appCoordinator: appCoordinator) {
                    do {
                        try await performIndividualSync(enhancedSummary)
                        uploadedCount += 1
                        print("✅ Uploaded summary: \(enhancedSummary.recordingName)")
                    } catch {
                        print("❌ Failed to upload summary \(enhancedSummary.recordingName): \(error)")
                    }
                }
            }
            
            await updateSyncStatus(.completed)
            print("✅ CloudKit reset and sync complete: deleted \(deletedCount), uploaded \(uploadedCount)")
            return (deleted: deletedCount, uploaded: uploadedCount)
            
        } catch {
            await updateSyncStatus(.failed(error.localizedDescription))
            print("❌ CloudKit reset and sync failed: \(error)")
            throw error
        }
    }
    
    /// Deletes ALL summary records from CloudKit using zone changes
    private func deleteAllCloudKitSummaries() async throws -> Int {
        guard let database = database else { return 0 }
        
        print("🗑️ Finding all CloudKit summary records for deletion...")
        
        var deletedCount = 0
        
        // Use zone changes to find ALL records
        let zoneChangesOperation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [CKRecordZone.default().zoneID], 
            configurationsByRecordZoneID: nil
        )
        
        var recordsToDelete: [CKRecord.ID] = []
        
        zoneChangesOperation.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record):
                if record.recordType == CloudKitSummaryRecord.recordType {
                    recordsToDelete.append(record.recordID)
                    print("📝 Found CloudKit summary record to delete: \(record.recordID.recordName)")
                }
            case .failure(let error):
                print("⚠️ Failed to fetch record \(recordID): \(error)")
            }
        }
        
        _ = try await withCheckedThrowingContinuation { continuation in
            zoneChangesOperation.fetchRecordZoneChangesResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(zoneChangesOperation)
        }
        
        // Delete all found records
        print("🗑️ Deleting \(recordsToDelete.count) CloudKit summary records...")
        
        for recordID in recordsToDelete {
            do {
                try await database.deleteRecord(withID: recordID)
                deletedCount += 1
                print("✅ Deleted CloudKit record: \(recordID.recordName)")
            } catch {
                if let ckError = error as? CKError, ckError.code == .unknownItem {
                    print("ℹ️ Record already deleted: \(recordID.recordName)")
                    deletedCount += 1 // Count as deleted since it's gone
                } else {
                    print("❌ Failed to delete record \(recordID.recordName): \(error)")
                }
            }
        }
        
        print("✅ Deleted \(deletedCount) CloudKit summary records")
        return deletedCount
    }
    
    /// Converts Core Data SummaryEntry to EnhancedSummaryData for upload
    private func convertCoreDataToEnhancedSummary(_ summaryEntry: SummaryEntry, appCoordinator: AppDataCoordinator) throws -> EnhancedSummaryData {
        guard let summaryId = summaryEntry.id,
              let summary = summaryEntry.summary,
              let aiMethod = summaryEntry.aiMethod else {
            throw NSError(domain: "iCloudStorageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required summary fields"])
        }
        
        // Get associated recording info
        let recording = summaryEntry.recording
        let recordingId = summaryEntry.recordingId
        let transcriptId = summaryEntry.transcriptId
        
        // Parse structured data
        let tasks: [TaskItem] = {
            if let tasksString = summaryEntry.tasks,
               let tasksData = tasksString.data(using: .utf8) {
                return (try? JSONDecoder().decode([TaskItem].self, from: tasksData)) ?? []
            }
            return []
        }()
        
        let reminders: [ReminderItem] = {
            if let remindersString = summaryEntry.reminders,
               let remindersData = remindersString.data(using: .utf8) {
                return (try? JSONDecoder().decode([ReminderItem].self, from: remindersData)) ?? []
            }
            return []
        }()
        
        let titles: [TitleItem] = {
            if let titlesString = summaryEntry.titles,
               let titlesData = titlesString.data(using: .utf8) {
                return (try? JSONDecoder().decode([TitleItem].self, from: titlesData)) ?? []
            }
            return []
        }()
        
        // Build recording info
        let recordingName = recording?.recordingName ?? "Unknown Recording"
        let recordingDate = recording?.recordingDate ?? Date()
        let recordingURL = recording?.recordingURL.flatMap { URL(string: $0) } ?? URL(string: "file:///unknown")!
        
        let contentType = ContentType(rawValue: summaryEntry.contentType ?? "general") ?? .general
        
        let decodedMetadata = SummaryMetadataCodec.decode(aiMethod)
        let engine = decodedMetadata.engine ?? SummaryMetadataCodec.inferredEngine(from: decodedMetadata.model)
        
        return EnhancedSummaryData(
            id: summaryId,
            recordingId: recordingId ?? summaryId, // Use recordingId if available, otherwise use summary ID
            transcriptId: transcriptId,
            recordingURL: recordingURL,
            recordingName: recordingName,
            recordingDate: recordingDate,
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiEngine: engine,
            aiModel: decodedMetadata.model,
            originalLength: Int(summaryEntry.originalLength),
            processingTime: summaryEntry.processingTime,
            generatedAt: summaryEntry.generatedAt ?? Date(),
            version: Int(summaryEntry.version),
            wordCount: Int(summaryEntry.wordCount),
            compressionRatio: summaryEntry.compressionRatio,
            confidence: summaryEntry.confidence
        )
    }
    
    // MARK: - Private Methods
}

// MARK: - CloudKit Error Extensions

extension CKError {
    var isRetryable: Bool {
        switch code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return true
        default:
            return false
        }
    }
    
    var userFriendlyDescription: String {
        switch code {
        case .networkUnavailable:
            return "Network unavailable. Please check your internet connection."
        case .networkFailure:
            return "Network error occurred. Please try again."
        case .notAuthenticated:
            return "Please sign in to iCloud in Settings."
        case .quotaExceeded:
            return "iCloud storage quota exceeded. Please free up space."
        case .serviceUnavailable:
            return "iCloud service is temporarily unavailable."
        case .requestRateLimited:
            return "Too many requests. Please wait and try again."
        default:
            return localizedDescription
        }
    }

    // MARK: - Debug Methods

    /// Debug method to check current Core Data state
    @MainActor
    func debugCoreDataState(appCoordinator: AppDataCoordinator) {
        // Debug logging removed - function kept for potential future use
        let _ = appCoordinator.coreDataManager.getAllRecordings()
        let _ = appCoordinator.coreDataManager.getAllSummaries()
    }

}

// MARK: - Network Monitor

class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private let statusCallback: (NetworkStatus) -> Void
    
    init(statusCallback: @escaping (NetworkStatus) -> Void) {
        self.statusCallback = statusCallback
        
        // Skip network monitoring in preview environments
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ||
                       ProcessInfo.processInfo.processName.contains("PreviewShell") ||
                       ProcessInfo.processInfo.arguments.contains("--enable-previews")
        
        if isPreview {
            statusCallback(.available)
            return
        }
        
        startMonitoring()
    }
    
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let status: NetworkStatus
            
            if path.status == .satisfied {
                if path.isExpensive {
                    status = .limited
                } else {
                    status = .available
                }
            } else {
                status = .unavailable
            }
            
            self?.statusCallback(status)
        }
        
        monitor.start(queue: queue)
    }
    
    deinit {
        monitor.cancel()
    }
}
