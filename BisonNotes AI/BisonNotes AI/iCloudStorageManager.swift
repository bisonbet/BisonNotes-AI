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
    
    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?
    @Published var pendingSyncCount: Int = 0
    @Published var networkStatus: NetworkStatus = .available
    @Published var pendingConflicts: [SyncConflict] = []
    
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
        
        // Load last sync date
        if let lastSyncTimestamp = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date {
            self.lastSyncDate = lastSyncTimestamp
        }
        
        // Check if we're in a preview environment
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ||
                       ProcessInfo.processInfo.processName.contains("PreviewShell") ||
                       ProcessInfo.processInfo.arguments.contains("--enable-previews")
        EnhancedLogger.shared.logiCloudSync("iCloudStorageManager init - Preview environment: \(isPreview)", level: .debug)
        
        if isPreview {
            EnhancedLogger.shared.logiCloudSync("Running in Xcode preview, skipping CloudKit initialization", level: .debug)
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
        
        EnhancedLogger.shared.startPerformanceTracking("CloudKit Initialization", context: "iCloud Setup")
        
        // Skip CloudKit initialization in preview environments
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ||
                       ProcessInfo.processInfo.processName.contains("PreviewShell") ||
                       ProcessInfo.processInfo.arguments.contains("--enable-previews")
        EnhancedLogger.shared.logiCloudSync("initializeCloudKit - Preview environment: \(isPreview)", level: .debug)
        
        if isPreview {
            EnhancedLogger.shared.logiCloudSync("Skipping CloudKit initialization in preview environment", level: .debug)
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
        EnhancedLogger.shared.logiCloudSync("CloudKit initialized successfully", level: .info)
        
        if let result = EnhancedLogger.shared.endPerformanceTracking("CloudKit Initialization") {
            EnhancedLogger.shared.logPerformance("CloudKit initialization completed in \(String(format: "%.2f", result.duration))s", level: .info)
        }
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
        
        // Ensure CloudKit is initialized
        if !isInitialized {
            await initializeCloudKit()
        }
        
        guard let database = database else {
            throw NSError(domain: "iCloudStorageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "CloudKit not initialized"])
        }
        
        guard networkStatus.canSync else {
            print("⚠️ Network unavailable, queuing summary for later sync")
            // In a full implementation, we'd queue this for later
            throw NSError(domain: "iCloudStorageManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Network unavailable"])
        }
        
        print("🔄 Syncing summary: \(summary.recordingName)")
        
        var retryCount = 0
        
        while retryCount < maxRetryAttempts {
            do {
                // Check for existing record to handle conflicts
                let recordID = CKRecord.ID(recordName: summary.id.uuidString)
                
                var existingRecord: CKRecord?
                do {
                    existingRecord = try await database.record(for: recordID)
                } catch {
                    // Record doesn't exist, which is fine for new summaries
                    if let ckError = error as? CKError, ckError.code != .unknownItem {
                        throw error
                    }
                }
                
                // Handle conflict if existing record found
                if let existing = existingRecord {
                    let conflict = try await handleSyncConflict(localSummary: summary, cloudRecord: existing)
                    if let resolvedSummary = conflict {
                        let record = try createCloudKitRecord(from: resolvedSummary)
                        let savedRecord = try await database.save(record)
                        print("✅ Successfully synced resolved summary to iCloud: \(savedRecord.recordID)")
                    } else {
                        print("⚠️ Conflict resolution pending for summary: \(summary.recordingName)")
                        return
                    }
                } else {
                    // No conflict, save new record
                    let record = try createCloudKitRecord(from: summary)
                    let savedRecord = try await database.save(record)
                    print("✅ Successfully synced summary to iCloud: \(savedRecord.recordID)")
                }
                
                // Update last sync date
                await MainActor.run {
                    self.lastSyncDate = Date()
                    UserDefaults.standard.set(self.lastSyncDate, forKey: "lastSyncDate")
                }
                
                return // Success, exit retry loop
                
            } catch {
                retryCount += 1
                
                if let ckError = error as? CKError, ckError.isRetryable && retryCount < maxRetryAttempts {
                    print("⚠️ Retryable error, attempt \(retryCount)/\(maxRetryAttempts): \(ckError.localizedDescription)")
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    continue
                } else {
                    print("❌ Failed to sync summary after \(retryCount) attempts: \(error)")
                    throw error
                }
            }
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
    
    func fetchSummariesFromiCloud() async throws -> [EnhancedSummaryData] {
        guard isEnabled else {
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
        query.sortDescriptors = [NSSortDescriptor(key: CloudKitSummaryRecord.generatedAtField, ascending: false)]
        
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
                
                if let ckError = error as? CKError, ckError.isRetryable && retryCount < maxRetryAttempts {
                    print("⚠️ Retryable error fetching from iCloud, attempt \(retryCount)/\(maxRetryAttempts): \(ckError.localizedDescription)")
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    continue
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
            print("🔍 Skipping network monitoring setup in preview environment")
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
        
        print("🔄 Set up periodic sync with \(syncInterval)s interval")
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
            print("⏭️ Skipping periodic sync due to current conditions")
            return
        }
        
        print("🔄 Performing periodic sync check...")
        
        do {
            // Perform battery-aware sync
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
            try await syncAllSummaries([]) // Pass empty array for now
        }
    }
    
    private func syncSummariesInBatches(batchSize: Int) async throws {
        // Implementation for batch-based sync to reduce network usage
        print("📦 Syncing summaries in batches of \(batchSize)")
        
        // This would implement batch processing for network efficiency
        // For now, just call the standard sync
        try await syncAllSummaries([]) // Pass empty array for now
    }
    
    private func setupCloudKitSchema() async {
        print("🔧 Setting up CloudKit schema...")
        
        // CloudKit schema is typically set up through the CloudKit Dashboard
        // or automatically when first records are saved
        // This method can be used for any additional setup if needed
    }
    
    private func createCloudKitRecord(from summary: EnhancedSummaryData) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: summary.id.uuidString)
        let record = CKRecord(recordType: CloudKitSummaryRecord.recordType, recordID: recordID)
        
        // Basic fields
        record[CloudKitSummaryRecord.recordingURLField] = summary.recordingURL.absoluteString
        record[CloudKitSummaryRecord.recordingNameField] = summary.recordingName
        record[CloudKitSummaryRecord.recordingDateField] = summary.recordingDate
        record[CloudKitSummaryRecord.summaryField] = summary.summary
        record[CloudKitSummaryRecord.contentTypeField] = summary.contentType.rawValue
        record[CloudKitSummaryRecord.aiMethodField] = summary.aiMethod
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
        
        // Get processing time (default to 0 if not available)
        let processingTime = record[CloudKitSummaryRecord.processingTimeField] as? TimeInterval ?? 0
        
        return EnhancedSummaryData(
            recordingURL: recordingURL,
            recordingName: recordingName,
            recordingDate: recordingDate,
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiMethod: aiMethod,
            originalLength: originalLength,
            processingTime: processingTime
        )
    }
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
            print("🔍 Skipping network monitoring in preview environment")
            // Set default status for preview
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