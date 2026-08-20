import Foundation
import CloudKit
import SwiftUI
import Network
import CoreData

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
    static let schemaBootstrapRecordingName = "SchemaInit"
    static let schemaBootstrapAIMethod = "schema"

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

struct CloudReviewItem: Identifiable, Equatable {
    let id: String
    let recordingId: UUID?
    let title: String
    let date: Date?
    let backupRecordNames: [String]
    let legacySummaryRecordNames: [String]
    let hasRecording: Bool
    let hasAudio: Bool
    let hasTranscript: Bool
    let hasSummary: Bool
    let sourceDeviceIdentifier: String?

    var contentsDescription: String {
        var parts: [String] = []
        if hasAudio {
            parts.append("audio")
        } else if hasRecording {
            parts.append("recording")
        }
        if hasTranscript {
            parts.append("transcript")
        }
        if hasSummary {
            parts.append("summary")
        }
        return parts.isEmpty ? "cloud records" : parts.joined(separator: ", ")
    }
}

enum CloudDeletionTargetKind: String, Equatable {
    case recording
    case transcript
    case summary
}

struct CloudDeletionTarget: Equatable {
    let kind: CloudDeletionTargetKind
    let id: UUID
    let recordingId: UUID?
    let deletedAt: Date
}

// MARK: - Network Status

enum NetworkStatus: Sendable {
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

    // MARK: - Shared Instance

    /// Single shared instance used across the entire app.
    /// All code should use `.shared` instead of creating new instances
    /// so that in-memory state (isManualCloudTransferInProgress, timers,
    /// sync queue, etc.) is consistent.
    static let shared: iCloudStorageManager = {
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ||
                       ProcessInfo.processInfo.processName.contains("PreviewShell") ||
                       ProcessInfo.processInfo.arguments.contains("--enable-previews")
        if isPreview {
            return iCloudStorageManager.preview
        }
        return iCloudStorageManager()
    }()

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
    @Published var lastMaintenanceMessage: String?
    @Published var isAutomaticReconcileRunning = false
    @Published var pendingCloudReviewItems: [CloudReviewItem] = []
    @Published var isScanningCloudReviewItems = false
    @Published var cloudReviewError: String?

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

    /// Prevents periodic/queued sync work from competing with manual backup/restore operations.
    private var isManualCloudTransferInProgress = false
    private var isAutomaticCloudReconcileInProgress = false

    /// Maximum number of summaries to sync in a single batch
    private let maxBatchSize = 10

    /// Minimum delay between batch syncs (30 seconds)
    private let batchSyncDelay: TimeInterval = 30

    // MARK: - Auto-Backup

    /// Debounce timer for auto-backup after data changes
    private var autoBackupTimer: Timer?

    /// Delay before auto-backup fires after the last data change (2 minutes)
    private let autoBackupDebounceInterval: TimeInterval = 120

    /// Minimum interval between auto-backups (15 minutes)
    private let autoBackupMinInterval: TimeInterval = 900

    /// Timestamp of the last completed auto-backup
    private var lastAutoBackupDate: Date? {
        get { UserDefaults.standard.object(forKey: "lastAutoBackupDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastAutoBackupDate") }
    }

    // MARK: - Private Properties

    private static let sharedContainerIdentifier = "iCloud.Bison-Networking.BisonNotes-AI"
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

    private static func sharedCloudKitContainer() -> CKContainer {
        CKContainer(identifier: sharedContainerIdentifier)
    }

    init() {
        self.deviceIdentifier = PlatformDevice.vendorIdentifier

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
        self.container = Self.sharedCloudKitContainer()
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
                AppLog.shared.iCloudSync("Performing initial full sync (first install: \(isFirstInstall), requested: \(shouldPerformFullSyncOnStartup))")
                do {
                    try await performOneTimeFullSync()
                } catch {
                    AppLog.shared.iCloudSync("Initial full sync failed: \(error.localizedDescription)", level: .error)
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
        AppLog.shared.iCloudSync("Disabling iCloud sync")

        // Stop periodic sync
        syncTimer?.invalidate()
        syncTimer = nil

        await updateSyncStatus(.idle)
        AppLog.shared.iCloudSync("iCloud sync disabled")
    }

    func syncSummary(_ summary: EnhancedSummaryData) async throws {
        guard isEnabled else {
            AppLog.shared.iCloudSync("iCloud sync is disabled, skipping summary sync", level: .debug)
            return
        }

        guard !isCloudSyncDisabled(for: summary) else {
            AppLog.shared.iCloudSync("Summary belongs to a recording marked Keep on This Device, skipping iCloud sync", level: .debug)
            return
        }

        // Check if this summary is already being synced
        if syncingSummaries.contains(summary.id) {
            AppLog.shared.iCloudSync("Summary already being synced, skipping", level: .debug)
            return
        }

        // Check if this summary was recently synced
        if let lastSync = recentlySyncedSummaries[summary.id],
           Date().timeIntervalSince(lastSync) < syncCooldownInterval {
            let timeSince = Int(Date().timeIntervalSince(lastSync))
            AppLog.shared.iCloudSync("Summary recently synced (\(timeSince)s ago), skipping", level: .debug)
            return
        }

        // Add to pending queue and schedule batch sync
        pendingSyncQueue.append(summary)
        scheduleBatchSync()

        AppLog.shared.iCloudSync("Queued summary for batch sync (queue size: \(pendingSyncQueue.count))", level: .debug)
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
        pendingSyncQueue.removeAll { isCloudSyncDisabled(for: $0) }
        guard !pendingSyncQueue.isEmpty else { return }

        // Take up to maxBatchSize summaries from the queue
        let batch = Array(pendingSyncQueue.prefix(maxBatchSize))
        pendingSyncQueue.removeFirst(min(maxBatchSize, pendingSyncQueue.count))

        AppLog.shared.iCloudSync("Starting batch sync of \(batch.count) summaries", level: .debug)

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
                AppLog.shared.iCloudSync("Failed to sync summary: \(error.localizedDescription)", level: .error)
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
            AppLog.shared.iCloudSync("Successfully synced batch: \(syncedCount) summaries")
        } else {
            await updateSyncStatus(.failed("Batch: \(syncedCount) synced, \(failedCount) failed"))
            AppLog.shared.iCloudSync("Batch sync completed with errors: \(syncedCount) synced, \(failedCount) failed", level: .error)
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

        guard let database else {
            throw NSError(domain: "iCloudStorageManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "CloudKit not initialized"])
        }

        guard networkStatus.canSync else {
            throw NSError(domain: "iCloudStorageManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Network unavailable"])
        }

        AppLog.shared.iCloudSync("Syncing individual summary", level: .debug)

        // A summary can already be in the legacy upload queue when the user deletes
        // it. Check both the durable local queues and CloudKit's tombstones immediately
        // before every write so an in-flight upload cannot recreate deleted content.
        let deletionTargets = (try? await fetchDeletionTargets(database: database)) ?? CloudDeletionTargets()
        let pendingRecordingIds = Set(pendingCloudDeletionMarkers.map(\.recordingId))
        let pendingSummaryIds = Set(pendingSummaryCloudRemovals.map(\.summaryId))
        let pendingTranscriptIds = Set(pendingTranscriptCloudRemovals.map(\.transcriptId))
        if pendingSummaryIds.contains(summary.id) || deletionTargets.summaries.contains(summary.id) {
            return
        }
        if let recordingId = summary.recordingId,
           pendingRecordingIds.contains(recordingId) || deletionTargets.recordings.contains(recordingId) {
            return
        }
        let summaryToSync: EnhancedSummaryData
        if let transcriptId = summary.transcriptId,
           pendingTranscriptIds.contains(transcriptId) || deletionTargets.transcripts.contains(transcriptId) {
            summaryToSync = summaryByClearingTranscript(summary)
        } else {
            summaryToSync = summary
        }

        var retryCount = 0

        while retryCount < maxRetryAttempts {
            do {
                let recordID = CKRecord.ID(recordName: summary.id.uuidString)
                _ = try await handleConflictResolution(for: recordID, with: summaryToSync)

                // Update last sync date
                await MainActor.run {
                    self.lastSyncDate = Date()
                    UserDefaults.standard.set(self.lastSyncDate, forKey: "lastSyncDate")
                }

                AppLog.shared.iCloudSync("Successfully synced summary")
                return // Success, exit retry loop

            } catch {
                retryCount += 1

                // Handle specific CloudKit errors
                if let ckError = error as? CKError {
                    switch ckError.code {
                    case .serverRecordChanged:
                        AppLog.shared.iCloudSync("Server record changed, refetching and retrying (attempt \(retryCount)/\(maxRetryAttempts))", level: .debug)
                        // Don't wait for server changed errors, retry immediately with fresh data
                        continue
                    case .networkFailure, .networkUnavailable, .serviceUnavailable:
                        if retryCount < maxRetryAttempts {
                            AppLog.shared.iCloudSync("Network error, retrying in \(retryDelay)s (attempt \(retryCount)/\(maxRetryAttempts))", level: .error)
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            continue
                        }
                    case .unknownItem:
                        // Schema issue, ensure it exists and retry once
                        if retryCount == 1 {
                            AppLog.shared.iCloudSync("Unknown record type, setting up schema and retrying", level: .error)
                            await setupCloudKitSchema()
                            continue
                        }
                    default:
                        if ckError.isRetryable && retryCount < maxRetryAttempts {
                            AppLog.shared.iCloudSync("Retryable CloudKit error, attempt \(retryCount)/\(maxRetryAttempts): \(ckError.localizedDescription)", level: .error)
                            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                            continue
                        }
                    }
                }

                AppLog.shared.iCloudSync("Failed to sync summary after \(retryCount) attempts: \(error.localizedDescription)", level: .error)
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
            AppLog.shared.iCloudSync("Fetched existing record from server for conflict resolution", level: .debug)
        } catch {
            if let ckError = error as? CKError {
                switch ckError.code {
                case .unknownItem:
                    // Record doesn't exist, create new one
                    AppLog.shared.iCloudSync("Record doesn't exist, creating new record", level: .debug)
                    let newRecord = try createCloudKitRecord(from: summary)
                    return try await database.save(newRecord)
                case .invalidArguments:
                    // Schema issue, ensure schema exists and try creating new record
                    AppLog.shared.iCloudSync("Schema issue detected, ensuring schema and creating record", level: .error)
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
            AppLog.shared.iCloudSync("Updating existing record with local changes", level: .debug)
            updateCloudKitRecord(existing, from: summary)

            // Save the updated record
            return try await database.save(existing)
        } else {
            // Shouldn't reach here, but create new record as fallback
            AppLog.shared.iCloudSync("Unexpected state, creating new record", level: .error)
            let newRecord = try createCloudKitRecord(from: summary)
            return try await database.save(newRecord)
        }
    }

    private func summaryByClearingTranscript(_ summary: EnhancedSummaryData) -> EnhancedSummaryData {
        EnhancedSummaryData(
            id: summary.id,
            recordingId: summary.recordingId,
            transcriptId: nil,
            recordingURL: summary.recordingURL,
            recordingName: summary.recordingName,
            recordingDate: summary.recordingDate,
            summary: summary.summary,
            tasks: summary.tasks,
            reminders: summary.reminders,
            titles: summary.titles,
            attachments: summary.attachments,
            userNotes: summary.userNotes,
            contentType: summary.contentType,
            aiEngine: summary.aiEngine,
            aiModel: summary.aiModel,
            originalLength: summary.originalLength,
            processingTime: summary.processingTime,
            generatedAt: summary.generatedAt,
            version: summary.version,
            wordCount: summary.wordCount,
            compressionRatio: summary.compressionRatio,
            confidence: summary.confidence
        )
    }

    func syncAllSummaries(_ summaries: [EnhancedSummaryData]) async throws {
        guard isEnabled else {
            AppLog.shared.iCloudSync("iCloud sync is disabled, skipping batch sync", level: .debug)
            return
        }
        let syncableSummaries = summaries.filter { !isCloudSyncDisabled(for: $0) }

        await updateSyncStatus(.syncing)
        await MainActor.run {
            self.pendingSyncCount = syncableSummaries.count
        }

        AppLog.shared.iCloudSync("Starting batch sync of \(syncableSummaries.count) summaries", level: .debug)

        var syncedCount = 0
        var failedCount = 0

        for summary in syncableSummaries {
            do {
                try await syncSummary(summary)
                syncedCount += 1
            } catch {
                AppLog.shared.iCloudSync("Failed to sync summary: \(error.localizedDescription)", level: .error)
                failedCount += 1
            }

            await MainActor.run {
                self.pendingSyncCount = syncableSummaries.count - syncedCount - failedCount
            }
        }

        if failedCount == 0 {
            await updateSyncStatus(.completed)
            AppLog.shared.iCloudSync("Successfully synced all \(syncedCount) summaries")
        } else {
            await updateSyncStatus(.failed("Synced \(syncedCount), failed \(failedCount)"))
            AppLog.shared.iCloudSync("Batch sync completed with errors: \(syncedCount) synced, \(failedCount) failed", level: .error)
        }

        await MainActor.run {
            self.pendingSyncCount = 0
        }
    }

    /// Convenience wrapper that loads all locally stored summaries and syncs them
    /// This should only be called manually or during initial setup
    func syncAllSummaries() async throws {
        AppLog.shared.iCloudSync("Manual full sync requested")
        // Core Data is the authoritative local summary store. SummaryManager only exposes
        // this read-through for callers that do not already have an AppDataCoordinator.
        let allSummaries = SummaryManager.shared.getAuthoritativeSummaryData()
        try await syncAllSummaries(allSummaries)
    }

    /// Performs a one-time full sync for new installations or user request
    func performOneTimeFullSync() async throws {
        AppLog.shared.iCloudSync("Performing one-time full sync")
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
        try await removeSummaryContentFromiCloud(summaryId: summaryId)
    }

    func fetchSummariesFromiCloud(forRecovery: Bool = false) async throws -> [EnhancedSummaryData] {
        guard forRecovery || isEnabled else {
            AppLog.shared.iCloudSync("iCloud sync is disabled, returning empty array", level: .debug)
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
            AppLog.shared.iCloudSync("Network unavailable, cannot fetch from iCloud", level: .error)
            throw NSError(domain: "iCloudStorageManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Network unavailable"])
        }

        AppLog.shared.iCloudSync("Fetching summaries from iCloud")

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
                        AppLog.shared.iCloudSync("Failed to process record: \(error.localizedDescription)", level: .error)
                    }
                }

                let deletionTargets = try? await fetchDeletionTargets(database: database)
                summaries = filterDeletedSummaryData(summaries, deletionTargets: deletionTargets)
                AppLog.shared.iCloudSync("Fetched \(summaries.count) summaries from iCloud", level: .debug)
                return summaries

            } catch {
                retryCount += 1

                if let ckError = error as? CKError {
                    if ckError.code == .unknownItem || ckError.localizedDescription.contains("record type") {
                        await setupCloudKitSchema()
                        return []
                    } else if ckError.isRetryable && retryCount < maxRetryAttempts {
                        AppLog.shared.iCloudSync("Retryable error fetching from iCloud, attempt \(retryCount)/\(maxRetryAttempts): \(ckError.localizedDescription)", level: .error)
                        try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                        continue
                    } else {
                        AppLog.shared.iCloudSync("Failed to fetch summaries from iCloud after \(retryCount) attempts: \(error.localizedDescription)", level: .error)
                        throw error
                    }
                } else {
                    AppLog.shared.iCloudSync("Failed to fetch summaries from iCloud after \(retryCount) attempts: \(error.localizedDescription)", level: .error)
                    throw error
                }
            }
        }

        // This should never be reached, but just in case
        throw NSError(domain: "iCloudStorageManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Max retry attempts exceeded"])
    }

    func performBidirectionalSync(localSummaries: [EnhancedSummaryData]) async throws {
        guard isEnabled && networkStatus.canSync else {
            AppLog.shared.iCloudSync("Cannot perform bidirectional sync - disabled or network unavailable", level: .error)
            return
        }

        await updateSyncStatus(.syncing)

        do {
            // Fetch all summaries from iCloud
            let cloudSummaries = try await fetchSummariesFromiCloud()

            // Create lookup dictionaries
            let syncableLocalSummaries = localSummaries.filter { !isCloudSyncDisabled(for: $0) }
            let localLookup = Dictionary(uniqueKeysWithValues: syncableLocalSummaries.map { ($0.id, $0) })
            let cloudLookup = Dictionary(uniqueKeysWithValues: cloudSummaries.map { ($0.id, $0) })

            var syncedCount = 0
            var conflictCount = 0

            // Process local summaries
            for localSummary in syncableLocalSummaries {
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
                    AppLog.shared.iCloudSync("Found cloud-only summary", level: .debug)
                }
            }

            if conflictCount == 0 {
                await updateSyncStatus(.completed)
                AppLog.shared.iCloudSync("Bidirectional sync completed: \(syncedCount) synced")
            } else {
                await updateSyncStatus(.failed("Synced \(syncedCount), \(conflictCount) conflicts pending"))
                AppLog.shared.iCloudSync("Bidirectional sync completed with conflicts: \(syncedCount) synced, \(conflictCount) conflicts", level: .error)
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
            AppLog.shared.iCloudSync("Starting download process (forRecovery: \(forRecovery))")

            // Use the recovery-aware fetch method if this is for recovery, otherwise use the comprehensive method
            let cloudSummaries = forRecovery ?
                try await fetchSummariesFromiCloud(forRecovery: true) :
                try await fetchAllSummariesUsingRecordOperation(appCoordinator: appCoordinator)

            AppLog.shared.iCloudSync("Found \(cloudSummaries.count) summaries in iCloud", level: .debug)

            // Get local summary IDs from Core Data for comparison
            let localSummaries = appCoordinator.coreDataManager.getAllSummaries()
            let localSummaryIds = Set(localSummaries.compactMap { $0.id })

            AppLog.shared.iCloudSync("Found \(localSummaries.count) local summaries", level: .debug)

            // Find cloud-only summaries
            let cloudOnlySummaries = cloudSummaries.filter { !localSummaryIds.contains($0.id) }

            AppLog.shared.iCloudSync("Found \(cloudOnlySummaries.count) cloud summaries to download", level: .debug)

            var downloadedCount = 0
            for cloudSummary in cloudOnlySummaries {
                do {
                    // Try to create Core Data summary entry
                    let didPersist = try await createCoreDataSummary(from: cloudSummary, appCoordinator: appCoordinator)
                    if didPersist {
                        downloadedCount += 1
                        AppLog.shared.iCloudSync("Downloaded cloud summary", level: .debug)
                    }
                } catch {
                    AppLog.shared.iCloudSync("Failed to create Core Data entry for cloud summary: \(error.localizedDescription)", level: .error)
                }
            }

            await updateSyncStatus(.completed)
            AppLog.shared.iCloudSync("Downloaded \(downloadedCount) summaries from iCloud")
            return downloadedCount

        } catch {
            await updateSyncStatus(.failed(error.localizedDescription))
            throw error
        }
    }

    func fetchAllSummariesFromCloud() async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }
        return try await fetchAllSummariesFromCloud(using: database)
    }

    /// Fetches all summary-sync records using the provided database.
    /// Use this overload in the restore path where `self.database` may not
    /// yet be initialized (fresh app session on a new device).
    /// Follows pagination cursors to ensure all pages are fetched.
    func fetchAllSummariesFromCloud(using database: CKDatabase) async throws -> [EnhancedSummaryData] {
        let query = CKQuery(recordType: CloudKitSummaryRecord.recordType, predicate: NSPredicate(value: true))
        var summaries: [EnhancedSummaryData] = []

        // Fetch first page
        let (firstResults, firstCursor) = try await database.records(matching: query)
        processSummaryMatchResults(firstResults, into: &summaries)

        // Follow pagination cursors for remaining pages
        var cursor = firstCursor
        while let activeCursor = cursor {
            let (pageResults, nextCursor) = try await database.records(continuingMatchFrom: activeCursor)
            processSummaryMatchResults(pageResults, into: &summaries)
            cursor = nextCursor
        }

        let deletionTargets = try? await fetchDeletionTargets(database: database)
        return filterDeletedSummaryData(summaries, deletionTargets: deletionTargets)
    }

    /// Decodes match results into EnhancedSummaryData, appending to the provided array.
    private func processSummaryMatchResults(
        _ matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
        into summaries: inout [EnhancedSummaryData]
    ) {
        for (_, result) in matchResults {
            switch result {
            case .success(let record):
                do {
                    let summary = try createEnhancedSummaryData(from: record)
                    summaries.append(summary)
                } catch {
                    AppLog.shared.iCloudSync("Failed to decode cloud summary: \(error.localizedDescription)", level: .error)
                }
            case .failure(let error):
                AppLog.shared.iCloudSync("Failed to fetch cloud summary record: \(error.localizedDescription)", level: .error)
            }
        }
    }

    private func filterDeletedSummaryData(
        _ summaries: [EnhancedSummaryData],
        deletionTargets: CloudDeletionTargets?
    ) -> [EnhancedSummaryData] {
        guard let deletionTargets else { return summaries }

        return summaries.compactMap { summary in
            guard !deletionTargets.summaries.contains(summary.id) else {
                return nil
            }
            if let recordingId = summary.recordingId,
               deletionTargets.recordings.contains(recordingId) {
                return nil
            }
            if let transcriptId = summary.transcriptId,
               deletionTargets.transcripts.contains(transcriptId) {
                return summaryByClearingTranscript(summary)
            }
            return summary
        }
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

        AppLog.shared.iCloudSync("Fetching all summaries using record discovery (schema-safe)", level: .debug)

        var allSummaries: [EnhancedSummaryData] = []

        // Approach 1: UUID scanning + change tracking (most comprehensive)
        if let appCoordinator = appCoordinator {
            do {
                let summaries = try await fetchSummariesByUUIDScanning(appCoordinator: appCoordinator)
                allSummaries.append(contentsOf: summaries)
            } catch {
                AppLog.shared.iCloudSync("UUID scanning + change tracking failed: \(error.localizedDescription)", level: .error)
            }
        }

        // Approach 2: Brute force record scanning (works when change tracking fails)
        if allSummaries.isEmpty {
            do {
                let scannedSummaries = try await bruteForceRecordDiscovery()
                allSummaries.append(contentsOf: scannedSummaries)
            } catch {
                AppLog.shared.iCloudSync("Brute force scanning failed: \(error.localizedDescription)", level: .error)
            }
        }

        // Approach 2b: Direct zone changes (works without appCoordinator)
        if allSummaries.isEmpty {
            do {
                let zoneSummaries = try await fetchRecordsUsingZoneChanges()
                allSummaries.append(contentsOf: zoneSummaries)
            } catch {
                AppLog.shared.iCloudSync("Direct zone changes failed: \(error.localizedDescription)", level: .error)
            }
        }

        // Approach 3: Database changes + zone scanning (fallback)
        if allSummaries.isEmpty {
            do {
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
                        AppLog.shared.iCloudSync("Failed to fetch from zone using changes: \(error.localizedDescription)", level: .error)
                    }
                }

            } catch {
                AppLog.shared.iCloudSync("Database changes + zone scanning failed: \(error.localizedDescription)", level: .error)
            }
        }

        // Remove duplicates based on ID
        let uniqueSummaries = Dictionary(grouping: allSummaries, by: { $0.id })
            .compactMapValues { $0.first }
            .values
            .map { $0 }

        let deletionTargets = try? await fetchDeletionTargets(database: database)
        let filteredSummaries = filterDeletedSummaryData(Array(uniqueSummaries), deletionTargets: deletionTargets)
        let duplicateCount = allSummaries.count - uniqueSummaries.count
        let duplicateSuffix = duplicateCount > 0 ? "; removed \(duplicateCount) duplicates" : ""
        AppLog.shared.iCloudSync(
            "Cloud summary discovery complete: \(filteredSummaries.count) summaries found\(duplicateSuffix)",
            level: .debug
        )

        return filteredSummaries
    }

    /// Fetches summaries by scanning for common UUID patterns in record names
    /// This bypasses the need for queryable fields
    private func fetchSummariesByUUIDScanning(appCoordinator: AppDataCoordinator) async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }

        // Get all summaries from Core Data to get their IDs
        let localSummaries = appCoordinator.coreDataManager.getAllSummaries()

        var foundSummaries: [EnhancedSummaryData] = []
        var checkedUUIDs: Set<String> = Set()

        // Phase 1: Try to fetch each local summary's CloudKit record
        for localSummary in localSummaries {
            guard let summaryId = localSummary.id else {
                AppLog.shared.iCloudSync("Local summary has no ID, skipping", level: .error)
                continue
            }

            let uuidString = summaryId.uuidString
            checkedUUIDs.insert(uuidString)

            do {
                let recordID = CKRecord.ID(recordName: uuidString)
                let record = try await database.record(for: recordID)

                // Verify this is actually a summary record before processing
                guard record.recordType == CloudKitSummaryRecord.recordType else {
                    continue
                }

                // Convert to EnhancedSummaryData
                let summary = try createEnhancedSummaryData(from: record)
                foundSummaries.append(summary)

            } catch {
                // Missing records are expected for local-only summaries. Other
                // lookup failures are actionable and should remain visible.
                if (error as? CKError)?.code != .unknownItem {
                    AppLog.shared.iCloudSync(
                        "CloudKit summary lookup failed: \(error.localizedDescription)",
                        level: .error
                    )
                }
            }
        }

        // Phase 2: Try to find cloud-only summaries using change tracking
        // This will help us discover CloudKit records that don't have local counterparts
        do {
            let zoneChangesOperation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [CKRecordZone.default().zoneID],
                configurationsByRecordZoneID: nil
            )

            var cloudOnlyRecords: [CKRecord] = []

            zoneChangesOperation.recordWasChangedBlock = { _, result in
                switch result {
                case .success(let record):
                    // Only process our summary records that we haven't already checked
                    if record.recordType == CloudKitSummaryRecord.recordType &&
                       !checkedUUIDs.contains(record.recordID.recordName) {
                        cloudOnlyRecords.append(record)
                    }
                case .failure(let error):
                    AppLog.shared.iCloudSync("Failed to fetch cloud-only record: \(error.localizedDescription)", level: .error)
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
                } catch {
                    AppLog.shared.iCloudSync("Failed to convert cloud-only record: \(error.localizedDescription)", level: .error)
                }
            }

        } catch {
            AppLog.shared.iCloudSync("Change tracking failed: \(error.localizedDescription)", level: .error)
        }

        return foundSummaries
    }

    // Note: UUID pattern generation was removed to prevent integer overflow crashes
    // The current approach focuses on finding CloudKit records that correspond to local summaries

    /// Brute force record discovery - tries various approaches to find CloudKit records
    /// This method attempts to discover records when normal change tracking fails
    private func bruteForceRecordDiscovery() async throws -> [EnhancedSummaryData] {
        guard database != nil else { return [] }

        var foundSummaries: [EnhancedSummaryData] = []

        // Removed approach with hardcoded record IDs - not scalable or maintainable

        // Approach 2: Try with CKFetchRecordZoneChangesOperation but with specific configuration
        do {
            let summaries = try await fetchRecordsWithSpecificConfiguration()
            foundSummaries.append(contentsOf: summaries)
        } catch {
            AppLog.shared.iCloudSync("Configured zone changes failed: \(error.localizedDescription)", level: .error)
        }

        return foundSummaries
    }

    /// Fetches records using known IDs that were observed in sync operations

    /// Fetches records with specific zone configuration
    private func fetchRecordsWithSpecificConfiguration() async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }

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

        zoneChangesOperation.recordWasChangedBlock = { _, result in
            switch result {
            case .success(let record):
                if record.recordType == CloudKitSummaryRecord.recordType {
                    foundRecords.append(record)
                }
            case .failure(let error):
                AppLog.shared.iCloudSync("Failed to fetch record with configuration: \(error.localizedDescription)", level: .error)
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
                AppLog.shared.iCloudSync("Failed to convert configured record: \(error.localizedDescription)", level: .error)
            }
        }

        return summaries
    }

    /// Fetches records using direct zone changes operation (works without appCoordinator)
    private func fetchRecordsUsingZoneChanges() async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }

        let zoneChangesOperation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [CKRecordZone.default().zoneID],
            configurationsByRecordZoneID: nil
        )

        var foundRecords: [CKRecord] = []

        zoneChangesOperation.recordWasChangedBlock = { _, result in
            switch result {
            case .success(let record):
                if record.recordType == CloudKitSummaryRecord.recordType {
                    foundRecords.append(record)
                }
            case .failure(let error):
                AppLog.shared.iCloudSync("Failed to fetch record: \(error.localizedDescription)", level: .error)
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
                AppLog.shared.iCloudSync("Failed to convert record: \(error.localizedDescription)", level: .error)
            }
        }

        return summaries
    }

    /// Fetches records from a specific zone using zone changes operation
    private func fetchRecordsFromZoneUsingChanges(_ zoneID: CKRecordZone.ID) async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }

        let zoneChangesOperation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: nil
        )

        var foundRecords: [CKRecord] = []

        zoneChangesOperation.recordWasChangedBlock = { _, result in
            switch result {
            case .success(let record):
                if record.recordType == CloudKitSummaryRecord.recordType {
                    foundRecords.append(record)
                }
            case .failure(let error):
                AppLog.shared.iCloudSync("Failed to fetch record in zone: \(error.localizedDescription)", level: .error)
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
                AppLog.shared.iCloudSync("Failed to convert record: \(error.localizedDescription)", level: .error)
            }
        }

        return summaries
    }

    /// Fetches records from a zone by scanning for existing records
    /// This bypasses the need for queryable fields
    private func fetchRecordsFromZoneByScanning(_ zoneID: CKRecordZone.ID) async throws -> [EnhancedSummaryData] {
        guard let database = database else { return [] }

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
                    AppLog.shared.iCloudSync("Record fetch error: \(error.localizedDescription)", level: .error)
                }
            }

        } catch {
            AppLog.shared.iCloudSync("Zone query failed: \(error.localizedDescription)", level: .error)
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
                        AppLog.shared.iCloudSync("Record fetch error: \(error.localizedDescription)", level: .error)
                    }
                }

            } catch {
                AppLog.shared.iCloudSync("Extended zone query failed: \(error.localizedDescription)", level: .error)
            }
        }

        // Convert records to summaries
        var summaries: [EnhancedSummaryData] = []
        for record in foundRecords {
            do {
                let summary = try createEnhancedSummaryData(from: record)
                summaries.append(summary)
            } catch {
                AppLog.shared.iCloudSync("Failed to decode record: \(error.localizedDescription)", level: .error)
            }
        }

        return summaries
    }

    /// Creates a Core Data summary entry from cloud summary data.
    /// Returns `true` when a Core Data row was actually persisted.
    @discardableResult
    private func createCoreDataSummary(from cloudSummary: EnhancedSummaryData, appCoordinator: AppDataCoordinator) async throws -> Bool {
        let localRecordingId: UUID?
        if let cloudRecordingId = cloudSummary.recordingId {
            // A cloud recording UUID is authoritative. Do not map it to another local
            // recording by filename when the UUID is present.
            localRecordingId = appCoordinator.getRecording(id: cloudRecordingId)?.id
        } else {
            localRecordingId = appCoordinator.getRecording(url: cloudSummary.recordingURL)?.id
        }

        if let localRecordingId,
           appCoordinator.coreDataManager.getRecording(id: localRecordingId)?.isCloudSyncDisabled == true {
            AppLog.shared.iCloudSync("Skipping cloud summary for a recording marked Keep on This Device", level: .debug)
            return false
        }

        if let recordingId = localRecordingId {
            // Upsert by the cloud summary UUID so restore is idempotent and does not create a
            // second summary for a recording that already has one.
            try appCoordinator.upsertSummary(
                cloudSummary,
                for: recordingId,
                transcriptId: cloudSummary.transcriptId,
                identityPolicy: .incomingSummary
            )
            AppLog.shared.iCloudSync("Upserted linked Core Data entry for cloud summary")
            return true
        } else {
            // Create orphaned summary entry (similar to "summary-only recordings")
            AppLog.shared.iCloudSync("Creating orphaned Core Data summary entry (no local recording/transcript)", level: .debug)
            try await createOrphanedSummaryEntry(cloudSummary, appCoordinator: appCoordinator)
            return true
        }
    }

    /// Creates an orphaned summary entry in Core Data (without recording/transcript links)
    private func createOrphanedSummaryEntry(_ cloudSummary: EnhancedSummaryData, appCoordinator: AppDataCoordinator) async throws {
        _ = try appCoordinator.coreDataManager.upsertOrphanedSummary(cloudSummary)

        AppLog.shared.iCloudSync("Created orphaned Core Data summary entry")
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

    // MARK: - Auto-Backup Methods

    /// Call this after significant data changes (new recording, transcript, or summary)
    /// to schedule an automatic backup to iCloud. The backup is debounced so rapid
    /// changes are batched together.
    func scheduleAutoBackup(appCoordinator: AppDataCoordinator) {
        guard isEnabled else { return }
        guard !isManualCloudTransferInProgress else { return }

        // Calculate how long to wait before firing.
        // If we're inside the throttle window, delay until the window expires
        // (plus the debounce interval). Otherwise just use the debounce interval.
        var delay = autoBackupDebounceInterval
        if let lastBackup = lastAutoBackupDate {
            let elapsed = Date().timeIntervalSince(lastBackup)
            if elapsed < autoBackupMinInterval {
                let remaining = autoBackupMinInterval - elapsed
                delay = remaining + autoBackupDebounceInterval
            }
        }

        // Debounce: reset the timer on each call so we wait for a quiet period
        autoBackupTimer?.invalidate()
        autoBackupTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.performAutoBackup(appCoordinator: appCoordinator)
            }
        }
    }

    private func performAutoBackup(appCoordinator: AppDataCoordinator) async {
        guard isEnabled else { return }
        guard !isManualCloudTransferInProgress else { return }

        // Re-check throttle in case multiple timers fired
        if let lastBackup = lastAutoBackupDate,
           Date().timeIntervalSince(lastBackup) < autoBackupMinInterval {
            return
        }

        // Read user preferences with the same defaults as SettingsView's @AppStorage declarations.
        // UserDefaults.bool returns false for unset keys, so we must check for explicit values.
        let defaults = UserDefaults.standard
        let includeAudio = defaults.object(forKey: "iCloudBackupIncludeAudioFiles") != nil
            ? defaults.bool(forKey: "iCloudBackupIncludeAudioFiles")
            : false  // default: off (audio can be large)
        let includeSettings = defaults.object(forKey: "iCloudBackupIncludeSettings") != nil
            ? defaults.bool(forKey: "iCloudBackupIncludeSettings")
            : true   // default: on
        let includeSensitive = defaults.object(forKey: "iCloudBackupIncludeSensitiveSettings") != nil
            ? defaults.bool(forKey: "iCloudBackupIncludeSensitiveSettings")
            : false  // default: off for sensitive values

        let options = CloudBackupOptions(
            includeAudioFiles: includeAudio,
            includeSettings: includeSettings,
            includeSensitiveSettings: includeSettings && includeSensitive
        )

        do {
            let result = try await backupAllDataToiCloud(appCoordinator: appCoordinator, options: options)
            if !result.wasSkippedNoChanges {
                lastAutoBackupDate = Date()
                AppLog.shared.iCloudSync("Auto-backup complete: \(result.recordingsBackedUp) recordings, \(result.transcriptsBackedUp) transcripts, \(result.summariesBackedUp) summaries")
            } else {
                // Still update the timestamp to avoid retrying immediately
                lastAutoBackupDate = Date()
            }
        } catch {
            AppLog.shared.iCloudSync("Auto-backup failed (will retry on next data change): \(error.localizedDescription)", level: .error)
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
        guard !isManualCloudTransferInProgress else { return }

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
                AppLog.shared.iCloudSync("Skipping full periodic sync - only syncing changes as they occur", level: .debug)
            }
            // Only sync summaries that have been queued for sync
            if !pendingSyncQueue.isEmpty {
                AppLog.shared.iCloudSync("Syncing queued changes (\(pendingSyncQueue.count) items)", level: .debug)
                await performBatchSync()
            }
            return
        case .periodic:
            AppLog.shared.iCloudSync("Performing full periodic sync (legacy mode)")
            // Fall through to existing behavior
        }

        do {
            // Perform battery-aware sync (only in periodic mode)
            try await performBatteryAwareSync()
        } catch {
            AppLog.shared.iCloudSync("Periodic sync failed: \(error.localizedDescription)", level: .error)
            await updateSyncStatus(.failed(error.localizedDescription))
        }
    }

    private func shouldSkipSync() -> Bool {
        if isManualCloudTransferInProgress {
            return true
        }

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

    private func isCloudSyncDisabled(for summary: EnhancedSummaryData) -> Bool {
        guard let recordingId = summary.recordingId else {
            return false
        }
        let context = PersistenceController.shared.container.viewContext
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", recordingId as CVarArg)
        fetchRequest.fetchLimit = 1
        return ((try? context.fetch(fetchRequest).first)?.isCloudSyncDisabled) == true
    }

    private func performBatteryAwareSync() async throws {
        // Apply battery-aware network settings
        if performanceOptimizer.batteryInfo.shouldOptimizeForBattery {
            AppLog.shared.iCloudSync("Using battery-optimized sync settings", level: .debug)

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
        AppLog.shared.iCloudSync("Syncing summaries in batches of \(batchSize)", level: .debug)

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
        tempRecord[CloudKitSummaryRecord.recordingNameField] = CloudKitSummaryRecord.schemaBootstrapRecordingName
        tempRecord[CloudKitSummaryRecord.recordingDateField] = Date()
        tempRecord[CloudKitSummaryRecord.summaryField] = ""
        tempRecord[CloudKitSummaryRecord.tasksField] = Data()
        tempRecord[CloudKitSummaryRecord.remindersField] = Data()
        tempRecord[CloudKitSummaryRecord.titlesField] = Data()
        tempRecord[CloudKitSummaryRecord.contentTypeField] = ContentType.general.rawValue
        tempRecord[CloudKitSummaryRecord.aiMethodField] = CloudKitSummaryRecord.schemaBootstrapAIMethod
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
            AppLog.shared.iCloudSync("Failed to set up CloudKit schema: \(error.localizedDescription)", level: .error)
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
            AppLog.shared.iCloudSync("Failed to encode complex objects: \(error.localizedDescription)", level: .error)
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
            AppLog.shared.iCloudSync("Failed to encode complex objects during update: \(error.localizedDescription)", level: .error)
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

        // Extract IDs with proper UUID conversion. The legacy record name is the
        // summary ID; the parent recording ID lives in its explicit field.
        let recordingId = (record[CloudKitSummaryRecord.recordingIdField] as? String)
            .flatMap { UUID(uuidString: $0) }
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

        // Use the summary ID from the CloudKit record ID.
        let summaryId = UUID(uuidString: record.recordID.recordName) ?? UUID()

        let decodedMetadata = SummaryMetadataCodec.decode(aiMethod)
        let engine = decodedMetadata.engine ?? SummaryMetadataCodec.inferredEngine(from: decodedMetadata.model)

        return EnhancedSummaryData(
            id: summaryId,
            recordingId: recordingId,
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
        AppLog.shared.iCloudSync("Manual sync triggered")
        await performBatchSync()
    }

    /// Tests CloudKit fetch functionality (useful for debugging)
    func testCloudKitFetch() async -> String {
        AppLog.shared.iCloudSync("Testing CloudKit fetch functionality", level: .debug)

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
            _ = try await database.record(for: recordID)
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

    /// Every record type this app has ever written to its private database.
    /// Used only as a backstop sweep for the change-feed enumeration in
    /// `eraseAlliCloudData()`.
    private static let allKnownCloudRecordTypes: [CKRecord.RecordType] = [
        CloudKitSummaryRecord.recordType,
        backupRecordingRecordType,
        backupTranscriptRecordType,
        backupSummaryRecordType,
        backupSettingsRecordType,
        backupContentIndexRecordType,
        backupDeletionRecordType
    ]

    /// Erases everything this app stores in the user's private iCloud database.
    ///
    /// This is the nuclear maintenance option. It deletes every record the app
    /// owns — legacy summary sync records, backup records for recordings,
    /// transcripts and summaries (including their uploaded audio assets), the
    /// backed-up settings and content index records, and the deletion tombstones
    /// that would otherwise suppress a later re-upload. Custom record zones are
    /// dropped whole; the default zone cannot be deleted, so its records are
    /// enumerated and removed in batches.
    ///
    /// Nothing local is touched: Core Data and on-disk audio are left exactly as
    /// they are, so the user can follow this with a fresh backup that repopulates
    /// iCloud from this device.
    func eraseAlliCloudData() async throws -> CloudEraseResult {
        guard isEnabled else {
            throw NSError(
                domain: "iCloudStorageManager",
                code: 4012,
                userInfo: [NSLocalizedDescriptionKey: "Enable iCloud Sync before erasing iCloud data."]
            )
        }

        let container = Self.sharedCloudKitContainer()
        let database = container.privateCloudDatabase
        try await validateiCloudAccountAvailability(using: container)

        // Hold off automatic sync and auto-backup for the whole wipe, otherwise a
        // background upload can repopulate the container while it is being erased.
        isManualCloudTransferInProgress = true
        defer { isManualCloudTransferInProgress = false }

        await updateSyncStatus(.syncing)
        AppLog.shared.iCloudSync("Starting full iCloud erase of this app's private database")

        var result = CloudEraseResult()

        do {
            // Custom zones can be dropped wholesale, which removes their records too.
            let customZoneIDs = try await database.allRecordZones()
                .map { $0.zoneID }
                .filter { $0 != CKRecordZone.default().zoneID }

            if !customZoneIDs.isEmpty {
                let (_, zoneResults) = try await database.modifyRecordZones(
                    saving: [],
                    deleting: customZoneIDs
                )
                for (zoneID, zoneResult) in zoneResults {
                    switch zoneResult {
                    case .success:
                        result.zonesDeleted += 1
                    case .failure(let error):
                        result.failures.append("Zone \(zoneID.zoneName): \(error.localizedDescription)")
                    }
                }
            }

            // The default zone itself cannot be deleted, so remove its records.
            var recordIDs = try await defaultZoneRecordIDs(database: database)
            recordIDs.append(contentsOf: await queriedRecordIDsForKnownTypes(database: database))

            let deletion = try await deleteCloudRecordsInBatches(recordIDs, database: database)
            result.recordsDeleted = deletion.deleted
            result.failures.append(contentsOf: deletion.failures)

            // Forget the local markers describing what is (or was) in iCloud so the next
            // backup uploads a complete fresh copy instead of a delta. Pending deletion
            // queues are dropped too: the records they targeted no longer exist.
            resetLocalCloudSyncBookkeeping()

            if result.failures.isEmpty {
                await updateSyncStatus(.completed)
                AppLog.shared.iCloudSync("iCloud erase complete: \(result.recordsDeleted) records, \(result.zonesDeleted) custom zones")
            } else {
                await updateSyncStatus(.failed("Erase finished with \(result.failures.count) failures"))
                AppLog.shared.iCloudSync("iCloud erase finished with \(result.failures.count) failures", level: .error)
            }

            return result
        } catch {
            await updateSyncStatus(.failed(error.localizedDescription))
            AppLog.shared.iCloudSync("iCloud erase failed: \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    /// Collects the IDs of every record in the private default zone. `desiredKeys`
    /// is empty so CloudKit returns identifiers only and never downloads the audio
    /// assets attached to backup records.
    private func defaultZoneRecordIDs(database: CKDatabase) async throws -> [CKRecord.ID] {
        let zoneID = CKRecordZone.default().zoneID
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = nil
        configuration.desiredKeys = []

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: configuration]
        )
        operation.fetchAllChanges = true

        var recordIDs: [CKRecord.ID] = []
        operation.recordWasChangedBlock = { recordID, _ in
            // Keep the ID even when the record body failed to decode; it still needs deleting.
            recordIDs.append(recordID)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.fetchRecordZoneChangesResultBlock = { continuation.resume(with: $0) }
            database.add(operation)
        }

        AppLog.shared.iCloudSync("Found \(recordIDs.count) records in the default zone to erase", level: .debug)
        return recordIDs
    }

    /// Backstop for the change feed: queries each record type the app knows about.
    /// A type that was never created has no schema to query, which is not a failure
    /// for an erase, so query errors are logged and skipped.
    private func queriedRecordIDsForKnownTypes(database: CKDatabase) async -> [CKRecord.ID] {
        var recordIDs: [CKRecord.ID] = []

        for recordType in Self.allKnownCloudRecordTypes {
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
            do {
                var response = try await database.records(matching: query, desiredKeys: [])
                while true {
                    recordIDs.append(contentsOf: response.matchResults.map { $0.0 })
                    guard let cursor = response.queryCursor else { break }
                    response = try await database.records(continuingMatchFrom: cursor, desiredKeys: [])
                }
            } catch {
                AppLog.shared.iCloudSync("Erase sweep skipped \(recordType): \(error.localizedDescription)", level: .debug)
            }
        }

        return recordIDs
    }

    private func deleteCloudRecordsInBatches(
        _ recordIDs: [CKRecord.ID],
        database: CKDatabase,
        batchSize: Int = 200
    ) async throws -> (deleted: Int, failures: [String]) {
        var seenRecordNames = Set<String>()
        let uniqueRecordIDs = recordIDs.filter { seenRecordNames.insert($0.recordName).inserted }

        var deleted = 0
        var failures: [String] = []

        for start in stride(from: 0, to: uniqueRecordIDs.count, by: batchSize) {
            let batch = Array(uniqueRecordIDs[start..<min(start + batchSize, uniqueRecordIDs.count)])
            let outcome = try await deleteCloudRecordBatch(batch, database: database)
            deleted += outcome.deleted
            failures.append(contentsOf: outcome.failures)
        }

        return (deleted, failures)
    }

    private func deleteCloudRecordBatch(
        _ recordIDs: [CKRecord.ID],
        database: CKDatabase
    ) async throws -> (deleted: Int, failures: [String]) {
        guard !recordIDs.isEmpty else { return (0, []) }

        do {
            let (_, deleteResults) = try await database.modifyRecords(
                saving: [],
                deleting: recordIDs,
                savePolicy: .changedKeys,
                atomically: false
            )

            var deleted = 0
            var failures: [String] = []

            for (recordID, deleteResult) in deleteResults {
                switch deleteResult {
                case .success:
                    deleted += 1
                case .failure(let error as CKError) where error.code == .unknownItem:
                    // Already gone, which is the outcome we wanted.
                    deleted += 1
                case .failure(let error):
                    failures.append("\(recordID.recordName): \(error.localizedDescription)")
                }
            }

            return (deleted, failures)
        } catch let error as CKError where error.code == .limitExceeded && recordIDs.count > 1 {
            // The server rejected the batch as too large; halve it and retry.
            let midpoint = recordIDs.count / 2
            let first = try await deleteCloudRecordBatch(Array(recordIDs[..<midpoint]), database: database)
            let second = try await deleteCloudRecordBatch(Array(recordIDs[midpoint...]), database: database)
            return (first.deleted + second.deleted, first.failures + second.failures)
        }
    }

    /// Clears the local state that describes what already exists in iCloud. Local
    /// recordings, transcripts and summaries are untouched — only sync bookkeeping.
    private func resetLocalCloudSyncBookkeeping() {
        clearSyncState()
        lastSyncDate = nil
        lastAutoBackupDate = nil
        pendingCloudReviewItems = []

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "lastSyncDate")
        defaults.removeObject(forKey: Self.backupStateSignatureKey)
        defaults.removeObject(forKey: Self.activeManifestMigrationCompletedKey)
        defaults.removeObject(forKey: Self.quarantinedBackupRecordNamesKey)
        defaults.removeObject(forKey: Self.quarantinedLegacySummaryRecordNamesKey)
        defaults.removeObject(forKey: Self.pendingDeletionMarkersKey)
        defaults.removeObject(forKey: Self.pendingLocalOnlyRemovalsKey)
        defaults.removeObject(forKey: Self.pendingSummaryRemovalsKey)
        defaults.removeObject(forKey: Self.pendingTranscriptRemovalsKey)
    }

    // MARK: - Private Methods
}

// MARK: - Robust Backup Models

struct CloudBackupOptions {
    var includeAudioFiles: Bool
    var includeSettings: Bool
    var includeSensitiveSettings: Bool
}

/// Outcome of a full erase of the app's private CloudKit database.
struct CloudEraseResult {
    var recordsDeleted: Int = 0
    var zonesDeleted: Int = 0
    /// Human-readable description of anything the server refused to delete.
    var failures: [String] = []
}

struct CloudBackupResult {
    var recordingsBackedUp: Int = 0
    var transcriptsBackedUp: Int = 0
    var summariesBackedUp: Int = 0
    var audioFilesBackedUp: Int = 0
    var audioFilesSkippedUnchanged: Int = 0
    var settingsBackedUp: Bool = false
    var includedSensitiveSettings: Bool = false
    var wasSkippedNoChanges: Bool = false
}

struct CloudRestoreResult {
    var recordingsRestored: Int = 0
    /// Local rows left untouched because this device holds the newer edit.
    var localItemsKeptAsNewer: Int = 0
    var transcriptsRestored: Int = 0
    var summariesRestored: Int = 0
    var audioFilesRestored: Int = 0
    var settingsRestored: Bool = false
    var includedSensitiveSettings: Bool = false
    var itemsHeldForReview: Int = 0
}

struct CloudReconcileResult {
    var backupResult = CloudBackupResult()
    var restoreResult = CloudRestoreResult()
    var deletedLocalRecordings: Int = 0
    var deletedCloudRecords: Int = 0
    /// Items kept because they changed here after another device deleted them.
    var revivedLocalItems: Int = 0
    /// Duplicate local rows removed because a newer row for the same recording won.
    var prunedDuplicateItems: Int = 0
}

/// Outcome of replaying every iCloud deletion marker against this device.
struct DeletionMarkerApplication {
    var deletedLocalItems: Int = 0
    var deletedCloudRecords: Int = 0
    var revivedLocally: Int = 0

    var didChangeAnything: Bool {
        deletedLocalItems > 0 || deletedCloudRecords > 0 || revivedLocally > 0
    }
}

private struct CodableSettingsBackupPayload: Codable {
    let createdAt: Date
    let includesSensitiveValues: Bool
    let sourcePlatform: String?
    let values: [String: Data]
}

private struct BackupContentRecordsFromIndex {
    var recordings: [CKRecord] = []
    var transcripts: [CKRecord] = []
    var summaries: [CKRecord] = []
}

private struct ActiveManifestRecordNames {
    var recordings = Set<String>()
    var transcripts = Set<String>()
    var summaries = Set<String>()
}

private struct CloudReviewItemBuilder {
    var recordingId: UUID?
    var title: String?
    var date: Date?
    var backupRecordNames = Set<String>()
    var legacySummaryRecordNames = Set<String>()
    var hasRecording = false
    var hasAudio = false
    var hasTranscript = false
    var hasSummary = false
    var sourceDeviceIdentifier: String?

    var stableId: String {
        recordingId?.uuidString ??
            backupRecordNames.sorted().first ??
            legacySummaryRecordNames.sorted().first ??
            UUID().uuidString
    }

    func makeItem() -> CloudReviewItem {
        CloudReviewItem(
            id: stableId,
            recordingId: recordingId,
            title: title?.isEmpty == false ? title! : "Cloud item",
            date: date,
            backupRecordNames: backupRecordNames.sorted(),
            legacySummaryRecordNames: legacySummaryRecordNames.sorted(),
            hasRecording: hasRecording,
            hasAudio: hasAudio,
            hasTranscript: hasTranscript,
            hasSummary: hasSummary,
            sourceDeviceIdentifier: sourceDeviceIdentifier
        )
    }
}

private struct BackupIdentifierFixupResult {
    var recordingsAssigned: Int = 0
    var transcriptsAssigned: Int = 0
    var summariesAssigned: Int = 0

    var totalAssigned: Int {
        recordingsAssigned + transcriptsAssigned + summariesAssigned
    }
}

private struct LatestPerRecordingResolution {
    var keptRecords: [CKRecord] = []
    var loserRecordIDs: [CKRecord.ID] = []
}

struct CloudBackupSourceSelection {
    let recordings: [RecordingEntry]
    let transcripts: [TranscriptEntry]
    let summaries: [SummaryEntry]
    let excludedRecordingIds: Set<UUID>
    /// Older duplicate rows for a recording that already has a newer transcript or
    /// summary. Never uploaded, so the cloud copy stops churning.
    var supersededTranscripts: [TranscriptEntry] = []
    var supersededSummaries: [SummaryEntry] = []
}

// MARK: - Robust iCloud Backup Extension

extension iCloudStorageManager {
    private static let backupRecordingRecordType = "CD_BackupRecording"
    private static let backupTranscriptRecordType = "CD_BackupTranscript"
    private static let backupSummaryRecordType = "CD_BackupSummary"
    private static let backupSettingsRecordType = "CD_BackupSettings"
    private static let backupContentIndexRecordType = "CD_BackupContentIndex"
    private static let backupDeletionRecordType = "CD_BackupDeletion"
    private static let missingProductionSchemaErrorCode = 4011
    private static let backupSettingsRecordName = "settings"
    private static let backupContentIndexRecordName = "content_index"
    private static let backupSchemaVersion = 1
    private static let activeManifestSchemaVersion = 2
    private static let backupStateSignatureKey = "iCloudBackupStateSignatureV1"
    private static let activeManifestMigrationCompletedKey = "iCloudActiveManifestMigrationCompletedV2"

    private static var currentSettingsPlatform: String {
#if os(macOS)
        return "macOS"
#else
        return "iOS"
#endif
    }

    private static let ollamaSettingsKeys: Set<String> = [
        "ollamaServerURL",
        "ollamaPort",
        "ollamaModelName",
        "ollamaMaxTokens",
        "ollamaTemperature",
        "ollamaContextTokens",
        "enableOllama"
    ]

    private static let platformSpecificSettingsKeys: Set<String> =
        ollamaSettingsKeys.union(["SelectedAIEngine"])
    private static let quarantinedBackupRecordNamesKey = "iCloudQuarantinedBackupRecordNamesV2"
    private static let quarantinedLegacySummaryRecordNamesKey = "iCloudQuarantinedLegacySummaryRecordNamesV2"
    private static let pendingDeletionMarkersKey = "iCloudPendingDeletionMarkersV1"
    private static let pendingLocalOnlyRemovalsKey = "iCloudPendingLocalOnlyRemovalsV1"
    private static let pendingSummaryRemovalsKey = "iCloudPendingSummaryRemovalsV1"
    private static let pendingTranscriptRemovalsKey = "iCloudPendingTranscriptRemovalsV1"
    private static let backupRecordingRecordPrefix = "backup_recording_"
    private static let backupTranscriptRecordPrefix = "backup_transcript_"
    private static let backupSummaryRecordPrefix = "backup_summary_"
    private static let backupDeletionRecordPrefix = "backup_deletion_"
    private static let backupTranscriptDeletionRecordPrefix = "backup_deletion_transcript_"
    private static let backupSummaryDeletionRecordPrefix = "backup_deletion_summary_"

    private struct PendingCloudDeletionMarker: Codable, Equatable {
        let recordingId: UUID
        var transcriptIds: [UUID]
        var summaryIds: [UUID]
        let requestedAt: Date
    }

    private struct PendingLocalOnlyCloudRemoval: Codable, Equatable {
        let recordingId: UUID
        let requestedAt: Date
    }

    private struct PendingTranscriptCloudRemoval: Codable, Equatable {
        let transcriptId: UUID
        var recordingId: UUID?
        let requestedAt: Date
    }

    private struct PendingSummaryCloudRemoval: Codable, Equatable {
        let summaryId: UUID
        var recordingId: UUID?
        let requestedAt: Date
    }

    private struct CloudDeletionTargets {
        var recordings = Set<UUID>()
        var transcripts = Set<UUID>()
        var summaries = Set<UUID>()
    }

    private static let fieldRecordingName = "recordingName"
    private static let fieldRecordingDate = "recordingDate"
    private static let fieldRecordingURL = "recordingURL"
    private static let fieldCreatedAt = "createdAt"
    private static let fieldLastModified = "lastModified"
    private static let fieldFileSize = "fileSize"
    private static let fieldDuration = "duration"
    private static let fieldAudioQuality = "audioQuality"
    private static let fieldTranscriptionStatus = "transcriptionStatus"
    private static let fieldSummaryStatus = "summaryStatus"
    private static let fieldTranscriptId = "transcriptId"
    private static let fieldSummaryId = "summaryId"
    private static let fieldLocationLatitude = "locationLatitude"
    private static let fieldLocationLongitude = "locationLongitude"
    private static let fieldLocationAccuracy = "locationAccuracy"
    private static let fieldLocationTimestamp = "locationTimestamp"
    private static let fieldLocationAddress = "locationAddress"
    private static let fieldDeviceIdentifier = "deviceIdentifier"

    private static let fieldAudioAsset = "audioAsset"
    private static let fieldAudioFileName = "audioFileName"
    private static let fieldAudioByteCount = "audioByteCount"
    private static let fieldAudioSignature = "audioSignature"

    private static let fieldRecordingId = "recordingId"
    private static let fieldEngine = "engine"
    private static let fieldProcessingTime = "processingTime"
    private static let fieldConfidence = "confidence"
    private static let fieldSegments = "segments"
    private static let fieldSpeakerMappings = "speakerMappings"

    private static let fieldSummaryText = "summary"
    private static let fieldTasks = "tasks"
    private static let fieldReminders = "reminders"
    private static let fieldTitles = "titles"
    private static let fieldContentType = "contentType"
    private static let fieldAIMethod = "aiMethod"
    private static let fieldGeneratedAt = "generatedAt"
    private static let fieldVersion = "version"
    private static let fieldWordCount = "wordCount"
    private static let fieldOriginalLength = "originalLength"
    private static let fieldCompressionRatio = "compressionRatio"

    private static let fieldSettingsPayload = "payload"
    private static let fieldSettingsIncludesSensitive = "includesSensitiveValues"
    private static let fieldSettingsSchemaVersion = "schemaVersion"
    private static let fieldSettingsUpdatedAt = "updatedAt"
    private static let fieldIndexRecordingRecordNames = "recordingRecordNames"
    private static let fieldIndexTranscriptRecordNames = "transcriptRecordNames"
    private static let fieldIndexSummaryRecordNames = "summaryRecordNames"
    private static let fieldManifestSchemaVersion = "manifestSchemaVersion"
    private static let fieldSyncLifecycle = "syncLifecycle"
    private static let fieldSyncSchemaVersion = "syncSchemaVersion"
    private static let fieldSyncUpdatedAt = "syncUpdatedAt"
    private static let fieldDeletedAt = "deletedAt"
    private static let syncLifecycleActive = "active"

    static let backedUpSettingsKeys: [String] = [
        "SelectedAIEngine",
        "selectedTranscriptionEngine",
        "showTranscriptionProgress",
        "summarizationTimeout",
        SummaryDetailLevel.storageKey,
        SummaryThinkingLevel.storageKey,
        "user_preference_time_format",
        "WatchIntegrationEnabled",
        "WatchAutoSync",
        "WatchBatteryAware",
        "isLocationTrackingEnabled",
        "openAICompatibleModel",
        "openAICompatibleBaseURL",
        "openAICompatibleTemperature",
        "openAICompatibleMaxTokens",
        "enableOpenAICompatible",
        "openAICompatibleManualFormatOverride",
        "openAICompatibleManualFormat",
        "googleAIStudioModel",
        "googleAIStudioTemperature",
        "googleAIStudioMaxTokens",
        "enableGoogleAIStudio",
        "mistralBaseURL",
        "mistralModel",
        "mistralTemperature",
        "mistralMaxTokens",
        "enableMistralAI",
        "mistralSupportsJsonResponseFormat",
        "mistralTranscribeModel",
        "mistralTranscribeDiarize",
        "mistralTranscribeLanguage",
        "ollamaServerURL",
        "ollamaPort",
        "ollamaModelName",
        "ollamaMaxTokens",
        "ollamaTemperature",
        "ollamaContextTokens",
        "enableOllama",
        "enableWhisper",
        "whisperServerURL",
        "whisperPort",
        "whisperProtocol",
        FluidAudioModelInfo.SettingsKeys.localSpeakerLabelsEnabled,
        FluidAudioModelInfo.SettingsKeys.selectedLocalSpeakerLabelMethod,
        // On-device MLX configuration. Without the enable flag a restored
        // "MLX Swift" selection would leave the engine switched off, and
        // SummaryManager would silently fall back to some other engine while
        // the UI still shows On Device AI. The model id is restored through a
        // device-RAM clamp, see restoredValue(forKey:rawValue:).
        MLXSwiftSettingsKeys.enabled,
        MLXSwiftSettingsKeys.modelId,
        MLXSwiftSettingsKeys.maxTokens,
        MLXSwiftSettingsKeys.temperature,
        MLXSwiftSettingsKeys.topK,
        MLXSwiftSettingsKeys.topP,
        MLXSwiftSettingsKeys.repetitionPenalty
    ]

    private static let sensitiveSettingKeyFragments: [String] = [
        "apikey",
        "secret",
        "credentials",
        "accesskey"
    ]

    /// Keys that exactly match known credential/token settings (avoids false
    /// positives on configuration keys like "*MaxTokens").
    private static let sensitiveSettingExactSuffixes: [String] = [
        "token",
        "accesstoken",
        "refreshtoken",
        "bearertoken",
        "authtoken"
    ]

    /// CloudKit private database already provides built-in encryption at rest and in transit.
    /// No app-managed encryption key is required for current backups.
    func canEncryptSensitiveSettingsBackup() -> Bool {
        return true
    }

    func backupAllDataToiCloud(
        appCoordinator: AppDataCoordinator,
        options: CloudBackupOptions
    ) async throws -> CloudBackupResult {
        guard isEnabled else {
            throw NSError(
                domain: "iCloudStorageManager",
                code: 4001,
                userInfo: [NSLocalizedDescriptionKey: "Enable iCloud Sync before backing up."]
            )
        }
        isManualCloudTransferInProgress = true
        defer { isManualCloudTransferInProgress = false }

        let container = Self.sharedCloudKitContainer()
        let database = container.privateCloudDatabase

        do {
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
            let containerIdentifier = container.containerIdentifier ?? Self.sharedContainerIdentifier
            AppLog.shared.iCloudSync("Backup context - bundle: \(bundleIdentifier), container: \(containerIdentifier)", level: .debug)

            try await validateiCloudAccountAvailability(using: container)
            await MainActor.run {
                self.syncStatus = .syncing
                self.lastError = nil
            }

            var result = CloudBackupResult()
            var recordingRecordsSaved = 0
            var transcriptRecordsSaved = 0
            var summaryRecordsSaved = 0
            var recordingRecordNames = Set<String>()
            var transcriptRecordNames = Set<String>()
            var summaryRecordNames = Set<String>()
            _ = try await flushPendingiCloudMutations(appCoordinator: appCoordinator)
            _ = try await applyiCloudDeletionMarkers(appCoordinator: appCoordinator)
            let deletionTargets = try await fetchDeletionTargets(database: database)
            let trustedActiveManifest = try await fetchTrustedActiveManifestRecordNames(database: database)
            var activeRecordingRecordNames = trustedActiveManifest.recordings
            var activeTranscriptRecordNames = trustedActiveManifest.transcripts
            var activeSummaryRecordNames = trustedActiveManifest.summaries
            let fileManager = FileManager.default
            let backupSourceSelection = Self.backupSourceSelection(from: appCoordinator.coreDataManager)
            let excludedRecordingIds = backupSourceSelection.excludedRecordingIds
            let recordings = backupSourceSelection.recordings.filter { recording in
                guard let recordingId = recording.id else { return true }
                return !deletionTargets.recordings.contains(recordingId)
            }
            let transcripts = backupSourceSelection.transcripts.filter { transcript in
                guard let transcriptId = transcript.id else { return true }
                if deletionTargets.transcripts.contains(transcriptId) {
                    return false
                }
                return transcript.recordingId.map { !deletionTargets.recordings.contains($0) } ?? true
            }
            let summaries = backupSourceSelection.summaries.filter { summary in
                guard let summaryId = summary.id else { return true }
                if deletionTargets.summaries.contains(summaryId) {
                    return false
                }
                return summary.recordingId.map { !deletionTargets.recordings.contains($0) } ?? true
            }
            AppLog.shared.iCloudSync(
                "Backup source counts - recordings: \(recordings.count), " +
                "transcripts: \(transcripts.count), summaries: \(summaries.count), " +
                "local-only recordings skipped: \(excludedRecordingIds.count)",
                level: .debug
            )

            let idFixup = try ensureBackupIdentifiers(
                recordings: recordings,
                transcripts: transcripts,
                summaries: summaries
            )
            if idFixup.totalAssigned > 0 {
                AppLog.shared.iCloudSync(
                    "Assigned missing backup IDs - recordings: \(idFixup.recordingsAssigned), " +
                    "transcripts: \(idFixup.transcriptsAssigned), summaries: \(idFixup.summariesAssigned)",
                    level: .debug
                )
            }

            let currentBackupStateSignature = computeBackupStateSignature(
                recordings: recordings,
                transcripts: transcripts,
                summaries: summaries,
                appCoordinator: appCoordinator,
                options: options
            )
            if activeManifestMigrationCompleted,
               UserDefaults.standard.string(forKey: Self.backupStateSignatureKey) == currentBackupStateSignature {
                let hasCloudContentBackup = try await cloudHasAnyContentBackupRecord(database: database)
                if hasCloudContentBackup {
                    result.wasSkippedNoChanges = true
                    await MainActor.run {
                        self.lastSyncDate = Date()
                        UserDefaults.standard.set(self.lastSyncDate, forKey: "lastSyncDate")
                        self.syncStatus = .completed
                        self.lastError = nil
                    }
                    return result
                } else {
                    AppLog.shared.iCloudSync(
                        "Local backup signature matched but cloud content backup is empty. " +
                        "Forcing full upload to seed this CloudKit environment."
                    )
                }
            }

            let existingRecordingRecordsById = try await fetchBackupRecordsByUUID(
                recordType: Self.backupRecordingRecordType,
                recordNamePrefix: Self.backupRecordingRecordPrefix,
                database: database
            )
            let excludedRecordingRecordIDs = existingRecordingRecordsById.compactMap { recordingId, record in
                excludedRecordingIds.contains(recordingId) ? record.recordID : nil
            }
            if !excludedRecordingRecordIDs.isEmpty {
                try await deleteBackupRecords(excludedRecordingRecordIDs, database: database)
            }
            recordingRecordNames.formUnion(
                existingRecordingRecordsById.compactMap { recordingId, record in
                    excludedRecordingIds.contains(recordingId) ? nil : record.recordID.recordName
                }
            )
            activeRecordingRecordNames.formUnion(
                existingRecordingRecordsById.compactMap { recordingId, record in
                    excludedRecordingIds.contains(recordingId) || !isActiveBackupRecord(record) ? nil : record.recordID.recordName
                }
            )

            for recording in recordings {
                guard let recordingId = recording.id else { continue }
                var backedUpAudioForRecording = false

                let recordID = CKRecord.ID(
                    recordName: makeBackupRecordName(
                        prefix: Self.backupRecordingRecordPrefix,
                        id: recordingId
                    )
                )
                recordingRecordNames.insert(recordID.recordName)
                activeRecordingRecordNames.insert(recordID.recordName)
                let existingRecord = existingRecordingRecordsById[recordingId]
                let record = existingRecord ?? CKRecord(recordType: Self.backupRecordingRecordType, recordID: recordID)

                var shouldSave = existingRecord == nil
                let stableLastModified = recording.lastModified ?? recording.createdAt ?? recording.recordingDate

                if let existingRecord,
                   !Self.shouldUploadLocalVersion(
                       localTimestamp: localRecordingContentTimestamp(recording),
                       cloudTimestamp: backupRecordContentTimestamp(
                           existingRecord,
                           keys: Self.recordingContentTimestampKeys
                       )
                   ) {
                    // Another device holds a newer edit. Leave its fields alone and let the
                    // restore leg bring them down, but still upload audio it has never seen.
                    var audioChanged = false
                    if options.includeAudioFiles,
                       existingRecord[Self.fieldAudioSignature] == nil,
                       attachAudioBackupIfNeeded(
                           recording: recording,
                           to: record,
                           appCoordinator: appCoordinator,
                           result: &result,
                           changed: &audioChanged
                       ) {
                        try await saveBackupRecord(record, database: database)
                        recordingRecordsSaved += 1
                        result.audioFilesBackedUp += 1
                    }
                    AppLog.shared.iCloudSync(
                        "Kept newer iCloud version of recording \(recordingId.uuidString)",
                        level: .debug
                    )
                    result.recordingsBackedUp += 1
                    continue
                }

                updateStringField(Self.fieldRecordingName, value: recording.recordingName, on: record, changed: &shouldSave)
                updateDateField(Self.fieldRecordingDate, value: recording.recordingDate, on: record, changed: &shouldSave)
                updateStringField(Self.fieldRecordingURL, value: recording.recordingURL, on: record, changed: &shouldSave)
                updateDateField(Self.fieldCreatedAt, value: recording.createdAt, on: record, changed: &shouldSave)
                updateDateField(Self.fieldLastModified, value: stableLastModified, on: record, changed: &shouldSave)
                updateInt64Field(Self.fieldFileSize, value: recording.fileSize, on: record, changed: &shouldSave)
                updateDoubleField(Self.fieldDuration, value: recording.duration, on: record, changed: &shouldSave)
                updateStringField(Self.fieldAudioQuality, value: recording.audioQuality, on: record, changed: &shouldSave)
                updateStringField(Self.fieldTranscriptionStatus, value: recording.transcriptionStatus, on: record, changed: &shouldSave)
                updateStringField(Self.fieldSummaryStatus, value: recording.summaryStatus, on: record, changed: &shouldSave)
                updateStringField(Self.fieldTranscriptId, value: recording.transcriptId?.uuidString, on: record, changed: &shouldSave)
                updateStringField(Self.fieldSummaryId, value: recording.summaryId?.uuidString, on: record, changed: &shouldSave)
                updateDoubleField(Self.fieldLocationLatitude, value: recording.locationLatitude, on: record, changed: &shouldSave)
                updateDoubleField(Self.fieldLocationLongitude, value: recording.locationLongitude, on: record, changed: &shouldSave)
                updateDoubleField(Self.fieldLocationAccuracy, value: recording.locationAccuracy, on: record, changed: &shouldSave)
                updateDateField(Self.fieldLocationTimestamp, value: recording.locationTimestamp, on: record, changed: &shouldSave)
                updateStringField(Self.fieldLocationAddress, value: recording.locationAddress, on: record, changed: &shouldSave)
                updateStringField(Self.fieldDeviceIdentifier, value: deviceIdentifier, on: record, changed: &shouldSave)
                markBackupRecordActive(record, changed: &shouldSave)

                if options.includeAudioFiles {
                    backedUpAudioForRecording = attachAudioBackupIfNeeded(
                        recording: recording,
                        to: record,
                        appCoordinator: appCoordinator,
                        result: &result,
                        changed: &shouldSave
                    )
                }

                if shouldSave {
                    try await saveBackupRecord(record, database: database)
                    recordingRecordsSaved += 1
                }
                result.recordingsBackedUp += 1

                if backedUpAudioForRecording {
                    result.audioFilesBackedUp += 1
                }
            }

            let existingTranscriptRecordsById = try await fetchBackupRecordsByUUID(
                recordType: Self.backupTranscriptRecordType,
                recordNamePrefix: Self.backupTranscriptRecordPrefix,
                database: database
            )
            let excludedTranscriptRecordIDs = existingTranscriptRecordsById.compactMap { _, record in
                backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds)
                    ? record.recordID
                    : nil
            }
            if !excludedTranscriptRecordIDs.isEmpty {
                try await deleteBackupRecords(excludedTranscriptRecordIDs, database: database)
            }
            transcriptRecordNames.formUnion(
                existingTranscriptRecordsById.compactMap { _, record in
                    backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds)
                        ? nil
                        : record.recordID.recordName
                }
            )
            activeTranscriptRecordNames.formUnion(
                existingTranscriptRecordsById.compactMap { _, record in
                    backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds) ||
                        !isActiveBackupRecord(record) ? nil : record.recordID.recordName
                }
            )
            for transcript in transcripts {
                guard let transcriptId = transcript.id else { continue }

                let recordID = CKRecord.ID(
                    recordName: makeBackupRecordName(
                        prefix: Self.backupTranscriptRecordPrefix,
                        id: transcriptId
                    )
                )
                transcriptRecordNames.insert(recordID.recordName)
                activeTranscriptRecordNames.insert(recordID.recordName)
                let existingRecord = existingTranscriptRecordsById[transcriptId]
                let record = existingRecord ?? CKRecord(recordType: Self.backupTranscriptRecordType, recordID: recordID)

                var shouldSave = existingRecord == nil
                let stableLastModified = transcript.lastModified ?? transcript.createdAt ?? Date()

                if let existingRecord,
                   !Self.shouldUploadLocalVersion(
                       localTimestamp: localTranscriptContentTimestamp(transcript),
                       cloudTimestamp: backupRecordContentTimestamp(
                           existingRecord,
                           keys: Self.transcriptContentTimestampKeys
                       )
                   ) {
                    // Another device holds a newer transcript for this id; the restore leg
                    // brings it down rather than this device overwriting it.
                    AppLog.shared.iCloudSync(
                        "Kept newer iCloud version of transcript \(transcriptId.uuidString)",
                        level: .debug
                    )
                    result.transcriptsBackedUp += 1
                    continue
                }
                updateStringField(Self.fieldRecordingId, value: transcript.recordingId?.uuidString, on: record, changed: &shouldSave)
                updateStringField(Self.fieldEngine, value: transcript.engine, on: record, changed: &shouldSave)
                updateDateField(Self.fieldCreatedAt, value: transcript.createdAt, on: record, changed: &shouldSave)
                updateDateField(Self.fieldLastModified, value: stableLastModified, on: record, changed: &shouldSave)
                updateDoubleField(Self.fieldProcessingTime, value: transcript.processingTime, on: record, changed: &shouldSave)
                updateDoubleField(Self.fieldConfidence, value: transcript.confidence, on: record, changed: &shouldSave)
                updateStringField(Self.fieldSegments, value: transcript.segments, on: record, changed: &shouldSave)
                updateStringField(Self.fieldSpeakerMappings, value: transcript.speakerMappings, on: record, changed: &shouldSave)
                updateStringField(Self.fieldDeviceIdentifier, value: deviceIdentifier, on: record, changed: &shouldSave)
                markBackupRecordActive(record, changed: &shouldSave)

                if shouldSave {
                    try await saveBackupRecord(record, database: database)
                    transcriptRecordsSaved += 1
                }
                result.transcriptsBackedUp += 1
            }

            // Keep only the newest transcript per recording in cloud.
            let transcriptQueryRecords = (try? await fetchBackupRecords(
                recordType: Self.backupTranscriptRecordType,
                database: database
            )) ?? []
            let excludedTranscriptQueryRecordIDs = transcriptQueryRecords.compactMap { record in
                backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds)
                    ? record.recordID
                    : nil
            }
            if !excludedTranscriptQueryRecordIDs.isEmpty {
                try await deleteBackupRecords(excludedTranscriptQueryRecordIDs, database: database)
            }
            transcriptRecordNames.formUnion(
                transcriptQueryRecords.compactMap { record in
                    backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds)
                        ? nil
                        : record.recordID.recordName
                }
            )
            activeTranscriptRecordNames.formUnion(
                transcriptQueryRecords.compactMap { record in
                    backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds) ||
                        !isActiveBackupRecord(record) ? nil : record.recordID.recordName
                }
            )
            let transcriptCandidateRecords = try await fetchBackupRecordsByRecordNames(
                Array(transcriptRecordNames),
                expectedRecordType: Self.backupTranscriptRecordType,
                database: database
            )
            let transcriptResolution = resolveLatestRecordsPerRecording(
                transcriptCandidateRecords,
                recordingIdField: Self.fieldRecordingId,
                timestampKeys: [Self.fieldLastModified, Self.fieldCreatedAt]
            )
            if !transcriptResolution.loserRecordIDs.isEmpty {
                try await deleteBackupRecords(transcriptResolution.loserRecordIDs, database: database)
                AppLog.shared.iCloudSync("Removed \(transcriptResolution.loserRecordIDs.count) older transcript backup records", level: .debug)
            }
            transcriptRecordNames = Set(transcriptResolution.keptRecords.map { $0.recordID.recordName })
            activeTranscriptRecordNames.formIntersection(transcriptRecordNames)

            let existingSummaryRecordsById = try await fetchBackupRecordsByUUID(
                recordType: Self.backupSummaryRecordType,
                recordNamePrefix: Self.backupSummaryRecordPrefix,
                database: database
            )
            let excludedSummaryRecordIDs = existingSummaryRecordsById.compactMap { _, record in
                backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds)
                    ? record.recordID
                    : nil
            }
            if !excludedSummaryRecordIDs.isEmpty {
                try await deleteBackupRecords(excludedSummaryRecordIDs, database: database)
            }
            summaryRecordNames.formUnion(
                existingSummaryRecordsById.compactMap { _, record in
                    backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds)
                        ? nil
                        : record.recordID.recordName
                }
            )
            activeSummaryRecordNames.formUnion(
                existingSummaryRecordsById.compactMap { _, record in
                    backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds) ||
                        !isActiveBackupRecord(record) ? nil : record.recordID.recordName
                }
            )
            for summary in summaries {
                guard let summaryId = summary.id else { continue }

                let recordID = CKRecord.ID(
                    recordName: makeBackupRecordName(
                        prefix: Self.backupSummaryRecordPrefix,
                        id: summaryId
                    )
                )
                summaryRecordNames.insert(recordID.recordName)
                activeSummaryRecordNames.insert(recordID.recordName)
                let existingRecord = existingSummaryRecordsById[summaryId]
                let record = existingRecord ?? CKRecord(recordType: Self.backupSummaryRecordType, recordID: recordID)

                var shouldSave = existingRecord == nil
                let stableGeneratedAt = summary.generatedAt ?? summary.recording?.recordingDate ?? Date()

                if let existingRecord,
                   !Self.shouldUploadLocalVersion(
                       localTimestamp: localSummaryContentTimestamp(summary),
                       cloudTimestamp: backupRecordContentTimestamp(
                           existingRecord,
                           keys: Self.summaryContentTimestampKeys
                       )
                   ) {
                    // Another device regenerated this summary more recently.
                    AppLog.shared.iCloudSync(
                        "Kept newer iCloud version of summary \(summaryId.uuidString)",
                        level: .debug
                    )
                    result.summariesBackedUp += 1
                    continue
                }
                updateStringField(Self.fieldRecordingId, value: summary.recordingId?.uuidString, on: record, changed: &shouldSave)
                updateStringField(Self.fieldTranscriptId, value: summary.transcriptId?.uuidString, on: record, changed: &shouldSave)
                updateStringField(Self.fieldSummaryText, value: summary.summary, on: record, changed: &shouldSave)
                updateStringField(Self.fieldTasks, value: summary.tasks, on: record, changed: &shouldSave)
                updateStringField(Self.fieldReminders, value: summary.reminders, on: record, changed: &shouldSave)
                updateStringField(Self.fieldTitles, value: summary.titles, on: record, changed: &shouldSave)
                updateStringField(Self.fieldContentType, value: summary.contentType, on: record, changed: &shouldSave)
                updateStringField(Self.fieldAIMethod, value: summary.aiMethod, on: record, changed: &shouldSave)
                updateDateField(Self.fieldGeneratedAt, value: stableGeneratedAt, on: record, changed: &shouldSave)
                updateIntField(Self.fieldVersion, value: Int(summary.version), on: record, changed: &shouldSave)
                updateIntField(Self.fieldWordCount, value: Int(summary.wordCount), on: record, changed: &shouldSave)
                updateIntField(Self.fieldOriginalLength, value: Int(summary.originalLength), on: record, changed: &shouldSave)
                updateDoubleField(Self.fieldCompressionRatio, value: summary.compressionRatio, on: record, changed: &shouldSave)
                updateDoubleField(Self.fieldConfidence, value: summary.confidence, on: record, changed: &shouldSave)
                updateDoubleField(Self.fieldProcessingTime, value: summary.processingTime, on: record, changed: &shouldSave)
                updateDateField(Self.fieldLastModified, value: stableGeneratedAt, on: record, changed: &shouldSave)
                updateStringField(Self.fieldDeviceIdentifier, value: deviceIdentifier, on: record, changed: &shouldSave)

                updateStringField(Self.fieldRecordingName, value: summary.recording?.recordingName, on: record, changed: &shouldSave)
                updateDateField(Self.fieldRecordingDate, value: summary.recording?.recordingDate, on: record, changed: &shouldSave)
                markBackupRecordActive(record, changed: &shouldSave)

                if shouldSave {
                    try await saveBackupRecord(record, database: database)
                    summaryRecordsSaved += 1
                }
                result.summariesBackedUp += 1
            }

            // Keep only the newest summary per recording in cloud.
            let summaryQueryRecords = (try? await fetchBackupRecords(
                recordType: Self.backupSummaryRecordType,
                database: database
            )) ?? []
            let excludedSummaryQueryRecordIDs = summaryQueryRecords.compactMap { record in
                backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds)
                    ? record.recordID
                    : nil
            }
            if !excludedSummaryQueryRecordIDs.isEmpty {
                try await deleteBackupRecords(excludedSummaryQueryRecordIDs, database: database)
            }
            summaryRecordNames.formUnion(
                summaryQueryRecords.compactMap { record in
                    backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds)
                        ? nil
                        : record.recordID.recordName
                }
            )
            activeSummaryRecordNames.formUnion(
                summaryQueryRecords.compactMap { record in
                    backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds) ||
                        !isActiveBackupRecord(record) ? nil : record.recordID.recordName
                }
            )
            let summaryCandidateRecords = try await fetchBackupRecordsByRecordNames(
                Array(summaryRecordNames),
                expectedRecordType: Self.backupSummaryRecordType,
                database: database
            )
            let summaryResolution = resolveLatestRecordsPerRecording(
                summaryCandidateRecords,
                recordingIdField: Self.fieldRecordingId,
                timestampKeys: [Self.fieldLastModified, Self.fieldGeneratedAt, Self.fieldCreatedAt]
            )
            if !summaryResolution.loserRecordIDs.isEmpty {
                try await deleteBackupRecords(summaryResolution.loserRecordIDs, database: database)
                AppLog.shared.iCloudSync("Removed \(summaryResolution.loserRecordIDs.count) older summary backup records", level: .debug)
            }
            summaryRecordNames = Set(summaryResolution.keptRecords.map { $0.recordID.recordName })
            activeSummaryRecordNames.formIntersection(summaryRecordNames)

            if options.includeSettings {
                let settingsResult = try await backupSettingsToiCloud(
                    database: database,
                    includeSensitiveSettings: options.includeSensitiveSettings
                )
                result.settingsBackedUp = settingsResult.backedUp
                result.includedSensitiveSettings = settingsResult.includedSensitiveSettings
            }

            try await saveBackupContentIndex(
                database: database,
                recordingRecordNames: Array(activeRecordingRecordNames).sorted(),
                transcriptRecordNames: Array(activeTranscriptRecordNames).sorted(),
                summaryRecordNames: Array(activeSummaryRecordNames).sorted()
            )

            let indexedCloudRecords = try await fetchBackupRecordsFromContentIndex(database: database)
            let cloudRecordingCount = indexedCloudRecords.recordings.count
            let cloudTranscriptCount = indexedCloudRecords.transcripts.count
            let cloudSummaryCount = indexedCloudRecords.summaries.count
            AppLog.shared.iCloudSync(
                "Backup write summary - processed [recordings: \(result.recordingsBackedUp), " +
                "transcripts: \(result.transcriptsBackedUp), summaries: \(result.summariesBackedUp)], " +
                "saved this run [recordings: \(recordingRecordsSaved), transcripts: \(transcriptRecordsSaved), " +
                "summaries: \(summaryRecordsSaved)], cloud now [recordings: \(cloudRecordingCount), " +
                "transcripts: \(cloudTranscriptCount), summaries: \(cloudSummaryCount)]",
                level: .debug
            )

            await MainActor.run {
                self.lastSyncDate = Date()
                UserDefaults.standard.set(self.lastSyncDate, forKey: "lastSyncDate")
                UserDefaults.standard.set(currentBackupStateSignature, forKey: Self.backupStateSignatureKey)
                self.syncStatus = .completed
                self.lastError = nil
            }

            return result
        } catch {
            await MainActor.run {
                self.syncStatus = .failed(error.localizedDescription)
                self.lastError = error.localizedDescription
            }
            throw error
        }
    }

    func refreshCloudReviewItems(appCoordinator: AppDataCoordinator) async {
        guard isEnabled else {
            await MainActor.run {
                self.pendingCloudReviewItems = []
                self.cloudReviewError = "Enable iCloud Sync before reviewing cloud items."
            }
            return
        }

        await MainActor.run {
            self.isScanningCloudReviewItems = true
            self.cloudReviewError = nil
        }

        do {
            let container = Self.sharedCloudKitContainer()
            let database = container.privateCloudDatabase
            try await validateiCloudAccountAvailability(using: container)
            let items = try await scanCloudOnlyReviewItems(appCoordinator: appCoordinator, database: database)
            await MainActor.run {
                self.pendingCloudReviewItems = items
                self.cloudReviewError = nil
                self.isScanningCloudReviewItems = false
            }
        } catch {
            await MainActor.run {
                self.cloudReviewError = error.localizedDescription
                self.isScanningCloudReviewItems = false
            }
        }
    }

    private func ensureActiveManifestMigrationScanIfNeeded(
        appCoordinator: AppDataCoordinator,
        database: CKDatabase
    ) async throws -> Int {
        guard !activeManifestMigrationCompleted else {
            return pendingCloudReviewItems.count
        }

        let items = try await scanCloudOnlyReviewItems(appCoordinator: appCoordinator, database: database)
        await MainActor.run {
            self.pendingCloudReviewItems = items
            self.activeManifestMigrationCompleted = true
            if !items.isEmpty {
                self.lastMaintenanceMessage = "\(items.count) older iCloud item\(items.count == 1 ? "" : "s") held for review."
            }
        }
        return items.count
    }

    private func scanCloudOnlyReviewItems(
        appCoordinator: AppDataCoordinator,
        database: CKDatabase
    ) async throws -> [CloudReviewItem] {
        var builders: [String: CloudReviewItemBuilder] = [:]
        let trustedManifest = try await fetchTrustedActiveManifestRecordNames(database: database)

        let localRecordings = appCoordinator.coreDataManager.getAllRecordings()
        let localRecordingIds = Set(localRecordings.compactMap { $0.id })
        let localTranscriptIds = Set(appCoordinator.coreDataManager.getAllTranscripts().compactMap { $0.id })
        let localSummaryIds = Set(appCoordinator.coreDataManager.getAllSummaries().compactMap { $0.id })
        let locallyExcludedRecordingIds = Set(localRecordings.compactMap { recording in
            recording.isCloudSyncDisabled ? recording.id : nil
        })
        let deletionTargets = try await fetchDeletionTargets(database: database)
        let deletedRecordingIds = deletionTargets.recordings

        let recordingRecords = try await fetchBackupRecords(recordType: Self.backupRecordingRecordType, database: database)
        let transcriptRecords = try await fetchBackupRecords(recordType: Self.backupTranscriptRecordType, database: database)
        let summaryRecords = try await fetchBackupRecords(recordType: Self.backupSummaryRecordType, database: database)
        let legacySummaryRecords = try await fetchLegacySummarySyncRecords(database: database)
        var legacySchemaBootstrapRecordIDs: [CKRecord.ID] = []

        for record in recordingRecords {
            guard let recordingId = decodeBackupRecordUUID(
                recordName: record.recordID.recordName,
                prefix: Self.backupRecordingRecordPrefix
            ) else {
                continue
            }
            guard !localRecordingIds.contains(recordingId),
                  !locallyExcludedRecordingIds.contains(recordingId),
                  !deletedRecordingIds.contains(recordingId),
                  !trustedManifest.recordings.contains(record.recordID.recordName),
                  !isActiveBackupRecord(record) else {
                continue
            }

            mergeReviewRecord(
                record,
                recordingId: recordingId,
                kind: .recording,
                builders: &builders
            )
        }

        for record in transcriptRecords {
            guard let transcriptId = decodeBackupRecordUUID(
                recordName: record.recordID.recordName,
                prefix: Self.backupTranscriptRecordPrefix
            ) else {
                continue
            }
            let recordingId = (record[Self.fieldRecordingId] as? String).flatMap { UUID(uuidString: $0) }
            guard !localTranscriptIds.contains(transcriptId),
                  !deletionTargets.transcripts.contains(transcriptId),
                  recordingId.map({ !locallyExcludedRecordingIds.contains($0) && !deletedRecordingIds.contains($0) }) ?? true,
                  !trustedManifest.transcripts.contains(record.recordID.recordName),
                  !isActiveBackupRecord(record) else {
                continue
            }

            mergeReviewRecord(
                record,
                recordingId: recordingId,
                kind: .transcript,
                builders: &builders
            )
        }

        for record in summaryRecords {
            guard let summaryId = decodeBackupRecordUUID(
                recordName: record.recordID.recordName,
                prefix: Self.backupSummaryRecordPrefix
            ) else {
                continue
            }
            let recordingId = (record[Self.fieldRecordingId] as? String).flatMap { UUID(uuidString: $0) }
            guard !localSummaryIds.contains(summaryId),
                  !deletionTargets.summaries.contains(summaryId),
                  recordingId.map({ !locallyExcludedRecordingIds.contains($0) && !deletedRecordingIds.contains($0) }) ?? true,
                  !trustedManifest.summaries.contains(record.recordID.recordName),
                  !isActiveBackupRecord(record) else {
                continue
            }

            mergeReviewRecord(
                record,
                recordingId: recordingId,
                kind: .summary,
                builders: &builders
            )
        }

        for record in legacySummaryRecords {
            if isLegacySchemaBootstrapRecord(record) {
                legacySchemaBootstrapRecordIDs.append(record.recordID)
                continue
            }

            let summaryId = UUID(uuidString: record.recordID.recordName)
            let recordingId = (record[CloudKitSummaryRecord.recordingIdField] as? String).flatMap { UUID(uuidString: $0) }
            guard summaryId.map({ !localSummaryIds.contains($0) }) ?? true,
                  summaryId.map({ !deletionTargets.summaries.contains($0) }) ?? true,
                  recordingId.map({ !locallyExcludedRecordingIds.contains($0) && !deletedRecordingIds.contains($0) }) ?? true else {
                continue
            }

            mergeLegacySummaryReviewRecord(record, recordingId: recordingId, builders: &builders)
        }

        let items = builders.values
            .map { $0.makeItem() }
            .sorted {
                ($0.date ?? Date.distantPast) > ($1.date ?? Date.distantPast)
            }

        if !legacySchemaBootstrapRecordIDs.isEmpty {
            do {
                let deletedCount = try await deleteExistingCloudRecords(legacySchemaBootstrapRecordIDs, database: database)
                if deletedCount > 0 {
                    AppLog.shared.iCloudSync("Cleaned up \(deletedCount) legacy CloudKit schema bootstrap records")
                }
            } catch {
                AppLog.shared.iCloudSync("Could not clean up legacy schema bootstrap records: \(error.localizedDescription)", level: .error)
            }
        }

        quarantinedBackupRecordNames = Set(items.flatMap { $0.backupRecordNames })
        quarantinedLegacySummaryRecordNames = Set(items.flatMap { $0.legacySummaryRecordNames })
        return items
    }

    private enum CloudReviewRecordKind {
        case recording
        case transcript
        case summary
    }

    private func mergeReviewRecord(
        _ record: CKRecord,
        recordingId: UUID?,
        kind: CloudReviewRecordKind,
        builders: inout [String: CloudReviewItemBuilder]
    ) {
        let key = recordingId?.uuidString ?? record.recordID.recordName
        var builder = builders[key] ?? CloudReviewItemBuilder(recordingId: recordingId)
        builder.recordingId = builder.recordingId ?? recordingId
        builder.backupRecordNames.insert(record.recordID.recordName)
        builder.sourceDeviceIdentifier = builder.sourceDeviceIdentifier ?? (record[Self.fieldDeviceIdentifier] as? String)

        switch kind {
        case .recording:
            builder.hasRecording = true
            builder.hasAudio = record[Self.fieldAudioAsset] is CKAsset
            builder.title = builder.title ?? (record[Self.fieldRecordingName] as? String)
            builder.date = builder.date ?? (record[Self.fieldRecordingDate] as? Date)
        case .transcript:
            builder.hasTranscript = true
            builder.date = builder.date ?? (record[Self.fieldCreatedAt] as? Date)
        case .summary:
            builder.hasSummary = true
            builder.title = builder.title ?? (record[Self.fieldRecordingName] as? String)
            builder.date = builder.date ?? (record[Self.fieldGeneratedAt] as? Date) ?? (record[Self.fieldRecordingDate] as? Date)
        }

        builders[key] = builder
    }

    private func mergeLegacySummaryReviewRecord(
        _ record: CKRecord,
        recordingId: UUID?,
        builders: inout [String: CloudReviewItemBuilder]
    ) {
        let key = recordingId?.uuidString ?? record.recordID.recordName
        var builder = builders[key] ?? CloudReviewItemBuilder(recordingId: recordingId)
        builder.recordingId = builder.recordingId ?? recordingId
        builder.legacySummaryRecordNames.insert(record.recordID.recordName)
        builder.hasSummary = true
        builder.title = builder.title ?? (record[CloudKitSummaryRecord.recordingNameField] as? String)
        builder.date = builder.date ?? (record[CloudKitSummaryRecord.generatedAtField] as? Date) ?? (record[CloudKitSummaryRecord.recordingDateField] as? Date)
        builder.sourceDeviceIdentifier = builder.sourceDeviceIdentifier ?? (record[CloudKitSummaryRecord.deviceIdentifierField] as? String)
        builders[key] = builder
    }

    private func isLegacySchemaBootstrapRecord(_ record: CKRecord) -> Bool {
        guard record.recordType == CloudKitSummaryRecord.recordType else {
            return false
        }

        let recordingName = record[CloudKitSummaryRecord.recordingNameField] as? String
        let aiMethod = record[CloudKitSummaryRecord.aiMethodField] as? String
        let summaryText = record[CloudKitSummaryRecord.summaryField] as? String
        let recordingURL = record[CloudKitSummaryRecord.recordingURLField] as? String
        let originalLength = intValue(from: record[CloudKitSummaryRecord.originalLengthField])

        return recordingName == CloudKitSummaryRecord.schemaBootstrapRecordingName &&
            aiMethod == CloudKitSummaryRecord.schemaBootstrapAIMethod &&
            (summaryText?.isEmpty ?? true) &&
            (recordingURL?.isEmpty ?? true) &&
            originalLength == 0
    }

    func restoreCloudReviewItem(
        _ item: CloudReviewItem,
        appCoordinator: AppDataCoordinator,
        includeAudioFiles: Bool
    ) async throws -> CloudRestoreResult {
        guard isEnabled else {
            throw NSError(
                domain: "iCloudStorageManager",
                code: 4006,
                userInfo: [NSLocalizedDescriptionKey: "Enable iCloud Sync before restoring review items."]
            )
        }

        let container = Self.sharedCloudKitContainer()
        let database = container.privateCloudDatabase
        try await validateiCloudAccountAvailability(using: container)

        let recordingRecords = try await fetchBackupRecordsByRecordNames(
            item.backupRecordNames,
            expectedRecordType: Self.backupRecordingRecordType,
            database: database
        )
        let transcriptRecords = try await fetchBackupRecordsByRecordNames(
            item.backupRecordNames,
            expectedRecordType: Self.backupTranscriptRecordType,
            database: database
        )
        let summaryRecords = try await fetchBackupRecordsByRecordNames(
            item.backupRecordNames,
            expectedRecordType: Self.backupSummaryRecordType,
            database: database
        )

        for record in recordingRecords + transcriptRecords + summaryRecords {
            var shouldSave = false
            markBackupRecordActive(record, changed: &shouldSave)
            if shouldSave {
                try await saveBackupRecord(record, database: database)
            }
        }

        removeQuarantineEntries(
            backupRecordNames: item.backupRecordNames,
            legacySummaryRecordNames: item.legacySummaryRecordNames
        )

        let trustedManifest = try await fetchTrustedActiveManifestRecordNames(database: database)
        try await saveBackupContentIndex(
            database: database,
            recordingRecordNames: Array(trustedManifest.recordings.union(recordingRecords.map { $0.recordID.recordName })).sorted(),
            transcriptRecordNames: Array(trustedManifest.transcripts.union(transcriptRecords.map { $0.recordID.recordName })).sorted(),
            summaryRecordNames: Array(trustedManifest.summaries.union(summaryRecords.map { $0.recordID.recordName })).sorted()
        )

        var result = CloudRestoreResult()
        if !recordingRecords.isEmpty || !transcriptRecords.isEmpty || !summaryRecords.isEmpty {
            result = try await restoreAllDataFromiCloud(
                appCoordinator: appCoordinator,
                includeAudioFiles: includeAudioFiles,
                restoreSettings: false
            )
        }

        let legacyRestored = try await restoreSelectedLegacySummaryRecords(
            recordNames: item.legacySummaryRecordNames,
            appCoordinator: appCoordinator,
            database: database
        )
        result.summariesRestored += legacyRestored

        await refreshCloudReviewItems(appCoordinator: appCoordinator)
        await MainActor.run {
            self.lastMaintenanceMessage = "Restored \(item.title) from iCloud review."
        }
        return result
    }

    func deleteCloudReviewItem(_ item: CloudReviewItem) async throws -> Int {
        guard isEnabled else {
            throw NSError(
                domain: "iCloudStorageManager",
                code: 4007,
                userInfo: [NSLocalizedDescriptionKey: "Enable iCloud Sync before deleting review items."]
            )
        }

        let container = Self.sharedCloudKitContainer()
        let database = container.privateCloudDatabase
        try await validateiCloudAccountAvailability(using: container)

        var recordIDs = item.backupRecordNames.map { CKRecord.ID(recordName: $0) }
        recordIDs.append(contentsOf: item.legacySummaryRecordNames.map { CKRecord.ID(recordName: $0) })

        let deletedCount = try await deleteExistingCloudRecords(recordIDs, database: database)
        try await removeBackupRecordNamesFromContentIndex(
            database: database,
            recordingRecordNames: item.backupRecordNames.filter { $0.hasPrefix(Self.backupRecordingRecordPrefix) },
            transcriptRecordNames: item.backupRecordNames.filter { $0.hasPrefix(Self.backupTranscriptRecordPrefix) },
            summaryRecordNames: item.backupRecordNames.filter { $0.hasPrefix(Self.backupSummaryRecordPrefix) }
        )

        removeQuarantineEntries(
            backupRecordNames: item.backupRecordNames,
            legacySummaryRecordNames: item.legacySummaryRecordNames
        )
        await MainActor.run {
            self.pendingCloudReviewItems.removeAll { $0.id == item.id }
            self.lastMaintenanceMessage = "Deleted \(item.title) from iCloud review records."
        }
        return deletedCount
    }

    func restoreAllDataFromiCloud(
        appCoordinator: AppDataCoordinator,
        includeAudioFiles: Bool,
        restoreSettings: Bool
    ) async throws -> CloudRestoreResult {
        guard isEnabled else {
            throw NSError(
                domain: "iCloudStorageManager",
                code: 4002,
                userInfo: [NSLocalizedDescriptionKey: "Enable iCloud Sync before restoring."]
            )
        }
        isManualCloudTransferInProgress = true
        defer { isManualCloudTransferInProgress = false }

        let container = Self.sharedCloudKitContainer()
        let database = container.privateCloudDatabase

        do {
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
            let containerIdentifier = container.containerIdentifier ?? Self.sharedContainerIdentifier
            AppLog.shared.iCloudSync("Restore context - bundle: \(bundleIdentifier), container: \(containerIdentifier)", level: .debug)

            try await validateiCloudAccountAvailability(using: container)
            await MainActor.run {
                self.syncStatus = .syncing
                self.lastError = nil
            }

            var result = CloudRestoreResult()
            let context = appCoordinator.coreDataManager.managedObjectContext
            let fileManager = FileManager.default
            _ = try await flushPendingiCloudMutations(appCoordinator: appCoordinator)
            _ = try await applyiCloudDeletionMarkers(appCoordinator: appCoordinator)
            let deletionTargets = try await fetchDeletionTargets(database: database)

            var recordingRecords = try await fetchBackupRecords(
                recordType: Self.backupRecordingRecordType,
                database: database
            )
            var transcriptRecords = try await fetchBackupRecords(
                recordType: Self.backupTranscriptRecordType,
                database: database
            )
            var summaryRecords = try await fetchBackupRecords(
                recordType: Self.backupSummaryRecordType,
                database: database
            )

            if recordingRecords.isEmpty, transcriptRecords.isEmpty, summaryRecords.isEmpty {
                let indexedRecords = try await fetchBackupRecordsFromContentIndex(database: database)
                if !indexedRecords.recordings.isEmpty ||
                    !indexedRecords.transcripts.isEmpty ||
                    !indexedRecords.summaries.isEmpty {
                    recordingRecords = indexedRecords.recordings
                    transcriptRecords = indexedRecords.transcripts
                    summaryRecords = indexedRecords.summaries
                    AppLog.shared.iCloudSync(
                        "Restore fallback via content index - recordings: \(recordingRecords.count), " +
                        "transcripts: \(transcriptRecords.count), summaries: \(summaryRecords.count)",
                        level: .debug
                    )
                }
            }

            let locallyExcludedRecordingIds = Set(appCoordinator.coreDataManager.getAllRecordings().compactMap { recording in
                recording.isCloudSyncDisabled ? recording.id : nil
            })
            if !locallyExcludedRecordingIds.isEmpty {
                recordingRecords = recordingRecords.filter { record in
                    guard let recordingId = decodeBackupRecordUUID(
                        recordName: record.recordID.recordName,
                        prefix: Self.backupRecordingRecordPrefix
                    ) else {
                        return true
                    }
                    return !locallyExcludedRecordingIds.contains(recordingId)
                }
                transcriptRecords = transcriptRecords.filter {
                    !backupRecordBelongsToExcludedRecording($0, excludedRecordingIds: locallyExcludedRecordingIds)
                }
                summaryRecords = summaryRecords.filter {
                    !backupRecordBelongsToExcludedRecording($0, excludedRecordingIds: locallyExcludedRecordingIds)
                }
            }

            recordingRecords = recordingRecords.filter { record in
                guard let recordingId = decodeBackupRecordUUID(
                    recordName: record.recordID.recordName,
                    prefix: Self.backupRecordingRecordPrefix
                ) else {
                    return false
                }
                return !deletionTargets.recordings.contains(recordingId)
            }
            transcriptRecords = transcriptRecords.filter { record in
                guard let transcriptId = decodeBackupRecordUUID(
                    recordName: record.recordID.recordName,
                    prefix: Self.backupTranscriptRecordPrefix
                ) else {
                    return false
                }
                guard !deletionTargets.transcripts.contains(transcriptId) else {
                    return false
                }
                guard let recordingId = (record[Self.fieldRecordingId] as? String).flatMap({ UUID(uuidString: $0) }) else {
                    return true
                }
                return !deletionTargets.recordings.contains(recordingId)
            }
            summaryRecords = summaryRecords.filter { record in
                guard let summaryId = decodeBackupRecordUUID(
                    recordName: record.recordID.recordName,
                    prefix: Self.backupSummaryRecordPrefix
                ) else {
                    return false
                }
                guard !deletionTargets.summaries.contains(summaryId) else {
                    return false
                }
                guard let recordingId = (record[Self.fieldRecordingId] as? String).flatMap({ UUID(uuidString: $0) }) else {
                    return true
                }
                return !deletionTargets.recordings.contains(recordingId)
            }

            // A child tombstone must also win over stale relationship fields on a
            // parent record captured before the cloud-side cleanup completed. Keep
            // the surviving parent/summary, but never restore a deleted child link.
            recordingRecords = recordingRecords.map { record in
                if let transcriptId = (record[Self.fieldTranscriptId] as? String)
                    .flatMap(UUID.init(uuidString:)),
                   deletionTargets.transcripts.contains(transcriptId) {
                    record[Self.fieldTranscriptId] = nil
                    record[Self.fieldTranscriptionStatus] = ProcessingStatus.notStarted.rawValue
                }
                if let summaryId = (record[Self.fieldSummaryId] as? String)
                    .flatMap(UUID.init(uuidString:)),
                   deletionTargets.summaries.contains(summaryId) {
                    record[Self.fieldSummaryId] = nil
                    record[Self.fieldSummaryStatus] = ProcessingStatus.notStarted.rawValue
                }
                return record
            }
            summaryRecords = summaryRecords.map { record in
                if let transcriptId = (record[Self.fieldTranscriptId] as? String)
                    .flatMap(UUID.init(uuidString:)),
                   deletionTargets.transcripts.contains(transcriptId) {
                    record[Self.fieldTranscriptId] = nil
                }
                return record
            }

            let trustedActiveManifest = try await fetchTrustedActiveManifestRecordNames(database: database)
            let deletedRecordingIds = deletionTargets.recordings
            var backupRecordNamesHeldForReview = quarantinedBackupRecordNames
            var heldReviewKeys = Set<String>()
            var heldRecordingIds = Set<UUID>()

            func holdBackupRecordForReview(_ record: CKRecord, recordingId: UUID?) {
                backupRecordNamesHeldForReview.insert(record.recordID.recordName)
                let reviewKey = recordingId?.uuidString ?? record.recordID.recordName
                heldReviewKeys.insert(reviewKey)
                if let recordingId {
                    heldRecordingIds.insert(recordingId)
                }
            }

            func shouldRestoreCloudOnlyRecord(
                _ record: CKRecord,
                trustedRecordNames: Set<String>
            ) -> Bool {
                if backupRecordNamesHeldForReview.contains(record.recordID.recordName) {
                    return false
                }
                return trustedRecordNames.contains(record.recordID.recordName) || isActiveBackupRecord(record)
            }

            AppLog.shared.iCloudSync(
                "Backup restore candidates - recordings: \(recordingRecords.count), " +
                "transcripts: \(transcriptRecords.count), summaries: \(summaryRecords.count)",
                level: .debug
            )

            // Resolve duplicate transcript/summary records for the same recording by timestamp.
            let transcriptResolution = resolveLatestRecordsPerRecording(
                transcriptRecords,
                recordingIdField: Self.fieldRecordingId,
                timestampKeys: [Self.fieldLastModified, Self.fieldCreatedAt]
            )
            if transcriptResolution.keptRecords.count != transcriptRecords.count {
                AppLog.shared.iCloudSync(
                    "Restore selected newest transcript per recording; " +
                    "ignored \(transcriptRecords.count - transcriptResolution.keptRecords.count) older records",
                    level: .debug
                )
            }
            transcriptRecords = transcriptResolution.keptRecords

            let summaryResolution = resolveLatestRecordsPerRecording(
                summaryRecords,
                recordingIdField: Self.fieldRecordingId,
                timestampKeys: [Self.fieldLastModified, Self.fieldGeneratedAt, Self.fieldCreatedAt]
            )
            if summaryResolution.keptRecords.count != summaryRecords.count {
                AppLog.shared.iCloudSync(
                    "Restore selected newest summary per recording; " +
                    "ignored \(summaryRecords.count - summaryResolution.keptRecords.count) older records",
                    level: .debug
                )
            }
            summaryRecords = summaryResolution.keptRecords

            var recordingsById = [UUID: RecordingEntry]()
            for recording in appCoordinator.coreDataManager.getAllRecordings() {
                if let id = recording.id {
                    recordingsById[id] = recording
                }
            }

            for record in recordingRecords {
                guard let recordingId = decodeBackupRecordUUID(
                    recordName: record.recordID.recordName,
                    prefix: Self.backupRecordingRecordPrefix
                ) else {
                    continue
                }
                let existing = recordingsById[recordingId]
                if existing == nil {
                    if deletedRecordingIds.contains(recordingId) ||
                        !shouldRestoreCloudOnlyRecord(record, trustedRecordNames: trustedActiveManifest.recordings) {
                        holdBackupRecordForReview(record, recordingId: recordingId)
                        continue
                    }
                }
                let entry = existing ?? RecordingEntry(context: context)

                if existing == nil {
                    entry.id = recordingId
                    result.recordingsRestored += 1
                }

                let applyCloudRecording = existing.map { local in
                    Self.shouldApplyCloudVersion(
                        cloudTimestamp: backupRecordContentTimestamp(
                            record,
                            keys: Self.recordingContentTimestampKeys
                        ),
                        localTimestamp: localRecordingContentTimestamp(local)
                    )
                } ?? true

                if applyCloudRecording {
                    entry.recordingName = record[Self.fieldRecordingName] as? String
                    entry.recordingDate = record[Self.fieldRecordingDate] as? Date
                    entry.createdAt = record[Self.fieldCreatedAt] as? Date
                    entry.lastModified = record[Self.fieldLastModified] as? Date
                    entry.fileSize = int64Value(from: record[Self.fieldFileSize])
                    entry.duration = doubleValue(from: record[Self.fieldDuration])
                    entry.audioQuality = record[Self.fieldAudioQuality] as? String
                    entry.transcriptionStatus = record[Self.fieldTranscriptionStatus] as? String
                    entry.summaryStatus = record[Self.fieldSummaryStatus] as? String
                    entry.transcriptId = (record[Self.fieldTranscriptId] as? String).flatMap { UUID(uuidString: $0) }
                    entry.summaryId = (record[Self.fieldSummaryId] as? String).flatMap { UUID(uuidString: $0) }
                    entry.locationLatitude = doubleValue(from: record[Self.fieldLocationLatitude])
                    entry.locationLongitude = doubleValue(from: record[Self.fieldLocationLongitude])
                    entry.locationAccuracy = doubleValue(from: record[Self.fieldLocationAccuracy])
                    entry.locationTimestamp = record[Self.fieldLocationTimestamp] as? Date
                    entry.locationAddress = record[Self.fieldLocationAddress] as? String
                } else {
                    // This device has the newer edit; the backup leg already declined to
                    // overwrite the cloud copy, so leave the local row untouched.
                    result.localItemsKeptAsNewer += 1
                }

                if includeAudioFiles,
                   let asset = record[Self.fieldAudioAsset] as? CKAsset,
                   let assetURL = asset.fileURL,
                   fileManager.fileExists(atPath: assetURL.path) {
                    let backupFileName = (record[Self.fieldAudioFileName] as? String) ?? "\(recordingId.uuidString).m4a"
                    // Use recording ID as the filename to avoid collisions when
                    // multiple recordings share the same original basename.
                    let fileExtension = (backupFileName as NSString).pathExtension.isEmpty ? "m4a" : (backupFileName as NSString).pathExtension
                    let uniqueFileName = "\(recordingId.uuidString).\(fileExtension)"
                    let destinationURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent(uniqueFileName)

                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try? fileManager.removeItem(at: destinationURL)
                    }

                    try fileManager.copyItem(at: assetURL, to: destinationURL)
                    entry.recordingURL = appCoordinator.coreDataManager.urlToRelativePath(destinationURL) ?? uniqueFileName
                    result.audioFilesRestored += 1
                } else if existing == nil {
                    // Keep metadata-only records when audio backup is disabled or unavailable.
                    entry.recordingURL = nil
                }

                recordingsById[recordingId] = entry
            }

            var transcriptsById = [UUID: TranscriptEntry]()
            for transcript in appCoordinator.coreDataManager.getAllTranscripts() {
                if let id = transcript.id {
                    transcriptsById[id] = transcript
                }
            }

            for record in transcriptRecords {
                guard let transcriptId = decodeBackupRecordUUID(
                    recordName: record.recordID.recordName,
                    prefix: Self.backupTranscriptRecordPrefix
                ) else {
                    continue
                }
                let existing = transcriptsById[transcriptId]
                let recordingId = (record[Self.fieldRecordingId] as? String).flatMap { UUID(uuidString: $0) }
                if existing == nil {
                    if recordingId.map({ deletedRecordingIds.contains($0) || heldRecordingIds.contains($0) }) == true ||
                        !shouldRestoreCloudOnlyRecord(record, trustedRecordNames: trustedActiveManifest.transcripts) {
                        holdBackupRecordForReview(record, recordingId: recordingId)
                        continue
                    }
                }
                let entry = existing ?? TranscriptEntry(context: context)

                if existing == nil {
                    entry.id = transcriptId
                    result.transcriptsRestored += 1
                }

                let applyCloudTranscript = existing.map { local in
                    Self.shouldApplyCloudVersion(
                        cloudTimestamp: backupRecordContentTimestamp(
                            record,
                            keys: Self.transcriptContentTimestampKeys
                        ),
                        localTimestamp: localTranscriptContentTimestamp(local)
                    )
                } ?? true

                if applyCloudTranscript {
                    entry.recordingId = recordingId
                    entry.engine = record[Self.fieldEngine] as? String
                    entry.createdAt = record[Self.fieldCreatedAt] as? Date
                    entry.lastModified = record[Self.fieldLastModified] as? Date
                    entry.processingTime = doubleValue(from: record[Self.fieldProcessingTime])
                    entry.confidence = doubleValue(from: record[Self.fieldConfidence])
                    entry.segments = record[Self.fieldSegments] as? String
                    entry.speakerMappings = record[Self.fieldSpeakerMappings] as? String
                } else {
                    result.localItemsKeptAsNewer += 1
                }

                if let recordingId, let recording = recordingsById[recordingId] {
                    entry.recording = recording
                    recording.transcript = entry
                    recording.transcriptId = transcriptId
                    if recording.transcriptionStatus == nil || recording.transcriptionStatus?.isEmpty == true {
                        recording.transcriptionStatus = ProcessingStatus.completed.rawValue
                    }
                }

                transcriptsById[transcriptId] = entry
            }

            var summariesById = [UUID: SummaryEntry]()
            for summary in appCoordinator.coreDataManager.getAllSummaries() {
                if let id = summary.id {
                    summariesById[id] = summary
                }
            }

            for record in summaryRecords {
                guard let summaryId = decodeBackupRecordUUID(
                    recordName: record.recordID.recordName,
                    prefix: Self.backupSummaryRecordPrefix
                ) else {
                    continue
                }
                let existing = summariesById[summaryId]
                let recordingId = (record[Self.fieldRecordingId] as? String).flatMap { UUID(uuidString: $0) }
                if existing == nil {
                    if recordingId.map({ deletedRecordingIds.contains($0) || heldRecordingIds.contains($0) }) == true ||
                        !shouldRestoreCloudOnlyRecord(record, trustedRecordNames: trustedActiveManifest.summaries) {
                        holdBackupRecordForReview(record, recordingId: recordingId)
                        continue
                    }
                }
                let entry = existing ?? SummaryEntry(context: context)

                if existing == nil {
                    entry.id = summaryId
                    result.summariesRestored += 1
                }

                let transcriptId = (record[Self.fieldTranscriptId] as? String).flatMap { UUID(uuidString: $0) }

                let applyCloudSummary = existing.map { local in
                    Self.shouldApplyCloudVersion(
                        cloudTimestamp: backupRecordContentTimestamp(
                            record,
                            keys: Self.summaryContentTimestampKeys
                        ),
                        localTimestamp: localSummaryContentTimestamp(local)
                    )
                } ?? true

                if applyCloudSummary {
                    entry.recordingId = recordingId
                    entry.transcriptId = transcriptId
                    entry.summary = record[Self.fieldSummaryText] as? String
                    entry.tasks = record[Self.fieldTasks] as? String
                    entry.reminders = record[Self.fieldReminders] as? String
                    entry.titles = record[Self.fieldTitles] as? String
                    entry.contentType = record[Self.fieldContentType] as? String
                    entry.aiMethod = record[Self.fieldAIMethod] as? String
                    entry.generatedAt = record[Self.fieldGeneratedAt] as? Date
                    entry.version = Int32(intValue(from: record[Self.fieldVersion], defaultValue: 1))
                    entry.wordCount = Int32(intValue(from: record[Self.fieldWordCount]))
                    entry.originalLength = Int32(intValue(from: record[Self.fieldOriginalLength]))
                    entry.compressionRatio = doubleValue(from: record[Self.fieldCompressionRatio])
                    entry.confidence = doubleValue(from: record[Self.fieldConfidence])
                    entry.processingTime = doubleValue(from: record[Self.fieldProcessingTime])
                } else {
                    result.localItemsKeptAsNewer += 1
                }

                if let recordingId, let recording = recordingsById[recordingId] {
                    entry.recording = recording
                    recording.summary = entry
                    recording.summaryId = summaryId
                    if recording.summaryStatus == nil || recording.summaryStatus?.isEmpty == true {
                        recording.summaryStatus = ProcessingStatus.completed.rawValue
                    }
                }

                if let transcriptId, let transcript = transcriptsById[transcriptId] {
                    entry.transcript = transcript
                }

                summariesById[summaryId] = entry
            }

            var restoredSettings = false
            var restoredSensitiveSettings = false
            if restoreSettings {
                let settingsResult = try await restoreSettingsFromiCloud(database: database)
                restoredSettings = settingsResult.restored
                restoredSensitiveSettings = settingsResult.includedSensitiveSettings
            }

            let hasContentBackupRecords =
                !recordingRecords.isEmpty ||
                !transcriptRecords.isEmpty ||
                !summaryRecords.isEmpty
            if !hasContentBackupRecords {
                // Try falling back to CloudKit summary-sync records.
                // Use try? so that CloudKit errors don't replace the more
                // helpful "run Backup Now" message below.
                let reviewItems = (try? await scanCloudOnlyReviewItems(appCoordinator: appCoordinator, database: database)) ?? []
                result.itemsHeldForReview += reviewItems.count
            }

            if !backupRecordNamesHeldForReview.isEmpty {
                quarantinedBackupRecordNames = backupRecordNamesHeldForReview
            }
            result.itemsHeldForReview += heldReviewKeys.count

            if !hasContentBackupRecords, result.itemsHeldForReview == 0 {
                let settingsSuffix = restoredSettings
                    ? " Settings were restored."
                    : ""
                throw NSError(
                    domain: "iCloudStorageManager",
                    code: 4005,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No recordings, transcripts, or summaries backup records were found in iCloud." +
                            settingsSuffix +
                            " Run Backup Now on the source device and ensure both devices use the same app build channel (both Debug or both TestFlight/App Store)."
                    ]
                )
            }

            try context.save()

            await MainActor.run {
                self.lastSyncDate = Date()
                UserDefaults.standard.set(self.lastSyncDate, forKey: "lastSyncDate")
                self.syncStatus = .completed
                self.lastError = nil
            }

            result.settingsRestored = restoredSettings
            result.includedSensitiveSettings = restoredSensitiveSettings

            return result
        } catch {
            await MainActor.run {
                self.syncStatus = .failed(error.localizedDescription)
                self.lastError = error.localizedDescription
            }
            throw error
        }
    }

    private func restoreSummariesFromCloudIfAvailable(
        appCoordinator: AppDataCoordinator,
        existingSummaryIds: Set<UUID>,
        database: CKDatabase
    ) async throws -> Int {
        // Try the paginated query first. Catch any thrown errors (e.g. non-queryable
        // schema fields) so we can fall through to the schema-safe path instead of
        // propagating the error to the call site where try? would silently return 0.
        var cloudSummaries: [EnhancedSummaryData]
        do {
            cloudSummaries = try await fetchAllSummariesFromCloud(using: database)
        } catch {
            AppLog.shared.iCloudSync("Query threw error (\(error.localizedDescription)), trying schema-safe record discovery", level: .error)
            cloudSummaries = []
        }

        // If the query returned nothing or threw, it may be a non-queryable schema issue.
        // Fall back to the schema-safe record-operation approach which uses
        // UUID scanning + zone change tracking instead of CKQuery.
        if cloudSummaries.isEmpty {
            // Ensure self.database is available for the schema-safe helpers
            // (they guard on self.database, which may be nil on a fresh session).
            if self.database == nil {
                self.database = database
            }
            AppLog.shared.iCloudSync("Query returned 0 summaries, trying schema-safe record discovery", level: .debug)
            cloudSummaries = (try? await fetchAllSummariesUsingRecordOperation(appCoordinator: appCoordinator)) ?? []
        }

        guard !cloudSummaries.isEmpty else {
            return 0
        }

        var restoredCount = 0
        for cloudSummary in cloudSummaries {
            if existingSummaryIds.contains(cloudSummary.id) {
                continue
            }

            let didPersist = try await createCoreDataSummary(from: cloudSummary, appCoordinator: appCoordinator)
            if didPersist {
                restoredCount += 1
            }
        }

        if restoredCount > 0 {
            AppLog.shared.iCloudSync("Restored \(restoredCount) summaries from CloudKit summary sync records")
        }

        return restoredCount
    }

    private func restoreSelectedLegacySummaryRecords(
        recordNames: [String],
        appCoordinator: AppDataCoordinator,
        database: CKDatabase
    ) async throws -> Int {
        var restoredCount = 0
        let existingSummaryIds = Set(appCoordinator.coreDataManager.getAllSummaries().compactMap { $0.id })
        let deletionTargets = try await fetchDeletionTargets(database: database)

        for recordName in recordNames {
            do {
                let record = try await database.record(for: CKRecord.ID(recordName: recordName))
                guard record.recordType == CloudKitSummaryRecord.recordType else {
                    continue
                }
                let summary = try createEnhancedSummaryData(from: record)
                guard let summary = filterDeletedSummaryData(
                    [summary],
                    deletionTargets: deletionTargets
                ).first else {
                    continue
                }
                if existingSummaryIds.contains(summary.id) {
                    continue
                }
                let didPersist = try await createCoreDataSummary(from: summary, appCoordinator: appCoordinator)
                if didPersist {
                    restoredCount += 1
                }
            } catch let error as CKError where error.code == .unknownItem {
                continue
            }
        }

        if restoredCount > 0 {
            _ = try? await backupAllDataToiCloud(
                appCoordinator: appCoordinator,
                options: currentCloudBackupOptions()
            )
        }
        return restoredCount
    }

    func reconcileAllDataWithiCloud(
        appCoordinator: AppDataCoordinator,
        reason: String
    ) async throws -> CloudReconcileResult {
        guard isEnabled else {
            return CloudReconcileResult()
        }
        guard !isManualCloudTransferInProgress,
              !isAutomaticCloudReconcileInProgress else {
            return CloudReconcileResult()
        }
        guard networkStatus.canSync else {
            throw NSError(
                domain: "iCloudStorageManager",
                code: 4010,
                userInfo: [NSLocalizedDescriptionKey: "Network unavailable."]
            )
        }

        isAutomaticCloudReconcileInProgress = true
        isAutomaticReconcileRunning = true
        defer {
            isAutomaticCloudReconcileInProgress = false
            isAutomaticReconcileRunning = false
        }

        let options = currentCloudBackupOptions()
        var result = CloudReconcileResult()
        _ = try await flushPendingiCloudMutations(appCoordinator: appCoordinator)
        let deletionResult = try await applyiCloudDeletionMarkers(appCoordinator: appCoordinator)
        result.deletedLocalRecordings = deletionResult.deletedLocalItems
        result.deletedCloudRecords = deletionResult.deletedCloudRecords
        result.revivedLocalItems = deletionResult.revivedLocally
        result.backupResult = try await backupAllDataToiCloud(appCoordinator: appCoordinator, options: options)
        let container = Self.sharedCloudKitContainer()
        let database = container.privateCloudDatabase
        _ = try await ensureActiveManifestMigrationScanIfNeeded(
            appCoordinator: appCoordinator,
            database: database
        )
        result.restoreResult = try await restoreAllDataFromiCloud(
            appCoordinator: appCoordinator,
            includeAudioFiles: options.includeAudioFiles,
            restoreSettings: options.includeSettings
        )

        // The restore leg has just pointed every recording at the winning transcript and
        // summary, so any duplicate left behind is now safe to drop.
        let pruned = pruneSupersededLocalDuplicates(appCoordinator: appCoordinator)
        result.prunedDuplicateItems = pruned.transcripts + pruned.summaries

        let restoredCount = result.restoreResult.recordingsRestored +
            result.restoreResult.transcriptsRestored +
            result.restoreResult.summariesRestored
        var message =
            "iCloud sync finished (\(reason)): " +
            "\(result.backupResult.recordingsBackedUp) local recordings checked, " +
            "\(restoredCount) cloud items restored, " +
            "\(result.restoreResult.itemsHeldForReview) older iCloud items held for review, " +
            "\(result.deletedLocalRecordings) deleted items applied, " +
            "\(result.deletedCloudRecords) cloud records cleaned."
        if result.restoreResult.localItemsKeptAsNewer > 0 {
            message += " \(result.restoreResult.localItemsKeptAsNewer) newer local item" +
                "\(result.restoreResult.localItemsKeptAsNewer == 1 ? "" : "s") kept over older iCloud copies."
        }
        if result.revivedLocalItems > 0 {
            message += " \(result.revivedLocalItems) item" +
                "\(result.revivedLocalItems == 1 ? "" : "s") changed after being deleted elsewhere and were kept."
        }
        if result.prunedDuplicateItems > 0 {
            message += " \(result.prunedDuplicateItems) duplicate item" +
                "\(result.prunedDuplicateItems == 1 ? "" : "s") removed."
        }
        await MainActor.run {
            self.lastMaintenanceMessage = message
            self.lastSyncDate = Date()
            UserDefaults.standard.set(self.lastSyncDate, forKey: "lastSyncDate")
        }
        return result
    }

    private func saveDeletionMarker(
        kind: CloudDeletionTargetKind,
        id: UUID,
        recordingId: UUID?,
        deletedAt: Date,
        database: CKDatabase
    ) async throws {
        let recordID = CKRecord.ID(
            recordName: deletionMarkerRecordName(kind: kind, id: id)
        )
        let record = try await fetchOrCreateRecord(
            recordType: Self.backupDeletionRecordType,
            recordID: recordID,
            database: database
        )
        let parentRecordingId: UUID?
        if kind == .recording {
            parentRecordingId = id
        } else {
            parentRecordingId = recordingId
        }
        record[Self.fieldRecordingId] = parentRecordingId?.uuidString
        record[Self.fieldDeletedAt] = Self.resolvedDeletionTimestamp(
            existing: record[Self.fieldDeletedAt] as? Date,
            requested: deletedAt
        )
        record[Self.fieldDeviceIdentifier] = deviceIdentifier
        try await saveBackupRecord(record, database: database)
    }

    /// - Parameter deletedAt: when the user actually deleted the item. Queued
    ///   deletions replay their original request time so a marker that reaches
    ///   CloudKit days later cannot claim newer work on another device.
    func markRecordingDeletedIniCloud(
        recordingId: UUID,
        transcriptIds: [UUID],
        summaryIds: [UUID],
        deletedAt: Date = Date()
    ) async throws {
        guard isEnabled else {
            enqueueRecordingDeletionForiCloud(
                recordingId: recordingId,
                transcriptIds: transcriptIds,
                summaryIds: summaryIds,
                requestedAt: deletedAt
            )
            return
        }

        let container = Self.sharedCloudKitContainer()
        let database = container.privateCloudDatabase
        try await validateiCloudAccountAvailability(using: container)

        try await saveDeletionMarker(
            kind: .recording,
            id: recordingId,
            recordingId: nil,
            deletedAt: deletedAt,
            database: database
        )

        let deletedCloudRecords = try await deleteCloudContentRecords(
            recordingId: recordingId,
            transcriptIds: transcriptIds,
            summaryIds: summaryIds,
            database: database
        )
        UserDefaults.standard.removeObject(forKey: Self.backupStateSignatureKey)
        clearPendingRecordingDeletion(recordingId: recordingId)
        await MainActor.run {
            self.lastMaintenanceMessage = "Deleted item removed from iCloud sync records."
        }
        AppLog.shared.iCloudSync("Recorded iCloud deletion marker for \(recordingId.uuidString); removed \(deletedCloudRecords) cloud content records", level: .debug)
    }

    func markTranscriptDeletedIniCloud(
        transcriptId: UUID,
        recordingId: UUID? = nil,
        deletedAt: Date = Date()
    ) async throws {
        guard isEnabled else {
            enqueueTranscriptRemovalFromiCloud(
                transcriptId: transcriptId,
                recordingId: recordingId,
                requestedAt: deletedAt
            )
            return
        }

        let container = Self.sharedCloudKitContainer()
        let database = container.privateCloudDatabase
        try await validateiCloudAccountAvailability(using: container)
        try await saveDeletionMarker(
            kind: .transcript,
            id: transcriptId,
            recordingId: recordingId,
            deletedAt: deletedAt,
            database: database
        )
        let deletedCloudRecords = try await deleteTranscriptContentRecords(
            transcriptId: transcriptId,
            database: database
        )
        UserDefaults.standard.removeObject(forKey: Self.backupStateSignatureKey)
        clearPendingTranscriptRemoval(transcriptId: transcriptId)
        await MainActor.run {
            self.lastMaintenanceMessage = "Deleted transcript removed from iCloud sync records."
        }
        AppLog.shared.iCloudSync(
            "Recorded iCloud transcript deletion marker for \(transcriptId.uuidString); removed \(deletedCloudRecords) cloud content records",
            level: .debug
        )
    }

    func markSummaryDeletedIniCloud(
        summaryId: UUID,
        recordingId: UUID? = nil,
        deletedAt: Date = Date()
    ) async throws {
        guard isEnabled else {
            enqueueSummaryRemovalFromiCloud(
                summaryId: summaryId,
                recordingId: recordingId,
                requestedAt: deletedAt
            )
            return
        }

        let container = Self.sharedCloudKitContainer()
        let database = container.privateCloudDatabase
        try await validateiCloudAccountAvailability(using: container)
        try await saveDeletionMarker(
            kind: .summary,
            id: summaryId,
            recordingId: recordingId,
            deletedAt: deletedAt,
            database: database
        )
        let deletedCloudRecords = try await deleteSummaryContentRecords(
            summaryIds: [summaryId],
            database: database
        )
        UserDefaults.standard.removeObject(forKey: Self.backupStateSignatureKey)
        clearPendingSummaryRemoval(summaryId: summaryId)
        await MainActor.run {
            self.lastMaintenanceMessage = "Deleted summary removed from iCloud sync records."
        }
        AppLog.shared.iCloudSync(
            "Recorded iCloud summary deletion marker for \(summaryId.uuidString); removed \(deletedCloudRecords) cloud content records",
            level: .debug
        )
    }

    func removeSummaryContentFromiCloud(summaryId: UUID) async throws {
        try await markSummaryDeletedIniCloud(summaryId: summaryId)
    }

    func removeContentFromiCloud(
        recordingId: UUID,
        appCoordinator: AppDataCoordinator
    ) async throws {
        guard isEnabled else {
            enqueueLocalOnlyCloudRemoval(recordingId: recordingId)
            return
        }

        let container = Self.sharedCloudKitContainer()
        let database = container.privateCloudDatabase
        try await validateiCloudAccountAvailability(using: container)

        let transcripts = appCoordinator.coreDataManager.getAllTranscripts().filter {
            $0.recordingId == recordingId
        }
        let summaries = appCoordinator.coreDataManager.getAllSummaries().filter {
            ($0.recordingId ?? $0.recording?.id) == recordingId
        }

        let deletedCloudRecords = try await deleteCloudContentRecords(
            recordingId: recordingId,
            transcriptIds: transcripts.compactMap(\.id),
            summaryIds: summaries.compactMap(\.id),
            database: database
        )

        UserDefaults.standard.removeObject(forKey: Self.backupStateSignatureKey)
        clearPendingLocalOnlyCloudRemoval(recordingId: recordingId)
        AppLog.shared.iCloudSync("Removed \(deletedCloudRecords) iCloud records for local-only recording \(recordingId.uuidString)", level: .debug)
    }

    private func currentCloudBackupOptions() -> CloudBackupOptions {
        let defaults = UserDefaults.standard
        let includeAudio = defaults.object(forKey: "iCloudBackupIncludeAudioFiles") != nil
            ? defaults.bool(forKey: "iCloudBackupIncludeAudioFiles")
            : false
        let includeSettings = defaults.object(forKey: "iCloudBackupIncludeSettings") != nil
            ? defaults.bool(forKey: "iCloudBackupIncludeSettings")
            : true
        let includeSensitive = defaults.object(forKey: "iCloudBackupIncludeSensitiveSettings") != nil
            ? defaults.bool(forKey: "iCloudBackupIncludeSensitiveSettings")
            : false

        return CloudBackupOptions(
            includeAudioFiles: includeAudio,
            includeSettings: includeSettings,
            includeSensitiveSettings: includeSettings && includeSensitive
        )
    }

    private var pendingCloudDeletionMarkers: [PendingCloudDeletionMarker] {
        get { Self.decodePendingCloudMutations(PendingCloudDeletionMarker.self, key: Self.pendingDeletionMarkersKey) }
        set { Self.storePendingCloudMutations(newValue, key: Self.pendingDeletionMarkersKey) }
    }

    private var pendingLocalOnlyCloudRemovals: [PendingLocalOnlyCloudRemoval] {
        get { Self.decodePendingCloudMutations(PendingLocalOnlyCloudRemoval.self, key: Self.pendingLocalOnlyRemovalsKey) }
        set { Self.storePendingCloudMutations(newValue, key: Self.pendingLocalOnlyRemovalsKey) }
    }

    private var pendingSummaryCloudRemovals: [PendingSummaryCloudRemoval] {
        get { Self.decodePendingCloudMutations(PendingSummaryCloudRemoval.self, key: Self.pendingSummaryRemovalsKey) }
        set { Self.storePendingCloudMutations(newValue, key: Self.pendingSummaryRemovalsKey) }
    }

    private var pendingTranscriptCloudRemovals: [PendingTranscriptCloudRemoval] {
        get { Self.decodePendingCloudMutations(PendingTranscriptCloudRemoval.self, key: Self.pendingTranscriptRemovalsKey) }
        set { Self.storePendingCloudMutations(newValue, key: Self.pendingTranscriptRemovalsKey) }
    }

    private static func decodePendingCloudMutations<T: Decodable>(_ type: T.Type, key: String) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return []
        }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private static func storePendingCloudMutations<T: Encodable>(_ mutations: [T], key: String) {
        guard !mutations.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(mutations) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Publishes UI-only maintenance feedback after the current main-actor turn.
    /// Queue persistence must remain synchronous so deletion intent survives a crash,
    /// but publishing here during a SwiftUI update triggers undefined behavior.
    private func publishMaintenanceMessage(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastMaintenanceMessage = message
        }
    }

    func enqueueRecordingDeletionForiCloud(
        recordingId: UUID,
        transcriptIds: [UUID],
        summaryIds: [UUID],
        requestedAt: Date = Date()
    ) {
        var queue = pendingCloudDeletionMarkers
        if let index = queue.firstIndex(where: { $0.recordingId == recordingId }) {
            queue[index].transcriptIds = Self.mergedUUIDs(queue[index].transcriptIds, transcriptIds)
            queue[index].summaryIds = Self.mergedUUIDs(queue[index].summaryIds, summaryIds)
        } else {
            queue.append(PendingCloudDeletionMarker(
                recordingId: recordingId,
                transcriptIds: transcriptIds,
                summaryIds: summaryIds,
                requestedAt: requestedAt
            ))
        }
        pendingCloudDeletionMarkers = queue
        let deletedSummaryIds = Set(summaryIds)
        pendingSyncQueue.removeAll { summary in
            summary.recordingId == recordingId || deletedSummaryIds.contains(summary.id)
        }
        UserDefaults.standard.removeObject(forKey: Self.backupStateSignatureKey)
    }

    func enqueueLocalOnlyCloudRemoval(recordingId: UUID) {
        var queue = pendingLocalOnlyCloudRemovals
        if !queue.contains(where: { $0.recordingId == recordingId }) {
            queue.append(PendingLocalOnlyCloudRemoval(recordingId: recordingId, requestedAt: Date()))
            pendingLocalOnlyCloudRemovals = queue
        }
        UserDefaults.standard.removeObject(forKey: Self.backupStateSignatureKey)
        publishMaintenanceMessage("Existing iCloud copies for local-only recordings will be removed when iCloud sync is available.")
    }

    func enqueueSummaryRemovalFromiCloud(
        summaryId: UUID,
        recordingId: UUID? = nil,
        requestedAt: Date = Date()
    ) {
        var queue = pendingSummaryCloudRemovals
        if let index = queue.firstIndex(where: { $0.summaryId == summaryId }) {
            if queue[index].recordingId == nil {
                queue[index].recordingId = recordingId
            }
        } else {
            queue.append(PendingSummaryCloudRemoval(
                summaryId: summaryId,
                recordingId: recordingId,
                requestedAt: requestedAt
            ))
        }
        pendingSummaryCloudRemovals = queue
        pendingSyncQueue.removeAll { $0.id == summaryId }
        UserDefaults.standard.removeObject(forKey: Self.backupStateSignatureKey)
        publishMaintenanceMessage("Deleted summaries will be removed from iCloud sync records when iCloud sync is available.")
    }

    func enqueueTranscriptRemovalFromiCloud(
        transcriptId: UUID,
        recordingId: UUID? = nil,
        requestedAt: Date = Date()
    ) {
        var queue = pendingTranscriptCloudRemovals
        if let index = queue.firstIndex(where: { $0.transcriptId == transcriptId }) {
            if queue[index].recordingId == nil {
                queue[index].recordingId = recordingId
            }
        } else {
            queue.append(PendingTranscriptCloudRemoval(
                transcriptId: transcriptId,
                recordingId: recordingId,
                requestedAt: requestedAt
            ))
        }
        pendingTranscriptCloudRemovals = queue
        UserDefaults.standard.removeObject(forKey: Self.backupStateSignatureKey)
        publishMaintenanceMessage("Deleted transcripts will be removed from iCloud sync records when iCloud sync is available.")
    }

    func clearPendingLocalOnlyCloudRemoval(recordingId: UUID) {
        pendingLocalOnlyCloudRemovals.removeAll { $0.recordingId == recordingId }
    }

    func clearPendingSummaryRemoval(summaryId: UUID) {
        pendingSummaryCloudRemovals.removeAll { $0.summaryId == summaryId }
    }

    func clearPendingTranscriptRemoval(transcriptId: UUID) {
        pendingTranscriptCloudRemovals.removeAll { $0.transcriptId == transcriptId }
    }

    private func clearPendingRecordingDeletion(recordingId: UUID) {
        pendingCloudDeletionMarkers.removeAll { $0.recordingId == recordingId }
    }

    private static func mergedUUIDs(_ lhs: [UUID], _ rhs: [UUID]) -> [UUID] {
        Array(Set(lhs + rhs)).sorted { $0.uuidString < $1.uuidString }
    }

    @discardableResult
    func flushPendingiCloudMutations(appCoordinator: AppDataCoordinator) async throws -> (deletions: Int, localOnlyRemovals: Int, summaryRemovals: Int) {
        guard isEnabled else {
            return (0, 0, 0)
        }

        var flushedDeletions = 0
        var flushedLocalOnlyRemovals = 0
        var flushedSummaryRemovals = 0
        var flushedTranscriptRemovals = 0

        for pendingDeletion in pendingCloudDeletionMarkers {
            try await markRecordingDeletedIniCloud(
                recordingId: pendingDeletion.recordingId,
                transcriptIds: pendingDeletion.transcriptIds,
                summaryIds: pendingDeletion.summaryIds,
                deletedAt: pendingDeletion.requestedAt
            )
            flushedDeletions += 1
        }

        for pendingTranscriptRemoval in pendingTranscriptCloudRemovals {
            try await markTranscriptDeletedIniCloud(
                transcriptId: pendingTranscriptRemoval.transcriptId,
                recordingId: pendingTranscriptRemoval.recordingId,
                deletedAt: pendingTranscriptRemoval.requestedAt
            )
            flushedTranscriptRemovals += 1
        }

        for pendingSummaryRemoval in pendingSummaryCloudRemovals {
            try await markSummaryDeletedIniCloud(
                summaryId: pendingSummaryRemoval.summaryId,
                recordingId: pendingSummaryRemoval.recordingId,
                deletedAt: pendingSummaryRemoval.requestedAt
            )
            flushedSummaryRemovals += 1
        }

        for pendingRemoval in pendingLocalOnlyCloudRemovals {
            guard let recording = appCoordinator.coreDataManager.getRecording(id: pendingRemoval.recordingId) else {
                clearPendingLocalOnlyCloudRemoval(recordingId: pendingRemoval.recordingId)
                continue
            }
            guard recording.isCloudSyncDisabled else {
                clearPendingLocalOnlyCloudRemoval(recordingId: pendingRemoval.recordingId)
                continue
            }

            try await removeContentFromiCloud(
                recordingId: pendingRemoval.recordingId,
                appCoordinator: appCoordinator
            )
            flushedLocalOnlyRemovals += 1
        }

        if flushedDeletions > 0 || flushedLocalOnlyRemovals > 0 ||
            flushedTranscriptRemovals > 0 || flushedSummaryRemovals > 0 {
            AppLog.shared.iCloudSync(
                "Flushed pending iCloud mutations - deletions: \(flushedDeletions), " +
                    "local-only removals: \(flushedLocalOnlyRemovals), " +
                    "transcript removals: \(flushedTranscriptRemovals), " +
                    "summary removals: \(flushedSummaryRemovals)",
                level: .debug
            )
        }

        return (flushedDeletions, flushedLocalOnlyRemovals, flushedSummaryRemovals)
    }

    #if DEBUG
    var pendingCloudDeletionCountForTesting: Int {
        pendingCloudDeletionMarkers.count
    }

    var pendingLocalOnlyRemovalCountForTesting: Int {
        pendingLocalOnlyCloudRemovals.count
    }

    var pendingSummaryRemovalCountForTesting: Int {
        pendingSummaryCloudRemovals.count
    }

    var pendingTranscriptRemovalCountForTesting: Int {
        pendingTranscriptCloudRemovals.count
    }

    func pendingCloudDeletionRequestedAtForTesting(recordingId: UUID) -> Date? {
        pendingCloudDeletionMarkers.first { $0.recordingId == recordingId }?.requestedAt
    }

    func clearPendingCloudMutationsForTesting() {
        pendingCloudDeletionMarkers = []
        pendingLocalOnlyCloudRemovals = []
        pendingSummaryCloudRemovals = []
        pendingTranscriptCloudRemovals = []
    }
    #endif

    private func applyiCloudDeletionMarkers(
        appCoordinator: AppDataCoordinator
    ) async throws -> DeletionMarkerApplication {
        let container = Self.sharedCloudKitContainer()
        let database = container.privateCloudDatabase
        try await validateiCloudAccountAvailability(using: container)

        let deletionRecords = try await fetchBackupRecords(
            recordType: Self.backupDeletionRecordType,
            database: database
        )
        guard !deletionRecords.isEmpty else { return DeletionMarkerApplication() }

        var application = DeletionMarkerApplication()

        /// Withdraws a tombstone whose target was edited here after the delete. The
        /// later edit wins, and because the marker is gone before this reconcile's
        /// backup leg runs, the surviving item uploads again for every device.
        func reviveLocallyModifiedItem(_ record: CKRecord, describedAs description: String) async throws {
            try await deleteBackupRecords([record.recordID], database: database)
            application.revivedLocally += 1
            AppLog.shared.iCloudSync(
                "Kept \(description) that changed after it was deleted on another device; withdrew the iCloud deletion marker"
            )
        }

        for record in deletionRecords {
            guard let target = decodeDeletionTarget(record: record) else {
                continue
            }

            switch target.kind {
            case .recording:
                let recording = appCoordinator.coreDataManager.getRecording(id: target.id)
                if let recording,
                   recording.isCloudSyncDisabled == false,
                   Self.shouldReviveLocallyModifiedItem(
                       localTimestamp: localRecordingContentTimestamp(recording),
                       deletedAt: target.deletedAt
                   ) {
                    try await reviveLocallyModifiedItem(record, describedAs: "recording \(target.id.uuidString)")
                    continue
                }

                application.deletedCloudRecords += try await deleteCloudContentRecords(
                    recordingId: target.id,
                    transcriptIds: [],
                    summaryIds: [],
                    database: database
                )

                guard let recording, recording.isCloudSyncDisabled == false else {
                    continue
                }
                appCoordinator.coreDataManager.deleteRecording(id: target.id)
                application.deletedLocalItems += 1
            case .transcript:
                let transcript = appCoordinator.coreDataManager.getTranscript(id: target.id)
                let transcriptParent = transcript.flatMap { candidate in
                    candidate.recording
                        ?? candidate.recordingId.flatMap { appCoordinator.coreDataManager.getRecording(id: $0) }
                }
                if let transcript,
                   transcriptParent?.isCloudSyncDisabled != true,
                   Self.shouldReviveLocallyModifiedItem(
                       localTimestamp: localTranscriptContentTimestamp(transcript),
                       deletedAt: target.deletedAt
                   ) {
                    try await reviveLocallyModifiedItem(record, describedAs: "transcript \(target.id.uuidString)")
                    continue
                }

                application.deletedCloudRecords += try await deleteTranscriptContentRecords(
                    transcriptId: target.id,
                    database: database
                )

                guard transcript != nil, transcriptParent?.isCloudSyncDisabled != true else { continue }
                try? appCoordinator.coreDataManager.deleteTranscript(id: target.id)
                if appCoordinator.coreDataManager.getTranscript(id: target.id) == nil {
                    application.deletedLocalItems += 1
                }
            case .summary:
                let summary = appCoordinator.coreDataManager.getSummary(id: target.id)
                let summaryParent = summary.flatMap { candidate in
                    candidate.recording
                        ?? candidate.recordingId.flatMap { appCoordinator.coreDataManager.getRecording(id: $0) }
                }
                if let summary,
                   summaryParent?.isCloudSyncDisabled != true,
                   Self.shouldReviveLocallyModifiedItem(
                       localTimestamp: summary.generatedAt,
                       deletedAt: target.deletedAt
                   ) {
                    try await reviveLocallyModifiedItem(record, describedAs: "summary \(target.id.uuidString)")
                    continue
                }

                application.deletedCloudRecords += try await deleteSummaryContentRecords(
                    summaryIds: [target.id],
                    database: database
                )

                guard summary != nil, summaryParent?.isCloudSyncDisabled != true else { continue }
                try? SummaryAttachmentStore.shared.deleteAll(for: target.id)
                try? appCoordinator.coreDataManager.deleteSummary(id: target.id)
                if appCoordinator.coreDataManager.getSummary(id: target.id) == nil {
                    application.deletedLocalItems += 1
                }
            }
        }

        if application.didChangeAnything {
            let deletedLocalCount = application.deletedLocalItems
            let deletedCloudCount = application.deletedCloudRecords
            var messageParts: [String] = []
            if deletedLocalCount > 0 || deletedCloudCount > 0 {
                messageParts.append(
                    "Applied \(deletedLocalCount) iCloud deletion\(deletedLocalCount == 1 ? "" : "s") to this device and cleaned \(deletedCloudCount) cloud record\(deletedCloudCount == 1 ? "" : "s")."
                )
            }
            if application.revivedLocally > 0 {
                messageParts.append(
                    "Kept \(application.revivedLocally) item\(application.revivedLocally == 1 ? "" : "s") that changed after being deleted on another device."
                )
            }
            let message = messageParts.joined(separator: " ")
            await MainActor.run {
                self.lastMaintenanceMessage = message
            }
            NotificationCenter.default.post(name: NSNotification.Name("iCloudReconcileCompleted"), object: nil)
        }

        if application.revivedLocally > 0 {
            // Those items must upload again, so the skip-if-unchanged shortcut cannot
            // be allowed to short-circuit the backup leg that follows.
            UserDefaults.standard.removeObject(forKey: Self.backupStateSignatureKey)
        }

        return application
    }

    private func fetchDeletionTargets(database: CKDatabase) async throws -> CloudDeletionTargets {
        let deletionRecords = try await fetchBackupRecords(
            recordType: Self.backupDeletionRecordType,
            database: database
        )
        var targets = CloudDeletionTargets()
        for record in deletionRecords {
            guard let target = decodeDeletionTarget(record: record) else { continue }
            switch target.kind {
            case .recording:
                targets.recordings.insert(target.id)
            case .transcript:
                targets.transcripts.insert(target.id)
            case .summary:
                targets.summaries.insert(target.id)
            }
        }
        return targets
    }

    private func deleteCloudContentRecords(
        recordingId: UUID,
        transcriptIds: [UUID],
        summaryIds: [UUID],
        database: CKDatabase
    ) async throws -> Int {
        let recordingBackupRecordName = makeBackupRecordName(prefix: Self.backupRecordingRecordPrefix, id: recordingId)
        var backupRecordIDs = [CKRecord.ID(recordName: recordingBackupRecordName)]

        let knownTranscriptRecordNames = transcriptIds.map {
            makeBackupRecordName(prefix: Self.backupTranscriptRecordPrefix, id: $0)
        }
        let knownSummaryRecordNames = summaryIds.map {
            makeBackupRecordName(prefix: Self.backupSummaryRecordPrefix, id: $0)
        }
        backupRecordIDs.append(contentsOf: knownTranscriptRecordNames.map { CKRecord.ID(recordName: $0) })
        backupRecordIDs.append(contentsOf: knownSummaryRecordNames.map { CKRecord.ID(recordName: $0) })

        let transcriptRecords = (try? await fetchBackupRecords(recordType: Self.backupTranscriptRecordType, database: database)) ?? []
        let summaryRecords = (try? await fetchBackupRecords(recordType: Self.backupSummaryRecordType, database: database)) ?? []
        let discoveredTranscriptRecords = transcriptRecords.filter { record in
            backupRecordBelongsToRecording(record, recordingId: recordingId)
        }
        let discoveredSummaryRecords = summaryRecords.filter { record in
            backupRecordBelongsToRecording(record, recordingId: recordingId)
        }
        let discoveredTranscriptRecordNames = discoveredTranscriptRecords.map { $0.recordID.recordName }
        let discoveredSummaryRecordNames = discoveredSummaryRecords.map { $0.recordID.recordName }
        backupRecordIDs.append(contentsOf: discoveredTranscriptRecords.map(\.recordID))
        backupRecordIDs.append(contentsOf: discoveredSummaryRecords.map(\.recordID))

        let legacySummaryRecordIDs = try await legacySummarySyncRecordIDs(
            recordingId: recordingId,
            summaryIds: summaryIds,
            database: database
        )

        let deletedRecordCount = try await deleteExistingCloudRecords(
            backupRecordIDs + legacySummaryRecordIDs,
            database: database
        )
        try await removeBackupRecordNamesFromContentIndex(
            database: database,
            recordingRecordNames: [recordingBackupRecordName],
            transcriptRecordNames: Array(Set(knownTranscriptRecordNames + discoveredTranscriptRecordNames)),
            summaryRecordNames: Array(Set(knownSummaryRecordNames + discoveredSummaryRecordNames))
        )
        return deletedRecordCount
    }

    private func deleteTranscriptContentRecords(
        transcriptId: UUID,
        database: CKDatabase
    ) async throws -> Int {
        let backupTranscriptRecordName = makeBackupRecordName(
            prefix: Self.backupTranscriptRecordPrefix,
            id: transcriptId
        )
        var deletedRecordCount = try await deleteExistingCloudRecords(
            [CKRecord.ID(recordName: backupTranscriptRecordName)],
            database: database
        )
        try await removeBackupRecordNamesFromContentIndex(
            database: database,
            recordingRecordNames: [],
            transcriptRecordNames: [backupTranscriptRecordName],
            summaryRecordNames: []
        )

        // Clear the parent and summary references as part of the same cloud
        // mutation. Otherwise a device restoring only the cloud backup could
        // recreate a dangling transcript link after the transcript record was
        // removed.
        let transcriptIdString = transcriptId.uuidString
        let recordingRecords = try await fetchBackupRecords(
            recordType: Self.backupRecordingRecordType,
            database: database
        )
        for record in recordingRecords where record[Self.fieldTranscriptId] as? String == transcriptIdString {
            var shouldSave = false
            updateStringField(Self.fieldTranscriptId, value: nil, on: record, changed: &shouldSave)
            updateStringField(
                Self.fieldTranscriptionStatus,
                value: ProcessingStatus.notStarted.rawValue,
                on: record,
                changed: &shouldSave
            )
            updateDateField(Self.fieldLastModified, value: Date(), on: record, changed: &shouldSave)
            if shouldSave {
                try await saveBackupRecord(record, database: database)
                deletedRecordCount += 1
            }
        }

        let summaryRecords = try await fetchBackupRecords(
            recordType: Self.backupSummaryRecordType,
            database: database
        )
        for record in summaryRecords where record[Self.fieldTranscriptId] as? String == transcriptIdString {
            var shouldSave = false
            updateStringField(Self.fieldTranscriptId, value: nil, on: record, changed: &shouldSave)
            updateDateField(Self.fieldLastModified, value: Date(), on: record, changed: &shouldSave)
            if shouldSave {
                try await saveBackupRecord(record, database: database)
                deletedRecordCount += 1
            }
        }

        // A legacy summary record may still point at the removed transcript. Keep the
        // summary, but clear that relationship so legacy restore cannot recreate it.
        let legacyRecords = try await fetchLegacySummarySyncRecords(database: database)
        for record in legacyRecords where record[CloudKitSummaryRecord.transcriptIdField] as? String == transcriptId.uuidString {
            record[CloudKitSummaryRecord.transcriptIdField] = nil
            record[CloudKitSummaryRecord.lastModifiedField] = Date()
            do {
                try await saveBackupRecord(record, database: database)
                deletedRecordCount += 1
            } catch {
                AppLog.shared.iCloudSync(
                    "Could not clear deleted transcript reference from legacy summary record \(record.recordID.recordName): \(error.localizedDescription)",
                    level: .error
                )
            }
        }
        return deletedRecordCount
    }

    private func deleteSummaryContentRecords(
        summaryIds: [UUID],
        database: CKDatabase
    ) async throws -> Int {
        let backupSummaryRecordNames = summaryIds.map {
            makeBackupRecordName(prefix: Self.backupSummaryRecordPrefix, id: $0)
        }
        let recordIDs = summaryIds.map { CKRecord.ID(recordName: $0.uuidString) } +
            backupSummaryRecordNames.map { CKRecord.ID(recordName: $0) }

        let legacySummaryRecordIDs = try await legacySummarySyncRecordIDs(
            recordingId: nil,
            summaryIds: summaryIds,
            database: database
        )
        var deletedRecordCount = try await deleteExistingCloudRecords(
            recordIDs + legacySummaryRecordIDs,
            database: database
        )
        try await removeBackupRecordNamesFromContentIndex(
            database: database,
            recordingRecordNames: [],
            transcriptRecordNames: [],
            summaryRecordNames: backupSummaryRecordNames
        )

        // Clear the recording's scalar relationship and lifecycle status so a
        // restore cannot resurrect a dangling summary reference from the parent
        // recording record.
        for record in try await fetchBackupRecords(
            recordType: Self.backupRecordingRecordType,
            database: database
        ) where summaryIds.contains(where: { $0.uuidString == (record[Self.fieldSummaryId] as? String) }) {
            var shouldSave = false
            updateStringField(Self.fieldSummaryId, value: nil, on: record, changed: &shouldSave)
            updateStringField(
                Self.fieldSummaryStatus,
                value: ProcessingStatus.notStarted.rawValue,
                on: record,
                changed: &shouldSave
            )
            updateDateField(Self.fieldLastModified, value: Date(), on: record, changed: &shouldSave)
            if shouldSave {
                try await saveBackupRecord(record, database: database)
                deletedRecordCount += 1
            }
        }
        return deletedRecordCount
    }

    private func deleteExistingCloudRecords(_ recordIDs: [CKRecord.ID], database: CKDatabase) async throws -> Int {
        var deletedCount = 0
        var seenRecordNames = Set<String>()

        for recordID in recordIDs where !seenRecordNames.contains(recordID.recordName) {
            seenRecordNames.insert(recordID.recordName)
            do {
                _ = try await database.record(for: recordID)
                try await deleteBackupRecord(recordID, database: database)
                deletedCount += 1
            } catch let error as CKError where error.code == .unknownItem {
                continue
            }
        }

        return deletedCount
    }

    private func legacySummarySyncRecordIDs(
        recordingId: UUID?,
        summaryIds: [UUID],
        database: CKDatabase
    ) async throws -> [CKRecord.ID] {
        let summaryIdStrings = Set(summaryIds.map { $0.uuidString })
        let query = CKQuery(recordType: CloudKitSummaryRecord.recordType, predicate: NSPredicate(value: true))
        var recordsToDelete: [CKRecord.ID] = summaryIds.map { CKRecord.ID(recordName: $0.uuidString) }

        do {
            var fetchResult = try await database.records(matching: query)
            while true {
                for (_, result) in fetchResult.matchResults {
                    guard case .success(let record) = result else { continue }
                    let recordRecordingId = record[CloudKitSummaryRecord.recordingIdField] as? String
                    if (recordingId.map { recordRecordingId == $0.uuidString } ?? false) ||
                        summaryIdStrings.contains(record.recordID.recordName) {
                        recordsToDelete.append(record.recordID)
                    }
                }

                guard let cursor = fetchResult.queryCursor else { break }
                fetchResult = try await database.records(continuingMatchFrom: cursor)
            }
        } catch {
            AppLog.shared.iCloudSync("Could not scan legacy summary sync records for deletion cleanup: \(error.localizedDescription)", level: .error)
        }

        return Array(Dictionary(grouping: recordsToDelete, by: { $0.recordName }).compactMap { $0.value.first })
    }

    private func fetchLegacySummarySyncRecords(database: CKDatabase) async throws -> [CKRecord] {
        let query = CKQuery(recordType: CloudKitSummaryRecord.recordType, predicate: NSPredicate(value: true))
        var records: [CKRecord] = []

        do {
            var fetchResult = try await database.records(matching: query)
            while true {
                for (_, result) in fetchResult.matchResults {
                    if case .success(let record) = result {
                        records.append(record)
                    }
                }

                guard let cursor = fetchResult.queryCursor else { break }
                fetchResult = try await database.records(continuingMatchFrom: cursor)
            }
        } catch {
            AppLog.shared.iCloudSync("Could not scan legacy summary sync records: \(error.localizedDescription)", level: .error)
        }

        return records
    }

    private func backupRecordBelongsToRecording(_ record: CKRecord, recordingId: UUID) -> Bool {
        guard let recordingIdValue = record[Self.fieldRecordingId] as? String,
              let recordRecordingId = UUID(uuidString: recordingIdValue) else {
            return false
        }
        return recordRecordingId == recordingId
    }

    private func deletionMarkerRecordName(kind: CloudDeletionTargetKind, id: UUID) -> String {
        let prefix: String
        switch kind {
        case .recording:
            prefix = Self.backupDeletionRecordPrefix
        case .transcript:
            prefix = Self.backupTranscriptDeletionRecordPrefix
        case .summary:
            prefix = Self.backupSummaryDeletionRecordPrefix
        }
        return makeBackupRecordName(prefix: prefix, id: id)
    }

    private func decodeDeletionTarget(record: CKRecord) -> CloudDeletionTarget? {
        decodeDeletionTarget(
            recordName: record.recordID.recordName,
            recordingId: (record[Self.fieldRecordingId] as? String).flatMap { UUID(uuidString: $0) },
            deletedAt: record[Self.fieldDeletedAt] as? Date ?? Date.distantPast
        )
    }

    private func decodeDeletionTarget(
        recordName: String,
        recordingId: UUID?,
        deletedAt: Date
    ) -> CloudDeletionTarget? {
        if let id = decodeBackupRecordUUID(
            recordName: recordName,
            prefix: Self.backupTranscriptDeletionRecordPrefix
        ) {
            return CloudDeletionTarget(
                kind: .transcript,
                id: id,
                recordingId: recordingId,
                deletedAt: deletedAt
            )
        }
        if let id = decodeBackupRecordUUID(
            recordName: recordName,
            prefix: Self.backupSummaryDeletionRecordPrefix
        ) {
            return CloudDeletionTarget(
                kind: .summary,
                id: id,
                recordingId: recordingId,
                deletedAt: deletedAt
            )
        }

        let recordingTarget = recordingId ?? decodeBackupRecordUUID(
            recordName: recordName,
            prefix: Self.backupDeletionRecordPrefix
        )
        guard let recordingTarget else { return nil }
        return CloudDeletionTarget(
            kind: .recording,
            id: recordingTarget,
            recordingId: nil,
            deletedAt: deletedAt
        )
    }

#if DEBUG
    func deletionMarkerRecordNameForTesting(kind: CloudDeletionTargetKind, id: UUID) -> String {
        deletionMarkerRecordName(kind: kind, id: id)
    }

    func decodeDeletionTargetForTesting(
        recordName: String,
        recordingId: UUID? = nil,
        deletedAt: Date = Date()
    ) -> CloudDeletionTarget? {
        decodeDeletionTarget(
            recordName: recordName,
            recordingId: recordingId,
            deletedAt: deletedAt
        )
    }
#endif

    private func makeBackupRecordName(prefix: String, id: UUID) -> String {
        return "\(prefix)\(id.uuidString)"
    }

    private func decodeBackupRecordUUID(recordName: String, prefix: String) -> UUID? {
        guard recordName.hasPrefix(prefix) else { return nil }
        let uuidText = String(recordName.dropFirst(prefix.count))
        return UUID(uuidString: uuidText)
    }

    private func audioFileSignature(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        let modifiedTime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int64(modifiedTime))"
    }

    private func computeBackupStateSignature(
        recordings: [RecordingEntry],
        transcripts: [TranscriptEntry],
        summaries: [SummaryEntry],
        appCoordinator: AppDataCoordinator,
        options: CloudBackupOptions
    ) -> String {
        var hashBuilder = StableHashBuilder()
        hashBuilder.combine("v3")
        hashBuilder.combine(options.includeAudioFiles ? "audio:on" : "audio:off")
        hashBuilder.combine(options.includeSettings ? "settings:on" : "settings:off")
        hashBuilder.combine(options.includeSensitiveSettings ? "sensitive:on" : "sensitive:off")

        let sortedRecordings = recordings.sorted {
            ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
        }
        for recording in sortedRecordings {
            hashBuilder.combine(recording.id?.uuidString ?? "-")
            hashBuilder.combine(recording.recordingName ?? "-")
            hashBuilder.combine(recording.recordingURL ?? "-")
            hashBuilder.combine(dateToken(recording.recordingDate))
            hashBuilder.combine(dateToken(recording.createdAt))
            hashBuilder.combine(dateToken(recording.lastModified))
            hashBuilder.combine(String(recording.fileSize))
            hashBuilder.combine(String(recording.duration))
            hashBuilder.combine(recording.audioQuality ?? "-")
            hashBuilder.combine(recording.transcriptionStatus ?? "-")
            hashBuilder.combine(recording.summaryStatus ?? "-")
            hashBuilder.combine(recording.transcriptId?.uuidString ?? "-")
            hashBuilder.combine(recording.summaryId?.uuidString ?? "-")
            hashBuilder.combine(String(recording.locationLatitude))
            hashBuilder.combine(String(recording.locationLongitude))
            hashBuilder.combine(String(recording.locationAccuracy))
            hashBuilder.combine(dateToken(recording.locationTimestamp))
            hashBuilder.combine(recording.locationAddress ?? "-")

            if options.includeAudioFiles,
               let localURL = appCoordinator.getAbsoluteURL(for: recording),
               FileManager.default.fileExists(atPath: localURL.path) {
                hashBuilder.combine(localURL.lastPathComponent)
                hashBuilder.combine(audioFileSignature(for: localURL))
            }
        }

        let sortedTranscripts = transcripts.sorted {
            ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
        }
        for transcript in sortedTranscripts {
            hashBuilder.combine(transcript.id?.uuidString ?? "-")
            hashBuilder.combine(transcript.recordingId?.uuidString ?? "-")
            hashBuilder.combine(transcript.engine ?? "-")
            hashBuilder.combine(dateToken(transcript.createdAt))
            hashBuilder.combine(dateToken(transcript.lastModified))
            hashBuilder.combine(String(transcript.processingTime))
            hashBuilder.combine(String(transcript.confidence))
            hashBuilder.combine(transcript.segments ?? "-")
            hashBuilder.combine(transcript.speakerMappings ?? "-")
        }

        let sortedSummaries = summaries.sorted {
            ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
        }
        for summary in sortedSummaries {
            hashBuilder.combine(summary.id?.uuidString ?? "-")
            hashBuilder.combine(summary.recordingId?.uuidString ?? "-")
            hashBuilder.combine(summary.transcriptId?.uuidString ?? "-")
            hashBuilder.combine(summary.summary ?? "-")
            hashBuilder.combine(summary.tasks ?? "-")
            hashBuilder.combine(summary.reminders ?? "-")
            hashBuilder.combine(summary.titles ?? "-")
            hashBuilder.combine(summary.contentType ?? "-")
            hashBuilder.combine(summary.aiMethod ?? "-")
            hashBuilder.combine(dateToken(summary.generatedAt))
            hashBuilder.combine(String(summary.version))
            hashBuilder.combine(String(summary.wordCount))
            hashBuilder.combine(String(summary.originalLength))
            hashBuilder.combine(String(summary.compressionRatio))
            hashBuilder.combine(String(summary.confidence))
            hashBuilder.combine(String(summary.processingTime))
        }

        if options.includeSettings {
            let settings = collectSettingsForBackup(includeSensitiveSettings: options.includeSensitiveSettings)
            hashBuilder.combine(settings.includedSensitiveSettings ? "settings-sensitive:yes" : "settings-sensitive:no")
            for key in settings.values.keys.sorted() {
                guard let valueData = settings.values[key] else { continue }
                hashBuilder.combine(key)
                hashBuilder.combine(valueData)
            }
        }

        return hashBuilder.hexDigest
    }

    private func backupRecordBelongsToExcludedRecording(
        _ record: CKRecord,
        excludedRecordingIds: Set<UUID>
    ) -> Bool {
        guard let recordingIdValue = record[Self.fieldRecordingId] as? String,
              let recordingId = UUID(uuidString: recordingIdValue) else {
            return false
        }
        return excludedRecordingIds.contains(recordingId)
    }

    private func dateToken(_ date: Date?) -> String {
        guard let date else { return "-" }
        return String(Int64(date.timeIntervalSince1970 * 1000))
    }

    private func ensureBackupIdentifiers(
        recordings: [RecordingEntry],
        transcripts: [TranscriptEntry],
        summaries: [SummaryEntry]
    ) throws -> BackupIdentifierFixupResult {
        var result = BackupIdentifierFixupResult()
        var contextsToSave: [NSManagedObjectContext] = []

        func trackContext(_ context: NSManagedObjectContext?) {
            guard let context else { return }
            if !contextsToSave.contains(where: { $0 === context }) {
                contextsToSave.append(context)
            }
        }

        for recording in recordings where recording.id == nil {
            recording.id = UUID()
            result.recordingsAssigned += 1
            trackContext(recording.managedObjectContext)
        }

        for transcript in transcripts where transcript.id == nil {
            transcript.id = UUID()
            result.transcriptsAssigned += 1
            trackContext(transcript.managedObjectContext)
        }

        for summary in summaries where summary.id == nil {
            summary.id = UUID()
            result.summariesAssigned += 1
            trackContext(summary.managedObjectContext)
        }

        if result.totalAssigned > 0 {
            for context in contextsToSave where context.hasChanges {
                try context.save()
            }
        }

        return result
    }

    private struct StableHashBuilder {
        private var hash: UInt64 = 1469598103934665603
        private static let prime: UInt64 = 1099511628211

        mutating func combine(_ text: String) {
            combine(Data(text.utf8))
        }

        mutating func combine(_ data: Data) {
            for byte in data {
                hash ^= UInt64(byte)
                hash = hash &* Self.prime
            }
            // Field separator to avoid accidental concatenation collisions.
            hash ^= 0x1F
            hash = hash &* Self.prime
        }

        var hexDigest: String {
            String(format: "%016llx", hash)
        }
    }

    private func updateStringField(
        _ key: String,
        value: String?,
        on record: CKRecord,
        changed: inout Bool
    ) {
        let current = record[key] as? String
        if current != value {
            record[key] = value as CKRecordValue?
            changed = true
        }
    }

    private func updateDateField(
        _ key: String,
        value: Date?,
        on record: CKRecord,
        changed: inout Bool
    ) {
        let current = record[key] as? Date
        if current != value {
            record[key] = value as CKRecordValue?
            changed = true
        }
    }

    private func updateIntField(
        _ key: String,
        value: Int,
        on record: CKRecord,
        changed: inout Bool
    ) {
        let current = intValue(from: record[key], defaultValue: Int.min)
        if current != value {
            record[key] = NSNumber(value: value)
            changed = true
        }
    }

    private func updateInt64Field(
        _ key: String,
        value: Int64,
        on record: CKRecord,
        changed: inout Bool
    ) {
        let current = int64Value(from: record[key], defaultValue: Int64.min)
        if current != value {
            record[key] = NSNumber(value: value)
            changed = true
        }
    }

    private func updateDoubleField(
        _ key: String,
        value: Double,
        on record: CKRecord,
        changed: inout Bool
    ) {
        let current = doubleValue(from: record[key], defaultValue: Double.nan)
        if current.isNaN || abs(current - value) > 0.0000001 {
            record[key] = NSNumber(value: value)
            changed = true
        }
    }

    private func markBackupRecordActive(_ record: CKRecord, changed: inout Bool) {
        updateStringField(Self.fieldSyncLifecycle, value: Self.syncLifecycleActive, on: record, changed: &changed)
        updateIntField(Self.fieldSyncSchemaVersion, value: Self.activeManifestSchemaVersion, on: record, changed: &changed)
        updateDateField(Self.fieldSyncUpdatedAt, value: Date(), on: record, changed: &changed)
        updateStringField(Self.fieldDeviceIdentifier, value: deviceIdentifier, on: record, changed: &changed)
    }

    private func isActiveBackupRecord(_ record: CKRecord) -> Bool {
        let lifecycle = record[Self.fieldSyncLifecycle] as? String
        let schemaVersion = intValue(from: record[Self.fieldSyncSchemaVersion])
        return lifecycle == Self.syncLifecycleActive && schemaVersion >= Self.activeManifestSchemaVersion
    }

    private func isTrustedManifestRecord(_ record: CKRecord) -> Bool {
        intValue(from: record[Self.fieldManifestSchemaVersion]) >= Self.activeManifestSchemaVersion
    }

    private var activeManifestMigrationCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.activeManifestMigrationCompletedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.activeManifestMigrationCompletedKey) }
    }

    private var quarantinedBackupRecordNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.quarantinedBackupRecordNamesKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.quarantinedBackupRecordNamesKey) }
    }

    private var quarantinedLegacySummaryRecordNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.quarantinedLegacySummaryRecordNamesKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.quarantinedLegacySummaryRecordNamesKey) }
    }

    private func removeQuarantineEntries(backupRecordNames: [String], legacySummaryRecordNames: [String]) {
        if !backupRecordNames.isEmpty {
            quarantinedBackupRecordNames.subtract(backupRecordNames)
        }
        if !legacySummaryRecordNames.isEmpty {
            quarantinedLegacySummaryRecordNames.subtract(legacySummaryRecordNames)
        }
    }

    private func intValue(from rawValue: Any?, defaultValue: Int = 0) -> Int {
        if let value = rawValue as? Int {
            return value
        }
        if let value = rawValue as? Int64 {
            return Int(value)
        }
        if let value = rawValue as? NSNumber {
            return value.intValue
        }
        return defaultValue
    }

    private func int64Value(from rawValue: Any?, defaultValue: Int64 = 0) -> Int64 {
        if let value = rawValue as? Int64 {
            return value
        }
        if let value = rawValue as? Int {
            return Int64(value)
        }
        if let value = rawValue as? NSNumber {
            return value.int64Value
        }
        return defaultValue
    }

    private func doubleValue(from rawValue: Any?, defaultValue: Double = 0) -> Double {
        if let value = rawValue as? Double {
            return value
        }
        if let value = rawValue as? NSNumber {
            return value.doubleValue
        }
        return defaultValue
    }

    private func validateiCloudAccountAvailability(using container: CKContainer) async throws {
        let accountStatus = try await container.accountStatus()
        guard accountStatus == .available else {
            throw NSError(
                domain: "iCloudStorageManager",
                code: 4003,
                userInfo: [NSLocalizedDescriptionKey: "iCloud account is not available."]
            )
        }
    }

    private func fetchOrCreateRecord(
        recordType: String,
        recordID: CKRecord.ID,
        database: CKDatabase
    ) async throws -> CKRecord {
        do {
            let existingRecord = try await database.record(for: recordID)
            if existingRecord.recordType == recordType {
                return existingRecord
            }
        } catch let error as CKError where error.code == .unknownItem {
            // No existing record - create one below.
        }

        return CKRecord(recordType: recordType, recordID: recordID)
    }

    private func fetchBackupRecordsByUUID(
        recordType: String,
        recordNamePrefix: String,
        database: CKDatabase
    ) async throws -> [UUID: CKRecord] {
        let indexedRecords = try await fetchIndexedBackupRecords(
            recordType: recordType,
            database: database
        )
        let records: [CKRecord]
        if !indexedRecords.isEmpty {
            records = indexedRecords
        } else {
            records = try await fetchBackupRecords(
                recordType: recordType,
                database: database
            )
        }

        var recordsByUUID: [UUID: CKRecord] = [:]
        for record in records {
            guard let uuid = decodeBackupRecordUUID(
                recordName: record.recordID.recordName,
                prefix: recordNamePrefix
            ) else {
                continue
            }
            recordsByUUID[uuid] = record
        }

        return recordsByUUID
    }

    private func fetchIndexedBackupRecords(
        recordType: String,
        database: CKDatabase
    ) async throws -> [CKRecord] {
        let indexedRecords = try await fetchBackupRecordsFromContentIndex(database: database)
        switch recordType {
        case Self.backupRecordingRecordType:
            return indexedRecords.recordings
        case Self.backupTranscriptRecordType:
            return indexedRecords.transcripts
        case Self.backupSummaryRecordType:
            return indexedRecords.summaries
        default:
            return []
        }
    }

    private func fetchBackupRecords(
        recordType: String,
        database: CKDatabase
    ) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))

        do {
            var records: [CKRecord] = []
            var fetchResult = try await database.records(matching: query)

            while true {
                for (_, result) in fetchResult.matchResults {
                    if case .success(let record) = result {
                        records.append(record)
                    }
                }

                guard let queryCursor = fetchResult.queryCursor else {
                    break
                }
                fetchResult = try await database.records(continuingMatchFrom: queryCursor)
            }

            if !records.isEmpty {
                return records
            }

            let zoneQueryRecords = try await fetchBackupRecordsInDefaultZoneQuery(
                recordType: recordType,
                database: database
            )
            if !zoneQueryRecords.isEmpty {
                return zoneQueryRecords
            }

            let zoneChangeRecords = try await fetchBackupRecordsUsingZoneChanges(
                recordType: recordType,
                database: database
            )
            if !zoneChangeRecords.isEmpty {
                return zoneChangeRecords
            }

            return []
        } catch {
            return try await fetchBackupRecordsUsingZoneChanges(
                recordType: recordType,
                database: database
            )
        }
    }

    private func fetchBackupRecordsInDefaultZoneQuery(
        recordType: String,
        database: CKDatabase
    ) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        let (matchResults, _) = try await database.records(
            matching: query,
            inZoneWith: CKRecordZone.default().zoneID,
            desiredKeys: nil,
            resultsLimit: 1000
        )

        var records: [CKRecord] = []
        for (_, result) in matchResults {
            if case .success(let record) = result {
                records.append(record)
            }
        }
        return records
    }

    private func fetchBackupRecordsUsingZoneChanges(
        recordType: String,
        database: CKDatabase
    ) async throws -> [CKRecord] {
        let zoneID = CKRecordZone.default().zoneID

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: nil
        )

        let lock = NSLock()
        var records: [CKRecord] = []

        operation.recordWasChangedBlock = { _, result in
            if case .success(let record) = result, record.recordType == recordType {
                lock.lock()
                records.append(record)
                lock.unlock()
            }
        }

        _ = try await withCheckedThrowingContinuation { continuation in
            operation.fetchRecordZoneChangesResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(operation)
        }

        return records
    }

    private func cloudHasAnyContentBackupRecord(database: CKDatabase) async throws -> Bool {
        let indexedRecords = try await fetchBackupRecordsFromContentIndex(database: database)
        if !indexedRecords.recordings.isEmpty ||
            !indexedRecords.transcripts.isEmpty ||
            !indexedRecords.summaries.isEmpty {
            return true
        }

        if try await hasAtLeastOneBackupRecord(recordType: Self.backupRecordingRecordType, database: database) {
            return true
        }
        if try await hasAtLeastOneBackupRecord(recordType: Self.backupTranscriptRecordType, database: database) {
            return true
        }
        if try await hasAtLeastOneBackupRecord(recordType: Self.backupSummaryRecordType, database: database) {
            return true
        }
        return false
    }

    private func hasAtLeastOneBackupRecord(
        recordType: String,
        database: CKDatabase
    ) async throws -> Bool {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        do {
            let (matchResults, _) = try await database.records(
                matching: query,
                inZoneWith: CKRecordZone.default().zoneID,
                desiredKeys: nil,
                resultsLimit: 1
            )
            return matchResults.contains { (_, result) in
                if case .success = result {
                    return true
                }
                return false
            }
        } catch {
            // Fallback for accounts/environments where this query variant is unavailable.
            let records = try await fetchBackupRecords(recordType: recordType, database: database)
            return !records.isEmpty
        }
    }

    private func saveBackupContentIndex(
        database: CKDatabase,
        recordingRecordNames: [String],
        transcriptRecordNames: [String],
        summaryRecordNames: [String]
    ) async throws {
        let recordID = CKRecord.ID(recordName: Self.backupContentIndexRecordName)
        let record = try await fetchOrCreateRecord(
            recordType: Self.backupContentIndexRecordType,
            recordID: recordID,
            database: database
        )

        record[Self.fieldIndexRecordingRecordNames] = recordingRecordNames as NSArray
        record[Self.fieldIndexTranscriptRecordNames] = transcriptRecordNames as NSArray
        record[Self.fieldIndexSummaryRecordNames] = summaryRecordNames as NSArray
        record[Self.fieldSettingsSchemaVersion] = Self.backupSchemaVersion
        record[Self.fieldManifestSchemaVersion] = Self.activeManifestSchemaVersion
        record[Self.fieldSettingsUpdatedAt] = Date()
        record[Self.fieldDeviceIdentifier] = deviceIdentifier

        try await saveBackupRecord(record, database: database)
    }

    private func fetchTrustedActiveManifestRecordNames(database: CKDatabase) async throws -> ActiveManifestRecordNames {
        let recordID = CKRecord.ID(recordName: Self.backupContentIndexRecordName)

        do {
            let indexRecord = try await database.record(for: recordID)
            guard isTrustedManifestRecord(indexRecord) else {
                return ActiveManifestRecordNames()
            }
            return ActiveManifestRecordNames(
                recordings: Set(indexRecord[Self.fieldIndexRecordingRecordNames] as? [String] ?? []),
                transcripts: Set(indexRecord[Self.fieldIndexTranscriptRecordNames] as? [String] ?? []),
                summaries: Set(indexRecord[Self.fieldIndexSummaryRecordNames] as? [String] ?? [])
            )
        } catch let error as CKError where error.code == .unknownItem {
            return ActiveManifestRecordNames()
        }
    }

    private func fetchBackupRecordsFromContentIndex(
        database: CKDatabase
    ) async throws -> BackupContentRecordsFromIndex {
        let recordID = CKRecord.ID(recordName: Self.backupContentIndexRecordName)

        do {
            let indexRecord = try await database.record(for: recordID)
            let recordingNames = indexRecord[Self.fieldIndexRecordingRecordNames] as? [String] ?? []
            let transcriptNames = indexRecord[Self.fieldIndexTranscriptRecordNames] as? [String] ?? []
            let summaryNames = indexRecord[Self.fieldIndexSummaryRecordNames] as? [String] ?? []

            return BackupContentRecordsFromIndex(
                recordings: try await fetchBackupRecordsByRecordNames(
                    recordingNames,
                    expectedRecordType: Self.backupRecordingRecordType,
                    database: database
                ),
                transcripts: try await fetchBackupRecordsByRecordNames(
                    transcriptNames,
                    expectedRecordType: Self.backupTranscriptRecordType,
                    database: database
                ),
                summaries: try await fetchBackupRecordsByRecordNames(
                    summaryNames,
                    expectedRecordType: Self.backupSummaryRecordType,
                    database: database
                )
            )
        } catch let error as CKError where error.code == .unknownItem {
            return BackupContentRecordsFromIndex()
        } catch {
            throw error
        }
    }

    private func removeBackupRecordNamesFromContentIndex(
        database: CKDatabase,
        recordingRecordNames: [String],
        transcriptRecordNames: [String],
        summaryRecordNames: [String]
    ) async throws {
        let recordID = CKRecord.ID(recordName: Self.backupContentIndexRecordName)

        do {
            let indexRecord = try await database.record(for: recordID)
            let recordingNamesToRemove = Set(recordingRecordNames)
            let transcriptNamesToRemove = Set(transcriptRecordNames)
            let summaryNamesToRemove = Set(summaryRecordNames)

            let currentRecordingNames = indexRecord[Self.fieldIndexRecordingRecordNames] as? [String] ?? []
            let currentTranscriptNames = indexRecord[Self.fieldIndexTranscriptRecordNames] as? [String] ?? []
            let currentSummaryNames = indexRecord[Self.fieldIndexSummaryRecordNames] as? [String] ?? []

            try await saveBackupContentIndex(
                database: database,
                recordingRecordNames: currentRecordingNames.filter { !recordingNamesToRemove.contains($0) },
                transcriptRecordNames: currentTranscriptNames.filter { !transcriptNamesToRemove.contains($0) },
                summaryRecordNames: currentSummaryNames.filter { !summaryNamesToRemove.contains($0) }
            )
        } catch let error as CKError where error.code == .unknownItem {
            return
        }
    }

    private func fetchBackupRecordsByRecordNames(
        _ recordNames: [String],
        expectedRecordType: String,
        database: CKDatabase
    ) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        records.reserveCapacity(recordNames.count)

        for recordName in recordNames {
            let recordID = CKRecord.ID(recordName: recordName)
            do {
                let record = try await database.record(for: recordID)
                if record.recordType == expectedRecordType {
                    records.append(record)
                }
            } catch let error as CKError where error.code == .unknownItem {
                continue
            } catch {
                throw error
            }
        }

        return records
    }

    // MARK: - Multi-Device Arbitration
    //
    // Two devices can hold different versions of the same item. Both sync legs
    // consult the item's *content* timestamp — never `syncUpdatedAt`, which is
    // rewritten on every save and would make the cloud copy look permanently
    // newer — so the newest edit wins regardless of which device syncs last.
    //
    // Both rules deliberately fall back to the previous "local wins on upload,
    // cloud wins on restore" behaviour when either side has no usable timestamp:
    // an unknown age must never block an item from syncing.

    static let recordingContentTimestampKeys = [fieldLastModified, fieldCreatedAt, fieldRecordingDate]
    static let transcriptContentTimestampKeys = [fieldLastModified, fieldCreatedAt]
    static let summaryContentTimestampKeys = [fieldLastModified, fieldGeneratedAt, fieldCreatedAt]

    /// A local edit is only treated as beating a delete from another device when it
    /// lands more than this far after the deletion. Absorbs cross-device clock skew
    /// and the common race where a delete and a background write happen together.
    static let deletionReviveGraceInterval: TimeInterval = 60

    /// True when this device should write its version over the cloud record.
    static func shouldUploadLocalVersion(localTimestamp: Date?, cloudTimestamp: Date?) -> Bool {
        guard let localTimestamp, let cloudTimestamp else { return true }
        return localTimestamp >= cloudTimestamp
    }

    /// True when a cloud record should overwrite the matching local row.
    static func shouldApplyCloudVersion(cloudTimestamp: Date?, localTimestamp: Date?) -> Bool {
        guard let cloudTimestamp, let localTimestamp else { return true }
        return cloudTimestamp >= localTimestamp
    }

    /// True when a local item changed after another device deleted it, so the later
    /// edit wins and the tombstone should be withdrawn instead of applied.
    static func shouldReviveLocallyModifiedItem(localTimestamp: Date?, deletedAt: Date) -> Bool {
        // Without both timestamps there is no proof the local edit came after the
        // delete, and a tombstone must never be withdrawn on a guess. `distantPast`
        // is the sentinel `decodeDeletionTarget` uses for a marker with no time.
        guard let localTimestamp, deletedAt > .distantPast else { return false }
        return localTimestamp > deletedAt.addingTimeInterval(deletionReviveGraceInterval)
    }

    /// A tombstone records when the user actually deleted the item, not when the
    /// marker reached CloudKit. If two devices report the same deletion, the earliest
    /// claim wins so a late-arriving marker cannot erase newer work elsewhere.
    static func resolvedDeletionTimestamp(existing: Date?, requested: Date) -> Date {
        guard let existing else { return requested }
        return min(existing, requested)
    }

    /// The content timestamp of a cloud backup record, or nil when it carries none.
    private func backupRecordContentTimestamp(_ record: CKRecord, keys: [String]) -> Date? {
        for key in keys {
            if let value = record[key] as? Date {
                return value
            }
        }
        return nil
    }

    private func localRecordingContentTimestamp(_ recording: RecordingEntry) -> Date? {
        recording.lastModified ?? recording.createdAt ?? recording.recordingDate
    }

    private func localTranscriptContentTimestamp(_ transcript: TranscriptEntry) -> Date? {
        transcript.lastModified ?? transcript.createdAt
    }

    private func localSummaryContentTimestamp(_ summary: SummaryEntry) -> Date? {
        summary.generatedAt ?? summary.recording?.recordingDate
    }

    /// Attaches the recording's audio to its backup record when the stored signature
    /// does not match the file on disk. Returns true when a new asset was attached.
    private func attachAudioBackupIfNeeded(
        recording: RecordingEntry,
        to record: CKRecord,
        appCoordinator: AppDataCoordinator,
        result: inout CloudBackupResult,
        changed: inout Bool
    ) -> Bool {
        guard let localURL = appCoordinator.getAbsoluteURL(for: recording),
              FileManager.default.fileExists(atPath: localURL.path) else {
            return false
        }

        let signature = audioFileSignature(for: localURL)
        guard signature != record[Self.fieldAudioSignature] as? String else {
            result.audioFilesSkippedUnchanged += 1
            return false
        }

        record[Self.fieldAudioAsset] = CKAsset(fileURL: localURL)
        updateStringField(Self.fieldAudioFileName, value: localURL.lastPathComponent, on: record, changed: &changed)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
           let size = attributes[.size] as? Int64 {
            updateInt64Field(Self.fieldAudioByteCount, value: size, on: record, changed: &changed)
        }
        updateStringField(Self.fieldAudioSignature, value: signature, on: record, changed: &changed)
        return true
    }
    /// Local counterpart of `resolveLatestRecordsPerRecording`: picks the one row per
    /// recording that every device will agree on, and reports the rows it supersedes.
    ///
    /// The two rules must stay in step — newest timestamp wins, ties broken on the
    /// identifier — because the cloud copy is deduplicated by one and the local rows
    /// by the other. If they disagree, devices trade uploads and deletions forever.
    /// Rows with no recording are never grouped, so they are always kept.
    static func latestPerRecording<Item>(
        _ items: [Item],
        recordingId: (Item) -> UUID?,
        timestamp: (Item) -> Date?,
        identifier: (Item) -> UUID?
    ) -> (kept: [Item], superseded: [Item]) {
        var winnersByRecordingId: [UUID: Item] = [:]
        var kept: [Item] = []
        var superseded: [Item] = []

        func isNewer(_ candidate: Item, than current: Item) -> Bool {
            let candidateTimestamp = timestamp(candidate) ?? .distantPast
            let currentTimestamp = timestamp(current) ?? .distantPast
            if candidateTimestamp != currentTimestamp {
                return candidateTimestamp > currentTimestamp
            }
            // Same tie-breaker as the cloud rule, whose record names are the identifier
            // behind a shared prefix.
            return (identifier(candidate)?.uuidString ?? "") > (identifier(current)?.uuidString ?? "")
        }

        for item in items {
            guard let groupId = recordingId(item) else {
                kept.append(item)
                continue
            }

            if let currentWinner = winnersByRecordingId[groupId] {
                if isNewer(item, than: currentWinner) {
                    superseded.append(currentWinner)
                    winnersByRecordingId[groupId] = item
                } else {
                    superseded.append(item)
                }
            } else {
                winnersByRecordingId[groupId] = item
            }
        }

        return (kept + Array(winnersByRecordingId.values), superseded)
    }

    private func resolveLatestRecordsPerRecording(
        _ records: [CKRecord],
        recordingIdField: String,
        timestampKeys: [String]
    ) -> LatestPerRecordingResolution {
        var winnersByRecordingId: [UUID: CKRecord] = [:]
        var recordsWithoutRecordingId: [CKRecord] = []
        var loserRecordIDs: [CKRecord.ID] = []

        for record in records {
            guard let recordingIdValue = record[recordingIdField] as? String,
                  let recordingId = UUID(uuidString: recordingIdValue) else {
                recordsWithoutRecordingId.append(record)
                continue
            }

            if let currentWinner = winnersByRecordingId[recordingId] {
                if isBackupRecord(record, newerThan: currentWinner, timestampKeys: timestampKeys) {
                    loserRecordIDs.append(currentWinner.recordID)
                    winnersByRecordingId[recordingId] = record
                } else {
                    loserRecordIDs.append(record.recordID)
                }
            } else {
                winnersByRecordingId[recordingId] = record
            }
        }

        return LatestPerRecordingResolution(
            keptRecords: Array(winnersByRecordingId.values) + recordsWithoutRecordingId,
            loserRecordIDs: loserRecordIDs
        )
    }

    private func isBackupRecord(
        _ candidate: CKRecord,
        newerThan current: CKRecord,
        timestampKeys: [String]
    ) -> Bool {
        let candidateTimestamp = backupRecordTimestamp(candidate, keys: timestampKeys)
        let currentTimestamp = backupRecordTimestamp(current, keys: timestampKeys)

        if candidateTimestamp != currentTimestamp {
            return candidateTimestamp > currentTimestamp
        }

        // Deterministic tie-breaker for equal timestamps.
        return candidate.recordID.recordName > current.recordID.recordName
    }

    private func backupRecordTimestamp(_ record: CKRecord, keys: [String]) -> Date {
        for key in keys {
            if let value = record[key] as? Date {
                return value
            }
        }
        return Date.distantPast
    }

    private func deleteBackupRecords(_ recordIDs: [CKRecord.ID], database: CKDatabase) async throws {
        var seenRecordNames = Set<String>()
        for recordID in recordIDs where !seenRecordNames.contains(recordID.recordName) {
            seenRecordNames.insert(recordID.recordName)
            try await deleteBackupRecord(recordID, database: database)
        }
    }

    private func deleteBackupRecord(_ recordID: CKRecord.ID, database: CKDatabase) async throws {
        var attempt = 0

        while true {
            do {
                _ = try await database.deleteRecord(withID: recordID)
                return
            } catch let ckError as CKError {
                if ckError.code == .unknownItem {
                    return
                }

                attempt += 1
                let shouldRetry = ckError.isRetryable && attempt < maxRetryAttempts
                guard shouldRetry else {
                    throw ckError
                }

                let delaySeconds = max(
                    ckError.suggestedRetryAfterSeconds ?? (retryDelay * Double(attempt)),
                    0.5
                )
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                throw error
            }
        }
    }

    private func saveBackupRecord(_ record: CKRecord, database: CKDatabase) async throws {
        var attempt = 0
        var recordToSave = record

        while true {
            do {
                _ = try await database.save(recordToSave)
                return
            } catch let ckError as CKError {
                attempt += 1

                if let schemaError = cloudBackupProductionSchemaError(from: ckError, recordType: record.recordType) {
                    AppLog.shared.iCloudSync(schemaError.localizedDescription, level: .error)
                    throw schemaError
                }

                if isRecordAlreadyExistsConflict(ckError), attempt < maxRetryAttempts {
                    do {
                        let serverRecord = try await database.record(for: record.recordID)
                        mergeBackupRecordFields(from: recordToSave, into: serverRecord)
                        recordToSave = serverRecord
                        continue
                    } catch {
                        // If the server read fails transiently, fall through to normal retry logic below.
                    }
                }

                let shouldRetry = ckError.isRetryable && attempt < maxRetryAttempts
                guard shouldRetry else {
                    AppLog.shared.iCloudSync("CloudKit save failed: \(ckError.localizedDescription)", level: .error)
                    throw ckError
                }

                let delaySeconds = max(
                    ckError.suggestedRetryAfterSeconds ?? (retryDelay * Double(attempt)),
                    0.5
                )
                AppLog.shared.iCloudSync(
                    "CloudKit save retry \(attempt)/\(maxRetryAttempts) " +
                    "in \(String(format: "%.1f", delaySeconds))s: \(ckError.localizedDescription)",
                    level: .error
                )
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                throw error
            }
        }
    }

    static func backupSourceSelection(from coreDataManager: CoreDataManager) -> CloudBackupSourceSelection {
        let allRecordings = coreDataManager.getAllRecordings()
        let excludedRecordingIds = Set(allRecordings.compactMap { recording in
            recording.isCloudSyncDisabled ? recording.id : nil
        })
        let recordings = allRecordings.filter { recording in
            guard let recordingId = recording.id else { return true }
            return !excludedRecordingIds.contains(recordingId)
        }
        let syncableTranscripts = coreDataManager.getAllTranscripts().filter { transcript in
            guard let recordingId = transcript.recordingId else { return true }
            return !excludedRecordingIds.contains(recordingId)
        }
        let syncableSummaries = coreDataManager.getAllSummaries().filter { summary in
            let recordingId = summary.recordingId ?? summary.recording?.id
            guard let recordingId else { return true }
            return !excludedRecordingIds.contains(recordingId)
        }

        // Only the current row per recording is worth uploading. Sending older
        // duplicates too meant the cloud-side dedupe deleted them again on every
        // pass, so each sync re-uploaded and re-deleted the same records.
        let transcripts = latestPerRecording(
            syncableTranscripts,
            recordingId: { $0.recordingId ?? $0.recording?.id },
            timestamp: { $0.lastModified ?? $0.createdAt },
            identifier: { $0.id }
        )
        let summaries = latestPerRecording(
            syncableSummaries,
            recordingId: { $0.recordingId ?? $0.recording?.id },
            timestamp: { $0.generatedAt ?? $0.recording?.recordingDate },
            identifier: { $0.id }
        )

        return CloudBackupSourceSelection(
            recordings: recordings,
            transcripts: transcripts.kept,
            summaries: summaries.kept,
            excludedRecordingIds: excludedRecordingIds,
            supersededTranscripts: transcripts.superseded,
            supersededSummaries: summaries.superseded
        )
    }

    /// Drops local transcript/summary rows that a newer row for the same recording has
    /// superseded, so two devices that each created their own copy converge instead of
    /// trading uploads. Only rows the recording no longer points at are removed, and no
    /// iCloud deletion markers are written — see `deleteSupersededDuplicates`.
    func pruneSupersededLocalDuplicates(
        appCoordinator: AppDataCoordinator
    ) -> (transcripts: Int, summaries: Int) {
        let selection = Self.backupSourceSelection(from: appCoordinator.coreDataManager)
        guard !selection.supersededTranscripts.isEmpty || !selection.supersededSummaries.isEmpty else {
            return (0, 0)
        }

        return appCoordinator.coreDataManager.deleteSupersededDuplicates(
            transcriptIds: selection.supersededTranscripts.compactMap(\.id),
            summaryIds: selection.supersededSummaries.compactMap(\.id)
        )
    }

    private func cloudBackupProductionSchemaError(from error: CKError, recordType: String) -> NSError? {
        let diagnosticText = "\(error.localizedDescription) \(String(describing: error))".lowercased()
        let isMissingTypeInProduction = Self.isMissingProductionSchemaDiagnostic(diagnosticText)

        guard isMissingTypeInProduction else {
            return nil
        }

        return Self.cloudBackupProductionSchemaError(recordType: recordType)
    }

    static func isMissingProductionSchemaDiagnostic(_ diagnosticText: String) -> Bool {
        let normalized = diagnosticText.lowercased()
        return normalized.contains("cannot create new type") &&
            normalized.contains("production schema")
    }

    static func cloudBackupProductionSchemaError(recordType: String) -> NSError {
        NSError(
            domain: "iCloudStorageManager",
            code: Self.missingProductionSchemaErrorCode,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "iCloud sync needs a CloudKit production schema update before this build can save \(recordType). " +
                    "Deploy the development CloudKit schema for \(Self.sharedContainerIdentifier) to production, then try syncing again."
            ]
        )
    }

    private func mergeBackupRecordFields(from source: CKRecord, into destination: CKRecord) {
        for key in source.allKeys() {
            destination[key] = source[key]
        }
    }

    private func isRecordAlreadyExistsConflict(_ error: CKError) -> Bool {
        if error.code == .serverRecordChanged {
            return true
        }

        if error.localizedDescription.lowercased().contains("already exists") {
            return true
        }

        if let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            for nestedError in partialErrors.values {
                if let nestedCKError = nestedError as? CKError {
                    if isRecordAlreadyExistsConflict(nestedCKError) {
                        return true
                    }
                } else if nestedError.localizedDescription.lowercased().contains("already exists") {
                    return true
                }
            }
        }

        return false
    }

    private func backupSettingsToiCloud(
        database: CKDatabase,
        includeSensitiveSettings: Bool
    ) async throws -> (backedUp: Bool, includedSensitiveSettings: Bool) {
        let settingsValues = collectSettingsForBackup(includeSensitiveSettings: includeSensitiveSettings)
        guard !settingsValues.values.isEmpty else {
            return (false, false)
        }

        let payload = CodableSettingsBackupPayload(
            createdAt: Date(),
            includesSensitiveValues: settingsValues.includedSensitiveSettings,
            sourcePlatform: Self.currentSettingsPlatform,
            values: settingsValues.values
        )
        let payloadData = try JSONEncoder().encode(payload)

        let recordID = CKRecord.ID(recordName: Self.backupSettingsRecordName)
        let record = try await fetchOrCreateRecord(
            recordType: Self.backupSettingsRecordType,
            recordID: recordID,
            database: database
        )

        record[Self.fieldSettingsPayload] = payloadData
        record[Self.fieldSettingsIncludesSensitive] = payload.includesSensitiveValues
        record[Self.fieldSettingsSchemaVersion] = Self.backupSchemaVersion
        record[Self.fieldSettingsUpdatedAt] = Date()
        record[Self.fieldDeviceIdentifier] = deviceIdentifier

        try await saveBackupRecord(record, database: database)
        return (true, payload.includesSensitiveValues)
    }

    private func restoreSettingsFromiCloud(
        database: CKDatabase
    ) async throws -> (restored: Bool, includedSensitiveSettings: Bool) {
        let recordID = CKRecord.ID(recordName: Self.backupSettingsRecordName)

        do {
            let record = try await database.record(for: recordID)
            guard let rawPayloadData = record[Self.fieldSettingsPayload] as? Data else {
                return (false, false)
            }

            let includesSensitive = record[Self.fieldSettingsIncludesSensitive] as? Bool ?? false

            let payload = try JSONDecoder().decode(CodableSettingsBackupPayload.self, from: rawPayloadData)
            applySettingsPayload(payload)
            return (true, includesSensitive)
        } catch let error as CKError where error.code == .unknownItem {
            return (false, false)
        }
    }

    private func collectSettingsForBackup(includeSensitiveSettings: Bool) -> (values: [String: Data], includedSensitiveSettings: Bool) {
        var encodedValues: [String: Data] = [:]
        var includedSensitive = false
        let defaults = UserDefaults.standard

        for key in Self.backedUpSettingsKeys {
            guard let rawValue = defaults.object(forKey: key) else { continue }

            let sensitive = isSensitiveSettingKey(key)
            if sensitive && !includeSensitiveSettings {
                continue
            }

            guard let encoded = try? PropertyListSerialization.data(
                fromPropertyList: rawValue,
                format: .binary,
                options: 0
            ) else {
                continue
            }

            encodedValues[key] = encoded
            if sensitive {
                includedSensitive = true
            }
        }

        return (encodedValues, includedSensitive)
    }

    private func applySettingsPayload(_ payload: CodableSettingsBackupPayload) {
        let defaults = UserDefaults.standard

        for (key, encodedValue) in payload.values {
            guard shouldApplySettingsKey(
                key,
                encodedValue: encodedValue,
                sourcePlatform: payload.sourcePlatform
            ) else {
                AppLog.shared.iCloudSync(
                    "Skipped platform-specific setting '\(key)' from \(payload.sourcePlatform ?? "legacy") backup",
                    level: .debug
                )
                continue
            }

            if KeychainSecretStore.isLegacyAWSSettingKey(key) {
                // Never restore settings from the removed AWS provider. This
                // also handles backups created before AWS settings were removed
                // from backedUpSettingsKeys.
                defaults.removeObject(forKey: key)
                continue
            }

            guard let rawValue = try? PropertyListSerialization.propertyList(
                from: encodedValue,
                options: [],
                format: nil
            ) else {
                continue
            }

            if applyLegacySensitiveSetting(rawValue, forKey: key) {
                defaults.removeObject(forKey: key)
                continue
            }

            guard let restoredValue = restoredValue(forKey: key, rawValue: rawValue) else {
                continue
            }

            defaults.set(restoredValue, forKey: key)
        }

        defaults.synchronize()
    }

    /// Adjusts a backed-up value for the device it is being restored onto.
    /// Returns nil to skip the key entirely.
    private func restoredValue(forKey key: String, rawValue: Any) -> Any? {
        guard key == MLXSwiftSettingsKeys.modelId else {
            return rawValue
        }

        // A model id is only meaningful relative to device RAM and platform.
        // Restoring an 8GB device's 8B selection onto a 4GB device — or a Mac
        // backup's 27B onto an iPhone, where it is not even in the catalog —
        // would strand the engine on a model it can never load.
        guard let requestedModelId = rawValue as? String else {
            return rawValue
        }

        return MLXSwiftSettingsKeys.supportedModelId(
            requestedModelId,
            forRAM: DeviceCapabilities.totalRAMInGB
        )
    }

    private func shouldApplySettingsKey(
        _ key: String,
        encodedValue: Data,
        sourcePlatform: String?
    ) -> Bool {
        // Do not restore settings or engine selections for the removed
        // llama.cpp engine from an older iCloud backup.
        if LegacyLlamaMigration.legacySettingsKeys.contains(key) {
            return false
        }

        if key == "SelectedAIEngine",
           let rawValue = try? PropertyListSerialization.propertyList(
               from: encodedValue,
               options: [],
               format: nil
           ),
           let selectedEngine = rawValue as? String,
           LegacyLlamaMigration.isLegacyEngineIdentifier(selectedEngine) {
            return false
        }

        guard Self.platformSpecificSettingsKeys.contains(key) else {
            return true
        }

        if let sourcePlatform {
            return sourcePlatform == Self.currentSettingsPlatform
        }

        // Older payloads did not identify their source platform. Protect iOS
        // from restoring Ollama state from those legacy Mac backups while
        // preserving the existing behavior for other settings.
        guard !AIEngineType.localLLM.isSupportedOnCurrentPlatform else {
            return true
        }

        if Self.ollamaSettingsKeys.contains(key) {
            return false
        }

        guard key == "SelectedAIEngine",
              let rawValue = try? PropertyListSerialization.propertyList(
                  from: encodedValue,
                  options: [],
                  format: nil
              ),
              let selectedEngine = rawValue as? String else {
            return true
        }

        return selectedEngine != AIEngineType.localLLM.rawValue
    }

    private func applyLegacySensitiveSetting(_ rawValue: Any, forKey key: String) -> Bool {
        switch key {
        case KeychainSecretStore.openAIAPIKey,
             KeychainSecretStore.openAICompatibleAPIKey,
             KeychainSecretStore.googleAIStudioAPIKey,
             KeychainSecretStore.mistralAPIKey:
            guard let value = rawValue as? String else { return true }
            KeychainSecretStore.shared.setString(value, forKey: key)
            return true
        default:
            return false
        }
    }

    func isSensitiveSettingKey(_ key: String) -> Bool {
        let lowercase = key.lowercased()
        // Substring match for unambiguous credential fragments (e.g. "apikey", "secret")
        if Self.sensitiveSettingKeyFragments.contains(where: { lowercase.contains($0) }) {
            return true
        }
        // Suffix match for "token" variants to avoid false positives on keys
        // like "openAISummarizationMaxTokens" or "ollamaMaxTokens".
        return Self.sensitiveSettingExactSuffixes.contains { lowercase.hasSuffix($0) }
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

    var suggestedRetryAfterSeconds: Double? {
        if let retryAfter = userInfo[CKErrorRetryAfterKey] as? NSNumber {
            return retryAfter.doubleValue
        }
        return nil
    }

    // MARK: - Debug Methods

    /// Debug method to check current Core Data state
    @MainActor
    func debugCoreDataState(appCoordinator: AppDataCoordinator) {
        // Debug logging removed - function kept for potential future use
        _ = appCoordinator.coreDataManager.getAllRecordings()
        _ = appCoordinator.coreDataManager.getAllSummaries()
    }

}

// MARK: - Network Monitor

class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private let statusCallback: @Sendable (NetworkStatus) -> Void

    init(statusCallback: @escaping @Sendable (NetworkStatus) -> Void) {
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
        let statusCallback = statusCallback
        monitor.pathUpdateHandler = { path in
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

            statusCallback(status)
        }

        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
