import Foundation
import CloudKit
import SwiftUI
import Network
import CoreData
import Synchronization

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

    // MARK: - Auto-Backup

    /// Debounce timer for auto-backup after data changes
    private var autoBackupTimer: Timer?

    /// Delay before auto-backup fires after the last data change (2 minutes)
    /// Long enough to fold a burst of edits into one upload, short enough that a
    /// change is in the cloud before the user looks at another device.
    private let autoBackupDebounceInterval: TimeInterval = 3

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

    // MARK: - Sync Engine

    /// Every CloudKit request the sync legs make goes through these four objects.
    /// Tests inject a scripted transport, a manual clock, and a sleeper that does
    /// not wait, so batching, retries, manifest conflicts, and phase order can be
    /// proved without a network or a deployed schema.
    private let injectedTransport: (any CloudKitTransport)?
    private let syncClock: any CloudSyncClock
    private let syncSleeper: any CloudSyncSleeper
    private let syncPreferences: any CloudSyncPreferencesStore
    private let syncMetricsSink: (any CloudSyncMetricsSink)?

    private var cachedTransport: (any CloudKitTransport)?
    private var cachedExecutor: CloudKitBatchExecutor?
    private var cachedContentIndexCoordinator: CloudContentIndexCoordinator?

    /// Serializes every CloudKit operation. Requests that arrive mid-run join it or
    /// collapse into one follow-up instead of stacking up behind each other.
    let operationCoordinator = CloudSyncOperationCoordinator()

    /// The metrics recorder for the run in progress, when there is one.
    private var activeRunRecorder: CloudSyncRunRecorder?

    var cloudTransport: any CloudKitTransport {
        if let injectedTransport { return injectedTransport }
        if let cachedTransport { return cachedTransport }
        let transport = CKDatabaseCloudKitTransport(container: Self.sharedCloudKitContainer())
        cachedTransport = transport
        return transport
    }

    var cloudExecutor: CloudKitBatchExecutor {
        if let cachedExecutor { return cachedExecutor }
        let executor = CloudKitBatchExecutor(
            transport: cloudTransport,
            sleeper: syncSleeper,
            clock: syncClock,
            preferences: syncPreferences
        )
        cachedExecutor = executor
        return executor
    }

    var contentIndexCoordinator: CloudContentIndexCoordinator {
        if let cachedContentIndexCoordinator { return cachedContentIndexCoordinator }
        let coordinator = CloudContentIndexCoordinator(
            executor: cloudExecutor,
            configuration: Self.contentIndexConfiguration,
            deviceIdentifier: deviceIdentifier,
            clock: syncClock
        )
        cachedContentIndexCoordinator = coordinator
        return coordinator
    }

    func recordMetrics(fetch outcome: CloudKitFetchOutcome) {
        activeRunRecorder?.add(fetch: outcome)
    }

    func recordMetrics(modify outcome: CloudKitModifyOutcome) {
        activeRunRecorder?.add(modify: outcome)
    }

    init(
        transport: (any CloudKitTransport)? = nil,
        clock: any CloudSyncClock = SystemCloudSyncClock(),
        sleeper: any CloudSyncSleeper = SystemCloudSyncSleeper(),
        preferences: any CloudSyncPreferencesStore = UserDefaultsCloudSyncPreferencesStore(),
        metricsSink: (any CloudSyncMetricsSink)? = CloudSyncLogMetricsSink()
    ) {
        self.injectedTransport = transport
        self.syncClock = clock
        self.syncSleeper = sleeper
        self.syncPreferences = preferences
        self.syncMetricsSink = metricsSink
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

    /// Performs batch sync of queued summaries.
    ///
    /// The whole queue is prepared in memory and saved in one batched request. The
    /// previous shape — one save per summary, a half-second sleep between each, and
    /// a fixed thirty-second wait before the next batch — spent almost all of its
    /// time asleep rather than transferring.
    private func performBatchSync() async {
        pendingSyncQueue.removeAll { isCloudSyncDisabled(for: $0) }
        guard !pendingSyncQueue.isEmpty else { return }

        let batch = pendingSyncQueue
        pendingSyncQueue.removeAll()

        AppLog.shared.iCloudSync("Starting batch sync of \(batch.count) summaries", level: .debug)

        await updateSyncStatus(.syncing)
        await MainActor.run {
            self.pendingSyncCount = batch.count
        }

        for summary in batch {
            syncingSummaries.insert(summary.id)
        }
        defer {
            for summary in batch {
                syncingSummaries.remove(summary.id)
            }
        }

        do {
            let syncedCount = try await uploadLegacySummaryRecords(batch)
            for summary in batch {
                recentlySyncedSummaries[summary.id] = Date()
            }
            await updateSyncStatus(.completed)
            await MainActor.run {
                self.pendingSyncCount = 0
                self.lastSyncDate = Date()
                UserDefaults.standard.set(self.lastSyncDate, forKey: "lastSyncDate")
            }
            AppLog.shared.iCloudSync("Successfully synced batch: \(syncedCount) summaries")
        } catch {
            // The queue was drained before the upload; without this the whole batch
            // is gone and those summaries are never sent again.
            let stillQueuedIds = Set(pendingSyncQueue.map(\.id))
            pendingSyncQueue.insert(
                contentsOf: batch.filter { !stillQueuedIds.contains($0.id) },
                at: 0
            )
            await updateSyncStatus(.failed(error.localizedDescription))
            await MainActor.run {
                self.pendingSyncCount = self.pendingSyncQueue.count
            }
            AppLog.shared.iCloudSync(
                "Batch sync failed, returning \(batch.count) summaries to the queue: \(error.localizedDescription)",
                level: .error
            )
        }

        // Anything queued while this batch was in flight goes out on the next
        // debounce rather than after a fixed delay.
        if !pendingSyncQueue.isEmpty {
            scheduleBatchSync()
        }
    }

    /// Uploads legacy `CD_EnhancedSummary` records in batches, refusing to write
    /// anything a durable deletion has claimed.
    ///
    /// Returns how many summaries were written.
    @discardableResult
    private func uploadLegacySummaryRecords(_ summaries: [EnhancedSummaryData]) async throws -> Int {
        if !isInitialized {
            await initializeCloudKit()
        }
        guard networkStatus.canSync else {
            throw NSError(
                domain: "iCloudStorageManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Network unavailable"]
            )
        }
        guard !summaries.isEmpty else { return 0 }

        // A summary can already be queued when the user deletes it. The tombstones
        // are read once for the whole batch — this used to be one query per summary.
        let deletionTargets = (try? await fetchDeletionTargets()) ?? CloudDeletionTargets()
        let pendingRecordingIds = Set(pendingCloudDeletionMarkers.map(\.recordingId))
        let pendingSummaryIds = Set(pendingSummaryCloudRemovals.map(\.summaryId))
        let pendingTranscriptIds = Set(pendingTranscriptCloudRemovals.map(\.transcriptId))

        var summariesToSync: [EnhancedSummaryData] = []
        for summary in summaries {
            if pendingSummaryIds.contains(summary.id) || deletionTargets.summaries.contains(summary.id) {
                continue
            }
            if let recordingId = summary.recordingId,
               pendingRecordingIds.contains(recordingId) || deletionTargets.recordings.contains(recordingId) {
                continue
            }
            if let transcriptId = summary.transcriptId,
               pendingTranscriptIds.contains(transcriptId) || deletionTargets.transcripts.contains(transcriptId) {
                summariesToSync.append(summaryByClearingTranscript(summary))
            } else {
                summariesToSync.append(summary)
            }
        }
        guard !summariesToSync.isEmpty else { return 0 }

        let recordIDs = summariesToSync.map { CKRecord.ID(recordName: $0.id.uuidString) }
        let fetchOutcome = try await cloudExecutor.fetch(recordIDs)
        recordMetrics(fetch: fetchOutcome)
        // Only a record CloudKit says is absent may be created fresh. Reading a
        // failed or deferred fetch as "not there" builds a new record over the top
        // of the server's copy.
        try fetchOutcome.throwIfIncomplete()

        var recordsToSave: [CKRecord] = []
        for summary in summariesToSync {
            let recordID = CKRecord.ID(recordName: summary.id.uuidString)
            if let existing = fetchOutcome.records[recordID] {
                updateCloudKitRecord(existing, from: summary)
                recordsToSave.append(existing)
            } else {
                recordsToSave.append(try createCloudKitRecord(from: summary))
            }
        }

        do {
            try await saveBackupRecords(recordsToSave)
        } catch let error as CKError where error.code == .unknownItem || error.code == .invalidArguments {
            // The legacy record type has never been created in this environment.
            AppLog.shared.iCloudSync("Legacy summary schema missing, creating it and retrying", level: .error)
            await setupCloudKitSchema()
            try await saveBackupRecords(recordsToSave)
        }

        return recordsToSave.count
    }

    /// Single-summary path, kept for the callers that own exactly one summary.
    /// Ordinary collection processing goes through `uploadLegacySummaryRecords`.
    private func performIndividualSync(_ summary: EnhancedSummaryData) async throws {
        _ = try await uploadLegacySummaryRecords([summary])
        await MainActor.run {
            self.lastSyncDate = Date()
            UserDefaults.standard.set(self.lastSyncDate, forKey: "lastSyncDate")
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

        do {
            let syncedCount = try await uploadLegacySummaryRecords(syncableSummaries)
            await updateSyncStatus(.completed)
            AppLog.shared.iCloudSync("Successfully synced all \(syncedCount) summaries")
        } catch {
            await updateSyncStatus(.failed(error.localizedDescription))
            AppLog.shared.iCloudSync(
                "Batch sync failed: \(error.localizedDescription)",
                level: .error
            )
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

                let deletionTargets = try? await fetchDeletionTargets()
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
                        try await syncSleeper.sleep(seconds: ckError.suggestedRetryAfterSeconds ?? retryDelay)
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

        let deletionTargets = try? await fetchDeletionTargets()
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

        let deletionTargets = try? await fetchDeletionTargets()
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

            // CloudKit calls this on its own queue, so the block must be
            // `@Sendable` — a closure formed in this main-actor class otherwise
            // inherits its isolation and traps on the callback — and the
            // accumulator has to be synchronized rather than a captured `var`.
            let collectedCloudOnlyRecords = Mutex<[CKRecord]>([])
            // Phase 1 is finished, so this is a fixed set by now; the block reads a
            // snapshot of it rather than the still-mutable local.
            let alreadyCheckedUUIDs = checkedUUIDs

            zoneChangesOperation.recordWasChangedBlock = { @Sendable _, result in
                switch result {
                case .success(let record):
                    // Only process our summary records that we haven't already checked
                    if record.recordType == CloudKitSummaryRecord.recordType &&
                       !alreadyCheckedUUIDs.contains(record.recordID.recordName) {
                        collectedCloudOnlyRecords.withLock { $0.append(record) }
                    }
                case .failure(let error):
                    AppLog.shared.iCloudSync("Failed to fetch cloud-only record: \(error.localizedDescription)", level: .error)
                }
            }

            _ = try await withCheckedThrowingContinuation { continuation in
                zoneChangesOperation.fetchRecordZoneChangesResultBlock = { @Sendable result in
                    continuation.resume(with: result)
                }
                database.add(zoneChangesOperation)
            }

            // Convert the cloud-only records
            for record in collectedCloudOnlyRecords.withLock({ $0 }) {
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

        // `@Sendable` and a synchronized accumulator: CloudKit calls this back on
        // its own queue, where a main-actor-isolated closure traps.
        let collectedRecords = Mutex<[CKRecord]>([])

        zoneChangesOperation.recordWasChangedBlock = { @Sendable _, result in
            switch result {
            case .success(let record):
                if record.recordType == CloudKitSummaryRecord.recordType {
                    collectedRecords.withLock { $0.append(record) }
                }
            case .failure(let error):
                AppLog.shared.iCloudSync("Failed to fetch record with configuration: \(error.localizedDescription)", level: .error)
            }
        }

        _ = try await withCheckedThrowingContinuation { continuation in
            zoneChangesOperation.fetchRecordZoneChangesResultBlock = { @Sendable result in
                continuation.resume(with: result)
            }
            database.add(zoneChangesOperation)
        }

        // Convert records to summaries
        var summaries: [EnhancedSummaryData] = []
        for record in collectedRecords.withLock({ $0 }) {
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

        // `@Sendable` and a synchronized accumulator: CloudKit calls this back on
        // its own queue, where a main-actor-isolated closure traps.
        let collectedRecords = Mutex<[CKRecord]>([])

        zoneChangesOperation.recordWasChangedBlock = { @Sendable _, result in
            switch result {
            case .success(let record):
                if record.recordType == CloudKitSummaryRecord.recordType {
                    collectedRecords.withLock { $0.append(record) }
                }
            case .failure(let error):
                AppLog.shared.iCloudSync("Failed to fetch record: \(error.localizedDescription)", level: .error)
            }
        }

        _ = try await withCheckedThrowingContinuation { continuation in
            zoneChangesOperation.fetchRecordZoneChangesResultBlock = { @Sendable result in
                continuation.resume(with: result)
            }
            database.add(zoneChangesOperation)
        }

        // Convert records to summaries
        var summaries: [EnhancedSummaryData] = []
        for record in collectedRecords.withLock({ $0 }) {
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

        // `@Sendable` and a synchronized accumulator: CloudKit calls this back on
        // its own queue, where a main-actor-isolated closure traps.
        let collectedRecords = Mutex<[CKRecord]>([])

        zoneChangesOperation.recordWasChangedBlock = { @Sendable _, result in
            switch result {
            case .success(let record):
                if record.recordType == CloudKitSummaryRecord.recordType {
                    collectedRecords.withLock { $0.append(record) }
                }
            case .failure(let error):
                AppLog.shared.iCloudSync("Failed to fetch record in zone: \(error.localizedDescription)", level: .error)
            }
        }

        _ = try await withCheckedThrowingContinuation { continuation in
            zoneChangesOperation.fetchRecordZoneChangesResultBlock = { @Sendable result in
                continuation.resume(with: result)
            }
            database.add(zoneChangesOperation)
        }

        // Convert records to summaries
        var summaries: [EnhancedSummaryData] = []
        for record in collectedRecords.withLock({ $0 }) {
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

                // Resume sync when network becomes available. Anything CloudKit
                // deferred is eligible again as soon as its window has passed.
                if status.canSync, let self, self.isEnabled {
                    if self.hasPendingCloudWork {
                        NotificationCenter.default.post(
                            name: iCloudStorageManager.networkRestoredNotification,
                            object: nil
                        )
                    }
                    await self.performPeriodicSync()
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

        // Something local changed, so there is work whatever any throttle says.
        hasPendingLocalChanges = true

        // Debounce only: reset the timer on each call so a burst of edits becomes
        // one upload. The maintenance throttle deliberately does not extend this —
        // making a user's edit wait out a 15-minute window is what made a one-line
        // rename look like it had failed to sync.
        autoBackupTimer?.invalidate()
        autoBackupTimer = Timer.scheduledTimer(
            withTimeInterval: autoBackupDebounceInterval,
            repeats: false
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.performAutoBackup(appCoordinator: appCoordinator)
            }
        }
    }

    private func performAutoBackup(appCoordinator: AppDataCoordinator) async {
        guard isEnabled else { return }
        guard !isManualCloudTransferInProgress else { return }

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
            // Only a completed run clears the pending flag or advances the throttle;
            // a failure has to leave the work looking outstanding.
            hasPendingLocalChanges = false
            lastAutoBackupDate = Date()
            if !result.wasSkippedNoChanges {
                AppLog.shared.iCloudSync("Auto-backup complete: \(result.recordingsBackedUp) recordings, \(result.transcriptsBackedUp) transcripts, \(result.summariesBackedUp) summaries")
            }
        } catch {
            AppLog.shared.iCloudSync("Auto-backup failed (will retry on next data change): \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Routine trigger gate

    /// Set by any local create or edit, cleared only by a completed upload.
    private(set) var hasPendingLocalChanges = false

    private static let lastSuccessfulRoutineSyncKey = "iCloudLastSuccessfulRoutineSyncV1"
    /// How long a quiet device may go before an activation is worth a check.
    private static let routineSyncStaleInterval: TimeInterval = 900

    var lastSuccessfulRoutineSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastSuccessfulRoutineSyncKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastSuccessfulRoutineSyncKey) }
    }

    /// Durable work waiting to go out. Deletions count even when nothing else does.
    var hasPendingCloudWork: Bool {
        hasPendingLocalChanges ||
            pendingCloudDeletionCount > 0
    }

    /// Whether an automatic trigger has earned a run.
    ///
    /// A cold launch forces one; the activation notification that follows it a
    /// moment later finds that run in flight and joins it, so the pair produces one
    /// sync rather than two.
    func shouldStartRoutineSnapshot(force: Bool) -> Bool {
        guard isEnabled else { return false }
        if force { return true }
        // Never start work CloudKit has asked us to hold off on.
        if cloudExecutor.isDeferred { return false }
        if hasPendingCloudWork { return true }
        guard let lastSuccess = lastSuccessfulRoutineSyncDate else { return true }
        return Date().timeIntervalSince(lastSuccess) >= Self.routineSyncStaleInterval
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

    /// Uploads with a smaller batch size than usual. Used when the device asks for
    /// battery-friendly behaviour: fewer records per request, same number of passes.
    private func syncSummariesInBatches(batchSize: Int) async throws {
        AppLog.shared.iCloudSync("Syncing summaries in batches of \(batchSize)", level: .debug)

        let previousLimits = cloudExecutor.limits
        cloudExecutor.limits.metadataBatchSize = max(1, batchSize)
        defer { cloudExecutor.limits = previousLimits }

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

        try await validateiCloudAccountAvailability()

        // The whole wipe runs as one coordinated operation. Flagging a manual
        // transfer only stops *new* automatic work from starting: a snapshot
        // already in flight would carry on and could save its records back after
        // the enumeration had passed them, leaving content behind while the erase
        // reported success.
        var result = CloudEraseResult()
        try await operationCoordinator.submit(
            intent: .erase,
            allowJoiningRunningOperation: false,
            coalescesWithEquivalentRequests: false
        ) { [weak self] in
            guard let self else { return }
            result = try await self.performErase()
        }
        return result
    }

    private func performErase() async throws -> CloudEraseResult {
        // Hold off automatic sync and auto-backup for the whole wipe, otherwise a
        // background upload can repopulate the container while it is being erased.
        isManualCloudTransferInProgress = true
        defer { isManualCloudTransferInProgress = false }

        await updateSyncStatus(.syncing)
        AppLog.shared.iCloudSync("Starting full iCloud erase of this app's private database")

        var result = CloudEraseResult()

        do {
            // Custom zones can be dropped wholesale, which removes their records too.
            let customZoneIDs = try await cloudTransport.allRecordZoneIDs()
                .filter { $0 != CKRecordZone.default().zoneID }

            if !customZoneIDs.isEmpty {
                let deletedZoneIDs = try await cloudTransport.deleteRecordZones(withIDs: customZoneIDs)
                result.zonesDeleted += deletedZoneIDs.count
                for zoneID in customZoneIDs where !deletedZoneIDs.contains(zoneID) {
                    result.failures.append("Zone \(zoneID.zoneName): could not be deleted")
                }
            }

            // The default zone itself cannot be deleted, so remove its records.
            var recordIDs = try await defaultZoneRecordIDs()
            recordIDs.append(contentsOf: await queriedRecordIDsForKnownTypes())

            let deletion = try await deleteCloudRecordsInBatches(recordIDs)
            result.recordsDeleted = deletion.deleted
            result.failures.append(contentsOf: deletion.failures)

            // Forget the local markers describing what is (or was) in iCloud so the next
            // backup uploads a complete fresh copy instead of a delta. Pending deletion
            // queues are dropped too: the records they targeted no longer exist.
            //
            // Only once nothing failed. Records that survived an incomplete erase are
            // still out there, and a normal sync between here and the user's retry
            // would reconcile them against local data — while the UI has just said the
            // erase changed nothing locally.
            if result.failures.isEmpty {
                resetLocalCloudSyncBookkeeping()
            } else {
                AppLog.shared.iCloudSync(
                    "Kept local sync bookkeeping: \(result.failures.count) record(s) survived the erase",
                    level: .error
                )
            }

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

    /// Collects the IDs of every record in the private default zone. No field
    /// values are requested, so CloudKit never downloads the audio assets attached
    /// to backup records just to enumerate them.
    private func defaultZoneRecordIDs() async throws -> [CKRecord.ID] {
        do {
            let recordIDs = try await cloudTransport.recordIDs(inZoneWith: CKRecordZone.default().zoneID)
            AppLog.shared.iCloudSync("Found \(recordIDs.count) records in the default zone to erase", level: .debug)
            return recordIDs
        } catch let error as CKError where error.isUnsupportedZoneChangeRequest {
            // The default zone cannot be enumerated by change token. The erase
            // still has its query sweep across every known record type, so this
            // must not abort the wipe.
            AppLog.shared.iCloudSync(
                "The default zone does not support change enumeration; " +
                "erasing from the per-type query sweep instead",
                level: .debug
            )
            return []
        }
    }

    /// Backstop for the change feed: queries each record type the app knows about.
    /// A type that was never created has no schema to query, which is not a failure
    /// for an erase, so query errors are logged and skipped.
    private func queriedRecordIDsForKnownTypes() async -> [CKRecord.ID] {
        var recordIDs: [CKRecord.ID] = []

        for recordType in Self.allKnownCloudRecordTypes {
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
            do {
                var page = try await cloudTransport.records(
                    matching: query,
                    inZoneWith: nil,
                    desiredKeys: [],
                    resultsLimit: CKQueryOperation.maximumResults
                )
                while true {
                    recordIDs.append(contentsOf: page.matchResults.map { $0.0 })
                    guard let cursor = page.queryCursor else { break }
                    page = try await cloudTransport.records(
                        continuingMatchFrom: cursor,
                        desiredKeys: [],
                        resultsLimit: CKQueryOperation.maximumResults
                    )
                }
            } catch {
                AppLog.shared.iCloudSync("Erase sweep skipped \(recordType): \(error.localizedDescription)", level: .debug)
            }
        }

        return recordIDs
    }

    /// Deletes through the shared batch executor, which splits an oversized batch,
    /// retries only the IDs that failed, and treats an already-absent record as
    /// success.
    private func deleteCloudRecordsInBatches(
        _ recordIDs: [CKRecord.ID]
    ) async throws -> (deleted: Int, failures: [String]) {
        guard !recordIDs.isEmpty else { return (0, []) }

        let outcome = try await cloudExecutor.delete(recordIDs)
        recordMetrics(modify: outcome)

        var failures = outcome.failures.map { recordID, error in
            "\(recordID.recordName): \(error.localizedDescription)"
        }
        failures.append(contentsOf: outcome.deferred.map { recordID in
            "\(recordID.recordName): deferred by CloudKit"
        })

        return (outcome.deleted.count, failures.sorted())
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
    /// True when this request's work was covered by a run already in flight. The
    /// zeroed counts below are not evidence that there was nothing to do.
    var wasCoalescedIntoRunningSync = false
    /// Set when CloudKit asked for a backoff longer than a foreground wait.
    var wasDeferredUntil: Date?
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

    // SelectedAIEngine is deliberately absent: rejecting it whenever the backup
    // crossed platforms also dropped engines valid on both. resolveRestoredEngineSelection
    // judges that key per engine instead.
    private static let platformSpecificSettingsKeys: Set<String> = ollamaSettingsKeys
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

    /// Ids other devices have tombstoned. Shared by every leg of one run.
    struct CloudDeletionTargets {
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
    static let contentIndexConfiguration = CloudContentIndexCoordinator.Configuration(
        recordType: backupContentIndexRecordType,
        recordName: backupContentIndexRecordName,
        recordingNamesField: fieldIndexRecordingRecordNames,
        transcriptNamesField: fieldIndexTranscriptRecordNames,
        summaryNamesField: fieldIndexSummaryRecordNames,
        schemaVersionField: fieldSettingsSchemaVersion,
        manifestSchemaVersionField: fieldManifestSchemaVersion,
        updatedAtField: fieldSettingsUpdatedAt,
        deviceIdentifierField: fieldDeviceIdentifier,
        backupSchemaVersion: backupSchemaVersion,
        manifestSchemaVersion: activeManifestSchemaVersion
    )

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

    /// One cloud read per run, shared by every leg that needs to know what the
    /// cloud currently holds.
    struct BackupCloudSnapshot {
        var recordings: [CKRecord.ID: CKRecord] = [:]
        var transcripts: [CKRecord.ID: CKRecord] = [:]
        var summaries: [CKRecord.ID: CKRecord] = [:]
        var manifest = CloudActiveManifest()
        /// False when the manifest was missing or written by an older schema. The
        /// snapshot is then only what this device already knew to ask for, which
        /// says nothing about what else is in the cloud.
        var manifestWasTrusted = false

        func record(for recordID: CKRecord.ID) -> CKRecord? {
            recordings[recordID] ?? transcripts[recordID] ?? summaries[recordID]
        }

        /// Folds this run's own writes in, so the leg that reads the snapshot next
        /// sees what the cloud holds now rather than what it held before the save.
        mutating func apply(saved: [CKRecord], deleted: [CKRecord.ID]) {
            for record in saved {
                switch record.recordType {
                case iCloudStorageManager.backupRecordingRecordType:
                    recordings[record.recordID] = record
                case iCloudStorageManager.backupTranscriptRecordType:
                    transcripts[record.recordID] = record
                case iCloudStorageManager.backupSummaryRecordType:
                    summaries[record.recordID] = record
                default:
                    continue
                }
            }
            for recordID in deleted {
                recordings.removeValue(forKey: recordID)
                transcripts.removeValue(forKey: recordID)
                summaries.removeValue(forKey: recordID)
            }
        }
    }

    /// Everything a content-changing operation must know before it writes: what
    /// other devices have deleted, and what the manifest says is live. Computed
    /// once per run and handed to both the backup and restore legs, because doing
    /// it per leg meant flushing, applying, and refetching the same tombstones
    /// three and four times in a single reconcile.
    struct CloudSyncPreflight {
        var deletionTargets = CloudDeletionTargets()
        var markerApplication = DeletionMarkerApplication()
    }

    /// What the backup leg produced, including the cloud snapshot it read. The
    /// restore leg reuses that snapshot rather than reading the same records again.
    struct CloudBackupLegOutcome {
        var result = CloudBackupResult()
        var snapshot: BackupCloudSnapshot?
    }

    /// Recording fields worth reading during metadata sync. `audioAsset` is
    /// deliberately absent: fetching it downloads every backed-up audio file, and
    /// metadata sync has to succeed whether or not audio does. A recording that
    /// turns out to need saving is refetched in full first, so a partial record is
    /// never written back over a complete one.
    static let recordingMetadataKeys: [CKRecord.FieldKey] = [
        fieldRecordingName,
        fieldRecordingDate,
        fieldRecordingURL,
        fieldCreatedAt,
        fieldLastModified,
        fieldFileSize,
        fieldDuration,
        fieldAudioQuality,
        fieldTranscriptionStatus,
        fieldSummaryStatus,
        fieldTranscriptId,
        fieldSummaryId,
        fieldLocationLatitude,
        fieldLocationLongitude,
        fieldLocationAccuracy,
        fieldLocationTimestamp,
        fieldLocationAddress,
        fieldDeviceIdentifier,
        fieldAudioFileName,
        fieldAudioByteCount,
        fieldAudioSignature,
        fieldSyncLifecycle,
        fieldSyncSchemaVersion,
        fieldSyncUpdatedAt
    ]

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
        var result = CloudBackupResult()
        try await operationCoordinator.submit(
            intent: .seedFromThisDevice,
            allowJoiningRunningOperation: false,
            // This caller reads its result out of the closure below.
            coalescesWithEquivalentRequests: false
        ) { [weak self] in
            guard let self else { return }
            result = try await self.performManualBackup(appCoordinator: appCoordinator, options: options)
        }
        return result
    }

    private func performManualBackup(
        appCoordinator: AppDataCoordinator,
        options: CloudBackupOptions
    ) async throws -> CloudBackupResult {
        isManualCloudTransferInProgress = true
        defer { isManualCloudTransferInProgress = false }

        let recorder = beginRun(reason: .manualBackup, intent: .seedFromThisDevice)
        do {
            try await validateiCloudAccountAvailability()
            await MainActor.run {
                self.syncStatus = .syncing
                self.lastError = nil
            }

            let preflight = try await performDeletionPreflight(
                appCoordinator: appCoordinator,
                recorder: recorder
            )
            let result = try await performBackup(
                appCoordinator: appCoordinator,
                options: options,
                preflight: preflight,
                recorder: recorder
            ).result

            await MainActor.run {
                self.lastSyncDate = Date()
                UserDefaults.standard.set(self.lastSyncDate, forKey: "lastSyncDate")
                self.syncStatus = .completed
                self.lastError = nil
            }
            recorder?.finish(result.wasSkippedNoChanges ? .skippedNoChanges : .succeeded)
            return result
        } catch {
            recorder?.finish(.failed)
            await MainActor.run {
                self.syncStatus = .failed(error.localizedDescription)
                self.lastError = error.localizedDescription
            }
            throw error
        }
    }

    /// The backup leg proper.
    ///
    /// Shape of a run: read the manifest and one snapshot of the records it names,
    /// decide every winner in memory, then issue one batched save and one batched
    /// delete. Nothing here reads a record back to count it, and nothing walks a
    /// collection one CloudKit request at a time.
    func performBackup(
        appCoordinator: AppDataCoordinator,
        options: CloudBackupOptions,
        preflight: CloudSyncPreflight,
        recorder: CloudSyncRunRecorder?
    ) async throws -> CloudBackupLegOutcome {
        var result = CloudBackupResult()
        let deletionTargets = preflight.deletionTargets

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
            let hasCloudContentBackup = try await cloudHasAnyContentBackupRecord()
            if hasCloudContentBackup {
                result.wasSkippedNoChanges = true
                return CloudBackupLegOutcome(result: result, snapshot: nil)
            } else {
                AppLog.shared.iCloudSync(
                    "Local backup signature matched but cloud content backup is empty. " +
                    "Forcing full upload to seed this CloudKit environment."
                )
            }
        }

        // MARK: One snapshot

        recorder?.begin(.fetchCloudSnapshot)
        let localRecordingRecordNames = Set(recordings.compactMap { recording in
            recording.id.map { makeBackupRecordName(prefix: Self.backupRecordingRecordPrefix, id: $0) }
        })
        let localTranscriptRecordNames = Set(transcripts.compactMap { transcript in
            transcript.id.map { makeBackupRecordName(prefix: Self.backupTranscriptRecordPrefix, id: $0) }
        })
        let localSummaryRecordNames = Set(summaries.compactMap { summary in
            summary.id.map { makeBackupRecordName(prefix: Self.backupSummaryRecordPrefix, id: $0) }
        })
        // Recordings the user marked "Keep on This Device" still need their cloud
        // copies found so they can be removed.
        let excludedRecordingRecordNames = Set(excludedRecordingIds.map {
            makeBackupRecordName(prefix: Self.backupRecordingRecordPrefix, id: $0)
        })

        let manifestState = try await contentIndexCoordinator.fetchManifestState()
        let snapshot = try await fetchBackupCloudSnapshot(
            manifest: manifestState.manifest,
            manifestWasTrusted: manifestState.isTrusted,
            recordingRecordNames: localRecordingRecordNames.union(excludedRecordingRecordNames),
            transcriptRecordNames: localTranscriptRecordNames,
            summaryRecordNames: localSummaryRecordNames
        )

        // MARK: Resolve winners in memory

        recorder?.begin(.resolveWinners)

        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        var manifestDelta = ManifestDelta()
        var recordingsNeedingUpload: [(recording: RecordingEntry, recordID: CKRecord.ID)] = []
        var recordingsNeedingAudioOnly: [(recording: RecordingEntry, recordID: CKRecord.ID)] = []

        // Local-only recordings: withdraw whatever the cloud still holds for them.
        for recordID in snapshot.recordings.keys {
            guard let recordingId = decodeBackupRecordUUID(
                recordName: recordID.recordName,
                prefix: Self.backupRecordingRecordPrefix
            ), excludedRecordingIds.contains(recordingId) else { continue }
            recordIDsToDelete.append(recordID)
            manifestDelta.removeRecordings.insert(recordID.recordName)
        }
        for (recordID, record) in snapshot.transcripts
        where backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds) {
            recordIDsToDelete.append(recordID)
            manifestDelta.removeTranscripts.insert(recordID.recordName)
        }
        for (recordID, record) in snapshot.summaries
        where backupRecordBelongsToExcludedRecording(record, excludedRecordingIds: excludedRecordingIds) {
            recordIDsToDelete.append(recordID)
            manifestDelta.removeSummaries.insert(recordID.recordName)
        }

        for recording in recordings {
            guard let recordingId = recording.id else { continue }
            let recordID = CKRecord.ID(
                recordName: makeBackupRecordName(prefix: Self.backupRecordingRecordPrefix, id: recordingId)
            )
            let existingRecord = snapshot.recordings[recordID]

            if let existingRecord,
               !Self.shouldUploadLocalVersion(
                   localTimestamp: localRecordingContentTimestamp(recording),
                   cloudTimestamp: backupRecordContentTimestamp(
                       existingRecord,
                       keys: Self.recordingContentTimestampKeys
                   )
               ) {
                // Another device holds a newer edit. Leave its fields alone and let
                // the restore leg bring them down, but still upload audio it has
                // never seen.
                if options.includeAudioFiles, existingRecord[Self.fieldAudioSignature] == nil {
                    recordingsNeedingAudioOnly.append((recording, recordID))
                }
                if isActiveBackupRecord(existingRecord) {
                    manifestDelta.addRecordings.insert(recordID.recordName)
                }
                AppLog.shared.iCloudSync(
                    "Kept newer iCloud version of recording \(recordingId.uuidString)",
                    level: .debug
                )
                result.recordingsBackedUp += 1
                continue
            }

            var changed = existingRecord == nil
            let probe = existingRecord
                ?? CKRecord(recordType: Self.backupRecordingRecordType, recordID: recordID)
            applyRecordingFields(recording, to: probe, changed: &changed)
            if changed {
                recordingsNeedingUpload.append((recording, recordID))
            } else if options.includeAudioFiles, existingRecord?[Self.fieldAudioSignature] == nil {
                recordingsNeedingAudioOnly.append((recording, recordID))
            }
            manifestDelta.addRecordings.insert(recordID.recordName)
            result.recordingsBackedUp += 1
        }

        for transcript in transcripts {
            guard let transcriptId = transcript.id else { continue }
            let recordID = CKRecord.ID(
                recordName: makeBackupRecordName(prefix: Self.backupTranscriptRecordPrefix, id: transcriptId)
            )
            let existingRecord = snapshot.transcripts[recordID]

            if let existingRecord,
               !Self.shouldUploadLocalVersion(
                   localTimestamp: localTranscriptContentTimestamp(transcript),
                   cloudTimestamp: backupRecordContentTimestamp(
                       existingRecord,
                       keys: Self.transcriptContentTimestampKeys
                   )
               ) {
                // Another device holds a newer transcript for this id; the restore
                // leg brings it down rather than this device overwriting it.
                if isActiveBackupRecord(existingRecord) {
                    manifestDelta.addTranscripts.insert(recordID.recordName)
                }
                AppLog.shared.iCloudSync(
                    "Kept newer iCloud version of transcript \(transcriptId.uuidString)",
                    level: .debug
                )
                result.transcriptsBackedUp += 1
                continue
            }

            var changed = existingRecord == nil
            let record = existingRecord
                ?? CKRecord(recordType: Self.backupTranscriptRecordType, recordID: recordID)
            applyTranscriptFields(transcript, to: record, changed: &changed)
            if changed {
                recordsToSave.append(record)
            }
            manifestDelta.addTranscripts.insert(recordID.recordName)
            result.transcriptsBackedUp += 1
        }

        for summary in summaries {
            guard let summaryId = summary.id else { continue }
            let recordID = CKRecord.ID(
                recordName: makeBackupRecordName(prefix: Self.backupSummaryRecordPrefix, id: summaryId)
            )
            let existingRecord = snapshot.summaries[recordID]

            if let existingRecord,
               !Self.shouldUploadLocalVersion(
                   localTimestamp: localSummaryContentTimestamp(summary),
                   cloudTimestamp: backupRecordContentTimestamp(
                       existingRecord,
                       keys: Self.summaryContentTimestampKeys
                   )
               ) {
                // Another device regenerated this summary more recently.
                if isActiveBackupRecord(existingRecord) {
                    manifestDelta.addSummaries.insert(recordID.recordName)
                }
                AppLog.shared.iCloudSync(
                    "Kept newer iCloud version of summary \(summaryId.uuidString)",
                    level: .debug
                )
                result.summariesBackedUp += 1
                continue
            }

            var changed = existingRecord == nil
            let record = existingRecord
                ?? CKRecord(recordType: Self.backupSummaryRecordType, recordID: recordID)
            applySummaryFields(summary, to: record, changed: &changed)
            if changed {
                recordsToSave.append(record)
            }
            manifestDelta.addSummaries.insert(recordID.recordName)
            result.summariesBackedUp += 1
        }

        // MARK: Write

        recorder?.begin(.writeContent)

        // Only recordings that are actually being written are refetched in full,
        // and only then does their audio asset come back down with them.
        let staging = TemporaryDirectoryAssetStaging(
            runIdentifier: recorder?.runIdentifier ?? UUID().uuidString
        )
        defer { staging.cleanUp() }

        // Only records the cloud already holds need the full refetch; a recording
        // being uploaded for the first time has nothing to preserve.
        let recordIDsNeedingFullFetch = (recordingsNeedingUpload.map(\.recordID) +
            recordingsNeedingAudioOnly.map(\.recordID))
            .filter { snapshot.recordings[$0] != nil }
        let recordingRecordsToWrite = try await fullRecordingRecords(for: recordIDsNeedingFullFetch)

        // Records another device won between the snapshot and the refetch. They are
        // what the cloud holds now, so the restore leg gets them rather than the
        // local copy this leg set out to upload.
        var remoteWinnersFoundWhileWriting: [CKRecord] = []

        for entry in recordingsNeedingUpload {
            let record = recordingRecordsToWrite[entry.recordID]
                ?? CKRecord(recordType: Self.backupRecordingRecordType, recordID: entry.recordID)

            // The refetch reads the record again, and with it a fresh change tag.
            // If another device wrote in the meantime, applying our fields now would
            // save cleanly over the newer edit — no `serverRecordChanged` to catch
            // it, because the tag we hold is the one that edit produced. Arbitrate
            // once more against what actually came back.
            if let refetched = recordingRecordsToWrite[entry.recordID],
               !Self.shouldUploadLocalVersion(
                   localTimestamp: localRecordingContentTimestamp(entry.recording),
                   cloudTimestamp: backupRecordContentTimestamp(
                       refetched,
                       keys: Self.recordingContentTimestampKeys
                   )
               ) {
                AppLog.shared.iCloudSync(
                    "Another device wrote this recording while the run was in flight; keeping its version",
                    level: .debug
                )
                remoteWinnersFoundWhileWriting.append(refetched)
                continue
            }

            var changed = recordingRecordsToWrite[entry.recordID] == nil
            applyRecordingFields(entry.recording, to: record, changed: &changed)
            if options.includeAudioFiles {
                if attachAudioBackupIfNeeded(
                    recording: entry.recording,
                    to: record,
                    appCoordinator: appCoordinator,
                    staging: staging,
                    includeAudioFiles: options.includeAudioFiles,
                    recorder: recorder,
                    result: &result,
                    changed: &changed
                ) {
                    result.audioFilesBackedUp += 1
                }
            }
            recordsToSave.append(record)
        }

        for entry in recordingsNeedingAudioOnly {
            guard let record = recordingRecordsToWrite[entry.recordID] else { continue }
            var changed = false
            if attachAudioBackupIfNeeded(
                recording: entry.recording,
                to: record,
                appCoordinator: appCoordinator,
                staging: staging,
                includeAudioFiles: options.includeAudioFiles,
                recorder: recorder,
                result: &result,
                changed: &changed
            ) {
                result.audioFilesBackedUp += 1
            }
            if changed {
                recordsToSave.append(record)
            }
        }

        // Keep only the newest transcript and summary per recording in the cloud.
        // The snapshot already holds every candidate, so this costs no extra reads.
        let removedSoFar = Set(recordIDsToDelete)
        let transcriptCandidates = mergedRecords(
            snapshot.transcripts,
            with: recordsToSave,
            ofType: Self.backupTranscriptRecordType
        ).filter { !removedSoFar.contains($0.recordID) }
        let transcriptResolution = resolveLatestRecordsPerRecording(
            transcriptCandidates,
            recordingIdField: Self.fieldRecordingId,
            timestampKeys: [Self.fieldLastModified, Self.fieldCreatedAt]
        )
        if !transcriptResolution.loserRecordIDs.isEmpty {
            recordIDsToDelete.append(contentsOf: transcriptResolution.loserRecordIDs)
            for recordID in transcriptResolution.loserRecordIDs {
                manifestDelta.removeTranscripts.insert(recordID.recordName)
            }
            AppLog.shared.iCloudSync(
                "Removed \(transcriptResolution.loserRecordIDs.count) older transcript backup records",
                level: .debug
            )
        }

        let summaryCandidates = mergedRecords(
            snapshot.summaries,
            with: recordsToSave,
            ofType: Self.backupSummaryRecordType
        ).filter { !removedSoFar.contains($0.recordID) }
        let summaryResolution = resolveLatestRecordsPerRecording(
            summaryCandidates,
            recordingIdField: Self.fieldRecordingId,
            timestampKeys: [Self.fieldLastModified, Self.fieldGeneratedAt, Self.fieldCreatedAt]
        )
        if !summaryResolution.loserRecordIDs.isEmpty {
            recordIDsToDelete.append(contentsOf: summaryResolution.loserRecordIDs)
            for recordID in summaryResolution.loserRecordIDs {
                manifestDelta.removeSummaries.insert(recordID.recordName)
            }
            AppLog.shared.iCloudSync(
                "Removed \(summaryResolution.loserRecordIDs.count) older summary backup records",
                level: .debug
            )
        }

        let losingRecordIDs = Set(recordIDsToDelete)
        recordsToSave.removeAll { losingRecordIDs.contains($0.recordID) }

        let settledRecords = try await saveBackupRecords(recordsToSave)
        try await deleteBackupRecords(recordIDsToDelete)

        if options.includeSettings {
            let settingsResult = try await backupSettingsToiCloud(
                includeSensitiveSettings: options.includeSensitiveSettings
            )
            result.settingsBackedUp = settingsResult.backedUp
            result.includedSensitiveSettings = settingsResult.includedSensitiveSettings
        }

        // MARK: Commit the manifest

        recorder?.begin(.commitManifest)
        // Data operations have all succeeded by here: the manifest never claims a
        // record that failed to upload, and never keeps one that was deleted.
        try await applyManifestDelta(manifestDelta)
        recorder?.endPhase()

        let cloudManifest = manifestDelta.applied(to: snapshot.manifest)
        let processedSummary = "processed [recordings: \(result.recordingsBackedUp), " +
            "transcripts: \(result.transcriptsBackedUp), summaries: \(result.summariesBackedUp)]"
        let writeSummary = "saved [records: \(recordsToSave.count)], deleted [records: \(recordIDsToDelete.count)]"
        let cloudSummary = "cloud now [recordings: \(cloudManifest.recordings.count), " +
            "transcripts: \(cloudManifest.transcripts.count), summaries: \(cloudManifest.summaries.count)]"
        AppLog.shared.iCloudSync(
            "Backup write summary - \(processedSummary), \(writeSummary), \(cloudSummary)",
            level: .debug
        )

        // Only a complete run may advance the signature; a partial failure threw
        // long before this line.
        UserDefaults.standard.set(currentBackupStateSignature, forKey: Self.backupStateSignatureKey)

        // Hand the restore leg what this leg already knows the cloud holds — which
        // is the settled records, not what we set out to write: where another
        // device won a conflict, its copy is the one the restore leg must apply.
        var updatedSnapshot = snapshot
        updatedSnapshot.manifest = cloudManifest
        updatedSnapshot.apply(
            saved: settledRecords + remoteWinnersFoundWhileWriting,
            deleted: recordIDsToDelete
        )
        return CloudBackupLegOutcome(result: result, snapshot: updatedSnapshot)
    }

    /// Reads the manifest's records plus the deterministic ids of everything held
    /// locally. Two batched requests cover the whole dataset: one for recordings
    /// (without their audio assets) and one for transcripts and summaries.
    private func fetchBackupCloudSnapshot(
        manifest: CloudActiveManifest,
        manifestWasTrusted: Bool,
        recordingRecordNames: Set<String>,
        transcriptRecordNames: Set<String>,
        summaryRecordNames: Set<String>,
        includeAudioAssets: Bool = false
    ) async throws -> BackupCloudSnapshot {
        var snapshot = BackupCloudSnapshot()
        snapshot.manifest = manifest
        snapshot.manifestWasTrusted = manifestWasTrusted

        let recordingIDs = manifest.recordings.union(recordingRecordNames)
            .sorted()
            .map { CKRecord.ID(recordName: $0) }
        let contentIDs = (manifest.transcripts.union(transcriptRecordNames).sorted() +
            manifest.summaries.union(summaryRecordNames).sorted())
            .map { CKRecord.ID(recordName: $0) }

        if !recordingIDs.isEmpty {
            let outcome = try await cloudExecutor.fetch(
                recordingIDs,
                desiredKeys: includeAudioAssets ? nil : Self.recordingMetadataKeys
            )
            recordMetrics(fetch: outcome)
            try outcome.throwIfIncomplete()
            for (recordID, record) in outcome.records
            where record.recordType == Self.backupRecordingRecordType {
                snapshot.recordings[recordID] = record
            }
        }

        if !contentIDs.isEmpty {
            let outcome = try await cloudExecutor.fetch(contentIDs)
            recordMetrics(fetch: outcome)
            try outcome.throwIfIncomplete()
            for (recordID, record) in outcome.records {
                switch record.recordType {
                case Self.backupTranscriptRecordType:
                    snapshot.transcripts[recordID] = record
                case Self.backupSummaryRecordType:
                    snapshot.summaries[recordID] = record
                default:
                    continue
                }
            }
        }

        return snapshot
    }

    /// Refetches the handful of recording records that are about to be written,
    /// this time with every field including the audio asset, so an upload can never
    /// write a partially fetched record back over a complete one.
    private func fullRecordingRecords(
        for recordIDs: [CKRecord.ID]
    ) async throws -> [CKRecord.ID: CKRecord] {
        guard !recordIDs.isEmpty else { return [:] }
        let outcome = try await cloudExecutor.fetch(recordIDs)
        recordMetrics(fetch: outcome)
        try outcome.throwIfIncomplete()
        return outcome.records.filter { $0.value.recordType == Self.backupRecordingRecordType }
    }

    /// Combines two record lists by id, keeping the preferred copy where both hold
    /// the same record.
    private static func mergedByRecordID(preferring preferred: [CKRecord], over others: [CKRecord]) -> [CKRecord] {
        var merged: [CKRecord.ID: CKRecord] = [:]
        for record in others {
            merged[record.recordID] = record
        }
        for record in preferred {
            merged[record.recordID] = record
        }
        return Array(merged.values)
    }

    private func mergedRecords(
        _ snapshotRecords: [CKRecord.ID: CKRecord],
        with pendingSaves: [CKRecord],
        ofType recordType: String
    ) -> [CKRecord] {
        var merged = snapshotRecords
        for record in pendingSaves where record.recordType == recordType {
            merged[record.recordID] = record
        }
        return Array(merged.values)
    }

    // MARK: - Record field mapping

    private func applyRecordingFields(
        _ recording: RecordingEntry,
        to record: CKRecord,
        changed: inout Bool
    ) {
        let stableLastModified = recording.lastModified ?? recording.createdAt ?? recording.recordingDate

        updateStringField(Self.fieldRecordingName, value: recording.recordingName, on: record, changed: &changed)
        updateDateField(Self.fieldRecordingDate, value: recording.recordingDate, on: record, changed: &changed)
        updateStringField(Self.fieldRecordingURL, value: recording.recordingURL, on: record, changed: &changed)
        updateDateField(Self.fieldCreatedAt, value: recording.createdAt, on: record, changed: &changed)
        updateDateField(Self.fieldLastModified, value: stableLastModified, on: record, changed: &changed)
        updateInt64Field(Self.fieldFileSize, value: recording.fileSize, on: record, changed: &changed)
        updateDoubleField(Self.fieldDuration, value: recording.duration, on: record, changed: &changed)
        updateStringField(Self.fieldAudioQuality, value: recording.audioQuality, on: record, changed: &changed)
        updateStringField(Self.fieldTranscriptionStatus, value: recording.transcriptionStatus, on: record, changed: &changed)
        updateStringField(Self.fieldSummaryStatus, value: recording.summaryStatus, on: record, changed: &changed)
        updateStringField(Self.fieldTranscriptId, value: recording.transcriptId?.uuidString, on: record, changed: &changed)
        updateStringField(Self.fieldSummaryId, value: recording.summaryId?.uuidString, on: record, changed: &changed)
        updateDoubleField(Self.fieldLocationLatitude, value: recording.locationLatitude, on: record, changed: &changed)
        updateDoubleField(Self.fieldLocationLongitude, value: recording.locationLongitude, on: record, changed: &changed)
        updateDoubleField(Self.fieldLocationAccuracy, value: recording.locationAccuracy, on: record, changed: &changed)
        updateDateField(Self.fieldLocationTimestamp, value: recording.locationTimestamp, on: record, changed: &changed)
        updateStringField(Self.fieldLocationAddress, value: recording.locationAddress, on: record, changed: &changed)
        markBackupRecordActive(record, changed: &changed)
    }

    private func applyTranscriptFields(
        _ transcript: TranscriptEntry,
        to record: CKRecord,
        changed: inout Bool
    ) {
        let stableLastModified = transcript.lastModified ?? transcript.createdAt ?? Date()

        updateStringField(Self.fieldRecordingId, value: transcript.recordingId?.uuidString, on: record, changed: &changed)
        updateStringField(Self.fieldEngine, value: transcript.engine, on: record, changed: &changed)
        updateDateField(Self.fieldCreatedAt, value: transcript.createdAt, on: record, changed: &changed)
        updateDateField(Self.fieldLastModified, value: stableLastModified, on: record, changed: &changed)
        updateDoubleField(Self.fieldProcessingTime, value: transcript.processingTime, on: record, changed: &changed)
        updateDoubleField(Self.fieldConfidence, value: transcript.confidence, on: record, changed: &changed)
        updateStringField(Self.fieldSegments, value: transcript.segments, on: record, changed: &changed)
        updateStringField(Self.fieldSpeakerMappings, value: transcript.speakerMappings, on: record, changed: &changed)
        markBackupRecordActive(record, changed: &changed)
    }

    private func applySummaryFields(
        _ summary: SummaryEntry,
        to record: CKRecord,
        changed: inout Bool
    ) {
        let stableGeneratedAt = summary.generatedAt ?? summary.recording?.recordingDate ?? Date()

        updateStringField(Self.fieldRecordingId, value: summary.recordingId?.uuidString, on: record, changed: &changed)
        updateStringField(Self.fieldTranscriptId, value: summary.transcriptId?.uuidString, on: record, changed: &changed)
        updateStringField(Self.fieldSummaryText, value: summary.summary, on: record, changed: &changed)
        updateStringField(Self.fieldTasks, value: summary.tasks, on: record, changed: &changed)
        updateStringField(Self.fieldReminders, value: summary.reminders, on: record, changed: &changed)
        updateStringField(Self.fieldTitles, value: summary.titles, on: record, changed: &changed)
        updateStringField(Self.fieldContentType, value: summary.contentType, on: record, changed: &changed)
        updateStringField(Self.fieldAIMethod, value: summary.aiMethod, on: record, changed: &changed)
        updateDateField(Self.fieldGeneratedAt, value: stableGeneratedAt, on: record, changed: &changed)
        updateIntField(Self.fieldVersion, value: Int(summary.version), on: record, changed: &changed)
        updateIntField(Self.fieldWordCount, value: Int(summary.wordCount), on: record, changed: &changed)
        updateIntField(Self.fieldOriginalLength, value: Int(summary.originalLength), on: record, changed: &changed)
        updateDoubleField(Self.fieldCompressionRatio, value: summary.compressionRatio, on: record, changed: &changed)
        updateDoubleField(Self.fieldConfidence, value: summary.confidence, on: record, changed: &changed)
        updateDoubleField(Self.fieldProcessingTime, value: summary.processingTime, on: record, changed: &changed)
        updateDateField(Self.fieldLastModified, value: stableGeneratedAt, on: record, changed: &changed)
        updateStringField(Self.fieldRecordingName, value: summary.recording?.recordingName, on: record, changed: &changed)
        updateDateField(Self.fieldRecordingDate, value: summary.recording?.recordingDate, on: record, changed: &changed)
        markBackupRecordActive(record, changed: &changed)
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
            try await validateiCloudAccountAvailability()
            // A review scan queries the zone, so it queues behind anything already
            // running rather than competing with it for the same records.
            var items: [CloudReviewItem] = []
            // The scan's findings come back through `items`, so this request must
            // keep its own closure rather than riding on another scan's.
            try await operationCoordinator.submit(
                intent: .reviewScan,
                coalescesWithEquivalentRequests: false
            ) { [weak self] in
                guard let self else { return }
                items = try await self.scanCloudOnlyReviewItems(appCoordinator: appCoordinator)
            }
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
        appCoordinator: AppDataCoordinator
    ) async throws -> Int {
        guard !activeManifestMigrationCompleted else {
            return pendingCloudReviewItems.count
        }

        let items = try await scanCloudOnlyReviewItems(appCoordinator: appCoordinator)
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
        appCoordinator: AppDataCoordinator
    ) async throws -> [CloudReviewItem] {
        var builders: [String: CloudReviewItemBuilder] = [:]
        let trustedManifest = try await fetchTrustedActiveManifestRecordNames()

        let localRecordings = appCoordinator.coreDataManager.getAllRecordings()
        let localRecordingIds = Set(localRecordings.compactMap { $0.id })
        let localTranscriptIds = Set(appCoordinator.coreDataManager.getAllTranscripts().compactMap { $0.id })
        let localSummaryIds = Set(appCoordinator.coreDataManager.getAllSummaries().compactMap { $0.id })
        let locallyExcludedRecordingIds = Set(localRecordings.compactMap { recording in
            recording.isCloudSyncDisabled ? recording.id : nil
        })
        let deletionTargets = try await fetchDeletionTargets()
        let deletedRecordingIds = deletionTargets.recordings

        let recordingRecords = try await fetchBackupRecords(recordType: Self.backupRecordingRecordType)
        let transcriptRecords = try await fetchBackupRecords(recordType: Self.backupTranscriptRecordType)
        let summaryRecords = try await fetchBackupRecords(recordType: Self.backupSummaryRecordType)
        let legacySummaryRecords = try await fetchLegacySummarySyncRecords()
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
                let deletedCount = try await deleteExistingCloudRecords(legacySchemaBootstrapRecordIDs)
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

        try await validateiCloudAccountAvailability()

        // Restoring one review item still writes records and mutates the manifest,
        // so it takes its turn like any other operation. Running outside the
        // coordinator let it interleave with an erase and put records back after
        // the enumeration had already passed them.
        var result = CloudRestoreResult()
        try await operationCoordinator.submit(
            intent: .restoreToThisDevice,
            allowJoiningRunningOperation: false,
            coalescesWithEquivalentRequests: false
        ) { [weak self] in
            guard let self else { return }
            result = try await self.runReviewItemRestore(
                item,
                appCoordinator: appCoordinator,
                includeAudioFiles: includeAudioFiles
            )
        }
        return result
    }

    private func runReviewItemRestore(
        _ item: CloudReviewItem,
        appCoordinator: AppDataCoordinator,
        includeAudioFiles: Bool
    ) async throws -> CloudRestoreResult {
        let recorder = beginRun(reason: .reviewRestore, intent: .restoreToThisDevice)
        do {
            let result = try await performReviewItemRestore(
                item,
                appCoordinator: appCoordinator,
                includeAudioFiles: includeAudioFiles,
                recorder: recorder
            )
            endRun(recorder, result: .succeeded)
            return result
        } catch {
            // A restore that threw part way through is not a successful one; the
            // metrics have to be able to tell the two apart.
            endRun(recorder, result: .failed)
            throw error
        }
    }

    private func performReviewItemRestore(
        _ item: CloudReviewItem,
        appCoordinator: AppDataCoordinator,
        includeAudioFiles: Bool,
        recorder: CloudSyncRunRecorder?
    ) async throws -> CloudRestoreResult {
        // One batched read covers all three types: the review item names its own
        // records, so there is nothing to search for.
        recorder?.begin(.fetchCloudSnapshot)
        let selectedRecords = try await fetchBackupRecordsByRecordNames(
            item.backupRecordNames,
            expectedRecordTypes: [
                Self.backupRecordingRecordType,
                Self.backupTranscriptRecordType,
                Self.backupSummaryRecordType
            ]
        )
        let recordingRecords = selectedRecords.filter { $0.recordType == Self.backupRecordingRecordType }
        let transcriptRecords = selectedRecords.filter { $0.recordType == Self.backupTranscriptRecordType }
        let summaryRecords = selectedRecords.filter { $0.recordType == Self.backupSummaryRecordType }

        recorder?.begin(.writeContent)
        var recordsToReactivate: [CKRecord] = []
        for record in selectedRecords {
            var shouldSave = false
            markBackupRecordActive(record, changed: &shouldSave)
            if shouldSave {
                recordsToReactivate.append(record)
            }
        }
        try await saveBackupRecords(recordsToReactivate)

        removeQuarantineEntries(
            backupRecordNames: item.backupRecordNames,
            legacySummaryRecordNames: item.legacySummaryRecordNames
        )

        recorder?.begin(.commitManifest)
        // Adding the selected records to the manifest, rather than rewriting it,
        // leaves everything another device put there untouched.
        try await applyManifestDelta(
            .adding(
                recordings: Set(recordingRecords.map { $0.recordID.recordName }),
                transcripts: Set(transcriptRecords.map { $0.recordID.recordName }),
                summaries: Set(summaryRecords.map { $0.recordID.recordName })
            )
        )

        // Restore only what the user selected. The old flow followed a single-item
        // restore with a full restore, a full backup, and a second full review
        // scan — four passes over the whole dataset to bring back one item.
        recorder?.begin(.applyCloudWinners)
        var result = CloudRestoreResult()
        if !selectedRecords.isEmpty {
            result = try await restoreSelectedBackupRecords(
                recordingRecords: recordingRecords,
                transcriptRecords: transcriptRecords,
                summaryRecords: summaryRecords,
                appCoordinator: appCoordinator,
                includeAudioFiles: includeAudioFiles
            )
        }

        let legacyRestored = try await restoreSelectedLegacySummaryRecords(
            recordNames: item.legacySummaryRecordNames,
            appCoordinator: appCoordinator
        )
        result.summariesRestored += legacyRestored
        recorder?.endPhase()

        await MainActor.run {
            self.pendingCloudReviewItems.removeAll { $0.id == item.id }
            self.lastMaintenanceMessage = "Restored \(item.title) from iCloud review."
        }
        return result
    }

    /// Restores exactly the records the user picked out of the review list, by
    /// running the ordinary restore leg against a snapshot containing only those
    /// records. Nothing else on the device or in the cloud is touched.
    private func restoreSelectedBackupRecords(
        recordingRecords: [CKRecord],
        transcriptRecords: [CKRecord],
        summaryRecords: [CKRecord],
        appCoordinator: AppDataCoordinator,
        includeAudioFiles: Bool
    ) async throws -> CloudRestoreResult {
        var snapshot = BackupCloudSnapshot()
        for record in recordingRecords {
            snapshot.recordings[record.recordID] = record
        }
        for record in transcriptRecords {
            snapshot.transcripts[record.recordID] = record
        }
        for record in summaryRecords {
            snapshot.summaries[record.recordID] = record
        }

        return try await performRestore(
            appCoordinator: appCoordinator,
            includeAudioFiles: includeAudioFiles,
            restoreSettings: false,
            preflight: CloudSyncPreflight(deletionTargets: try await fetchDeletionTargets()),
            snapshot: snapshot,
            recorder: nil,
            reportsEmptyCloudAsError: false
        )
    }

    func deleteCloudReviewItem(_ item: CloudReviewItem) async throws -> Int {
        guard isEnabled else {
            throw NSError(
                domain: "iCloudStorageManager",
                code: 4007,
                userInfo: [NSLocalizedDescriptionKey: "Enable iCloud Sync before deleting review items."]
            )
        }

        try await validateiCloudAccountAvailability()

        // Deleting a review item removes cloud records and rewrites the manifest,
        // so it queues with everything else rather than racing it.
        var deletedCount = 0
        try await operationCoordinator.submit(
            intent: .deletionFlush,
            allowJoiningRunningOperation: false,
            coalescesWithEquivalentRequests: false
        ) { [weak self] in
            guard let self else { return }
            deletedCount = try await self.performReviewItemDeletion(item)
        }
        return deletedCount
    }

    private func performReviewItemDeletion(_ item: CloudReviewItem) async throws -> Int {
        var recordIDs = item.backupRecordNames.map { CKRecord.ID(recordName: $0) }
        recordIDs.append(contentsOf: item.legacySummaryRecordNames.map { CKRecord.ID(recordName: $0) })

        let deletedCount = try await deleteExistingCloudRecords(recordIDs)
        try await removeBackupRecordNamesFromContentIndex(
            recordingRecordNames: item.backupRecordNames.filter { $0.hasPrefix(Self.backupRecordingRecordPrefix) },
            transcriptRecordNames: item.backupRecordNames.filter { $0.hasPrefix(Self.backupTranscriptRecordPrefix) },
            summaryRecordNames: item.backupRecordNames.filter { $0.hasPrefix(Self.backupSummaryRecordPrefix) })

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
        var result = CloudRestoreResult()
        try await operationCoordinator.submit(
            intent: .restoreToThisDevice,
            allowJoiningRunningOperation: false,
            coalescesWithEquivalentRequests: false
        ) { [weak self] in
            guard let self else { return }
            result = try await self.performManualRestore(
                appCoordinator: appCoordinator,
                includeAudioFiles: includeAudioFiles,
                restoreSettings: restoreSettings
            )
        }
        return result
    }

    private func performManualRestore(
        appCoordinator: AppDataCoordinator,
        includeAudioFiles: Bool,
        restoreSettings: Bool
    ) async throws -> CloudRestoreResult {
        isManualCloudTransferInProgress = true
        defer { isManualCloudTransferInProgress = false }

        let recorder = beginRun(reason: .manualRestore, intent: .restoreToThisDevice)
        do {
            try await validateiCloudAccountAvailability()
            await MainActor.run {
                self.syncStatus = .syncing
                self.lastError = nil
            }

            let preflight = try await performDeletionPreflight(
                appCoordinator: appCoordinator,
                recorder: recorder
            )
            let result = try await performRestore(
                appCoordinator: appCoordinator,
                includeAudioFiles: includeAudioFiles,
                restoreSettings: restoreSettings,
                preflight: preflight,
                snapshot: nil,
                recorder: recorder
            )

            await MainActor.run {
                self.lastSyncDate = Date()
                UserDefaults.standard.set(self.lastSyncDate, forKey: "lastSyncDate")
                self.syncStatus = .completed
                self.lastError = nil
            }
            endRun(recorder, result: .succeeded)
            return result
        } catch {
            endRun(recorder, result: .failed)
            await MainActor.run {
                self.syncStatus = .failed(error.localizedDescription)
                self.lastError = error.localizedDescription
            }
            throw error
        }
    }

    /// The restore leg proper.
    ///
    /// `snapshot` is the backup leg's view of the cloud when the two run together;
    /// only a standalone restore reads the records itself.
    /// - Parameter reportsEmptyCloudAsError: only a restore the user asked for
    ///   should fail when the cloud turns out to be empty. During a routine
    ///   reconcile an empty cloud is an ordinary state — a new account, or a device
    ///   whose recordings are all marked Keep on This Device — and raising an error
    ///   there would fail every sync and stop the throttle clock from ever advancing.
    func performRestore(
        appCoordinator: AppDataCoordinator,
        includeAudioFiles: Bool,
        restoreSettings: Bool,
        preflight: CloudSyncPreflight,
        snapshot: BackupCloudSnapshot?,
        recorder: CloudSyncRunRecorder?,
        reportsEmptyCloudAsError: Bool = true
    ) async throws -> CloudRestoreResult {
        do {
            var result = CloudRestoreResult()
            let context = appCoordinator.coreDataManager.managedObjectContext
            let fileManager = FileManager.default
            let deletionTargets = preflight.deletionTargets

            let restoreSnapshot: BackupCloudSnapshot
            if let snapshot {
                // Shared with the backup leg: it has just read the cloud and made
                // it agree with this device, so reading the same records again
                // would be pure duplication.
                restoreSnapshot = snapshot
            } else {
                recorder?.begin(.fetchCloudSnapshot)
                let manifestState = try await contentIndexCoordinator.fetchManifestState()
                restoreSnapshot = try await fetchBackupCloudSnapshot(
                    manifest: manifestState.manifest,
                    manifestWasTrusted: manifestState.isTrusted,
                    recordingRecordNames: [],
                    transcriptRecordNames: [],
                    summaryRecordNames: [],
                    includeAudioAssets: includeAudioFiles
                )
            }

            var recordingRecords = Array(restoreSnapshot.recordings.values)
            var transcriptRecords = Array(restoreSnapshot.transcripts.values)
            var summaryRecords = Array(restoreSnapshot.summaries.values)

            // Without a trusted manifest the snapshot holds only the ids this device
            // already knew to ask for. Deciding on emptiness alone meant a device
            // with any local data of its own quietly stopped discovering
            // cloud-only records — a first install found them, an established
            // device never did.
            //
            // The snapshot's own flag can be stale: when the backup leg shares its
            // snapshot, the manifest may have been created by that leg's commit
            // afterwards. Ask again rather than scanning the whole zone on the
            // strength of a flag from earlier in the same run.
            var manifestIsTrusted = restoreSnapshot.manifestWasTrusted
            if !manifestIsTrusted {
                manifestIsTrusted = try await contentIndexCoordinator.fetchManifestState().isTrusted
            }

            if !manifestIsTrusted ||
                (recordingRecords.isEmpty && transcriptRecords.isEmpty && summaryRecords.isEmpty) {
                // A first install, a restored device, an untrusted manifest, or a
                // repair — the situations where a full scan is the right tool.
                recorder?.begin(.fetchCloudSnapshot)
                let scannedRecordings = try await fetchBackupRecords(
                    recordType: Self.backupRecordingRecordType)
                let scannedTranscripts = try await fetchBackupRecords(
                    recordType: Self.backupTranscriptRecordType)
                let scannedSummaries = try await fetchBackupRecords(
                    recordType: Self.backupSummaryRecordType)

                // Merged, not replaced: the snapshot carries what this run just
                // settled — including a record another device won a conflict with,
                // which a scan started from the server's stored copy would not show.
                recordingRecords = Self.mergedByRecordID(preferring: recordingRecords, over: scannedRecordings)
                transcriptRecords = Self.mergedByRecordID(preferring: transcriptRecords, over: scannedTranscripts)
                summaryRecords = Self.mergedByRecordID(preferring: summaryRecords, over: scannedSummaries)

                if !recordingRecords.isEmpty || !transcriptRecords.isEmpty || !summaryRecords.isEmpty {
                    AppLog.shared.iCloudSync(
                        "Restore bootstrap scan - recordings: \(recordingRecords.count), " +
                        "transcripts: \(transcriptRecords.count), summaries: \(summaryRecords.count)",
                        level: .debug
                    )
                }
            }

            if includeAudioFiles {
                // The snapshot skipped audio assets. Bring them down only for the
                // recordings that are about to be written to disk.
                recordingRecords = try await recordingRecordsWithAudioAssets(recordingRecords)
            }

            recorder?.begin(.applyCloudWinners)
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

            let trustedActiveManifest = try await fetchTrustedActiveManifestRecordNames()
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

                if applyCloudRecording,
                   includeAudioFiles,
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

                    // `existing` is matched on transcript id, so a cloud row with a
                    // *different* id — the other device deleted and retranscribed —
                    // arrives with nothing to compare against and would relink the
                    // recording to the older transcript. Arbitrate against whatever
                    // the recording currently points at before repointing it.
                    if Self.shouldRelinkRestoredRow(
                        candidateId: transcriptId,
                        candidateTimestamp: localTranscriptContentTimestamp(entry),
                        linkedId: recording.transcriptId ?? recording.transcript?.id,
                        linkedTimestamp: recording.transcript.map(localTranscriptContentTimestamp) ?? nil
                    ) {
                        recording.transcript = entry
                        recording.transcriptId = transcriptId
                        if recording.transcriptionStatus == nil || recording.transcriptionStatus?.isEmpty == true {
                            recording.transcriptionStatus = ProcessingStatus.completed.rawValue
                        }
                    } else {
                        result.localItemsKeptAsNewer += 1
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

                    // Same rule as transcripts: `existing` is matched on summary
                    // id, so a cloud row from delete-and-regenerate arrives with
                    // nothing to compare against and would steal the recording's
                    // pointer. Arbitrate against whatever the recording currently
                    // points at before repointing it.
                    if Self.shouldRelinkRestoredRow(
                        candidateId: summaryId,
                        candidateTimestamp: localSummaryContentTimestamp(entry),
                        linkedId: recording.summaryId ?? recording.summary?.id,
                        linkedTimestamp: recording.summary.map(localSummaryContentTimestamp) ?? nil
                    ) {
                        recording.summary = entry
                        recording.summaryId = summaryId
                        if recording.summaryStatus == nil || recording.summaryStatus?.isEmpty == true {
                            recording.summaryStatus = ProcessingStatus.completed.rawValue
                        }
                    } else {
                        result.localItemsKeptAsNewer += 1
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
                let settingsResult = try await restoreSettingsFromiCloud()
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
                let reviewItems = (try? await scanCloudOnlyReviewItems(appCoordinator: appCoordinator)) ?? []
                result.itemsHeldForReview += reviewItems.count
            }

            if !backupRecordNamesHeldForReview.isEmpty {
                quarantinedBackupRecordNames = backupRecordNamesHeldForReview
            }
            result.itemsHeldForReview += heldReviewKeys.count

            if !hasContentBackupRecords, result.itemsHeldForReview == 0, reportsEmptyCloudAsError {
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
            recorder?.endPhase()

            result.settingsRestored = restoredSettings
            result.includedSensitiveSettings = restoredSensitiveSettings

            return result
        } catch {
            recorder?.endPhase()
            throw error
        }
    }

    private func restoreSummariesFromCloudIfAvailable(
        appCoordinator: AppDataCoordinator,
        existingSummaryIds: Set<UUID>
    ) async throws -> Int {
        // Try the paginated query first. Catch any thrown errors (e.g. non-queryable
        // schema fields) so we can fall through to the schema-safe path instead of
        // propagating the error to the call site where try? would silently return 0.
        var cloudSummaries: [EnhancedSummaryData]
        do {
            cloudSummaries = try await fetchAllSummariesFromCloud()
        } catch {
            AppLog.shared.iCloudSync("Query threw error (\(error.localizedDescription)), trying schema-safe record discovery", level: .error)
            cloudSummaries = []
        }

        // If the query returned nothing or threw, it may be a non-queryable schema issue.
        // Fall back to the schema-safe record-operation approach which uses
        // UUID scanning + zone change tracking instead of CKQuery.
        if cloudSummaries.isEmpty {
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
        appCoordinator: AppDataCoordinator
    ) async throws -> Int {
        var restoredCount = 0
        let existingSummaryIds = Set(appCoordinator.coreDataManager.getAllSummaries().compactMap { $0.id })
        let deletionTargets = try await fetchDeletionTargets()

        for recordName in recordNames {
            do {
                let recordID = CKRecord.ID(recordName: recordName)
                let fetchOutcome = try await cloudExecutor.fetch([recordID])
                recordMetrics(fetch: fetchOutcome)
                try fetchOutcome.throwIfIncomplete()
                guard let record = fetchOutcome.records[recordID] else { continue }
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
            // Mark the work rather than running a whole backup here: the debounced
            // routine snapshot uploads these rows within seconds, and a restore of
            // one review item should not cost a full pass over the dataset.
            hasPendingLocalChanges = true
        }
        return restoredCount
    }

    /// Starts a metrics recorder for one run. Nothing user-visible is recorded —
    /// see `CloudSyncMetrics` for why the report is counts only.
    func beginRun(
        reason: CloudSyncReason,
        intent: CloudSyncIntent,
        queueDelaySeconds: TimeInterval = 0
    ) -> CloudSyncRunRecorder? {
        let recorder = CloudSyncRunRecorder(
            reason: reason,
            intent: intent,
            queueDelaySeconds: queueDelaySeconds,
            clock: syncClock,
            sink: syncMetricsSink
        )
        activeRunRecorder = recorder
        return recorder
    }

    func endRun(_ recorder: CloudSyncRunRecorder?, result: CloudSyncRunResultKind) {
        recorder?.finish(result)
        if activeRunRecorder === recorder {
            activeRunRecorder = nil
        }
    }

    /// Phases one and two of the barrier, run exactly once per operation: push this
    /// device's durable tombstones out, then apply everyone else's.
    func performDeletionPreflight(
        appCoordinator: AppDataCoordinator,
        recorder: CloudSyncRunRecorder?
    ) async throws -> CloudSyncPreflight {
        recorder?.begin(.flushOutboundTombstones)
        _ = try await flushPendingiCloudMutations(appCoordinator: appCoordinator)

        recorder?.begin(.applyInboundTombstones)
        let markers = try await applyiCloudDeletionMarkers(appCoordinator: appCoordinator)
        recorder?.endPhase()

        return CloudSyncPreflight(
            deletionTargets: markers.targets,
            markerApplication: markers.application
        )
    }

    func reconcileAllDataWithiCloud(
        appCoordinator: AppDataCoordinator,
        reason: CloudSyncReason
    ) async throws -> CloudReconcileResult {
        guard isEnabled else {
            return CloudReconcileResult()
        }
        guard networkStatus.canSync else {
            throw NSError(
                domain: "iCloudStorageManager",
                code: 4010,
                userInfo: [NSLocalizedDescriptionKey: "Network unavailable."]
            )
        }
        if let deferredUntil = cloudExecutor.deferredUntil {
            // CloudKit asked for a long backoff. Saying "finished, nothing to do"
            // here would be a lie; the caller needs to know work is still pending.
            var deferredResult = CloudReconcileResult()
            deferredResult.wasDeferredUntil = deferredUntil
            return deferredResult
        }

        var result = CloudReconcileResult()
        let outcome = try await operationCoordinator.submit(intent: .routineSnapshot) { [weak self] in
            guard let self else { return }
            result = try await self.performReconcile(appCoordinator: appCoordinator, reason: reason)
        }

        switch outcome {
        case .completed:
            return result
        case .joinedRunningOperation(let intent), .coalescedIntoFollowUp(let intent):
            // The work happened, but not as this request's own run. Reporting an
            // empty result as a success is what made bursts look free.
            result.wasCoalescedIntoRunningSync = true
            AppLog.shared.iCloudSync(
                "Sync request (\(reason.rawValue)) folded into a \(intent.rawValue) run already in progress",
                level: .debug
            )
            return result
        case .deferred(let until):
            result.wasDeferredUntil = until
            return result
        }
    }

    private func performReconcile(
        appCoordinator: AppDataCoordinator,
        reason: CloudSyncReason
    ) async throws -> CloudReconcileResult {
        isAutomaticCloudReconcileInProgress = true
        isAutomaticReconcileRunning = true
        let recorder = beginRun(reason: reason, intent: .routineSnapshot)
        defer {
            isAutomaticCloudReconcileInProgress = false
            isAutomaticReconcileRunning = false
        }

        var result = CloudReconcileResult()
        do {
            let options = currentCloudBackupOptions()

            let preflight = try await performDeletionPreflight(
                appCoordinator: appCoordinator,
                recorder: recorder
            )
            result.deletedLocalRecordings = preflight.markerApplication.deletedLocalItems
            result.deletedCloudRecords = preflight.markerApplication.deletedCloudRecords
            result.revivedLocalItems = preflight.markerApplication.revivedLocally

            let backupLeg = try await performBackup(
                appCoordinator: appCoordinator,
                options: options,
                preflight: preflight,
                recorder: recorder
            )
            result.backupResult = backupLeg.result

            _ = try await ensureActiveManifestMigrationScanIfNeeded(appCoordinator: appCoordinator)

            // The backup leg has just read the cloud and made it agree with this
            // device. Handing its snapshot to the restore leg is what keeps an
            // ordinary activation to one pass over the data instead of two.
            result.restoreResult = try await performRestore(
                appCoordinator: appCoordinator,
                includeAudioFiles: options.includeAudioFiles,
                restoreSettings: options.includeSettings,
                preflight: preflight,
                snapshot: backupLeg.snapshot,
                recorder: recorder,
                reportsEmptyCloudAsError: false
            )

            // The restore leg has just pointed every recording at the winning transcript and
            // summary, so any duplicate left behind is now safe to drop.
            recorder?.begin(.pruneDuplicates)
            let pruned = pruneSupersededLocalDuplicates(appCoordinator: appCoordinator)
            result.prunedDuplicateItems = pruned.transcripts + pruned.summaries
            recorder?.endPhase()

            let restoredCount = result.restoreResult.recordingsRestored +
                result.restoreResult.transcriptsRestored +
                result.restoreResult.summariesRestored
            var message =
                "iCloud sync finished (\(reason.rawValue)): " +
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
            // Throttle timestamps are recorded only here, after a complete run. A
            // failed pass must not buy itself fifteen quiet minutes.
            lastSuccessfulRoutineSyncDate = Date()
            hasPendingLocalChanges = false
            endRun(recorder, result: result.backupResult.wasSkippedNoChanges ? .skippedNoChanges : .succeeded)
            return result
        } catch let deferral as CloudSyncDeferredError {
            // CloudKit asked this device to wait mid-run. That is not a failure and
            // not a completed sync: the pending work stays pending, the throttle
            // clock does not advance, and the caller is told when to come back.
            endRun(recorder, result: .deferred)
            result.wasDeferredUntil = deferral.until
            AppLog.shared.iCloudSync(
                "iCloud sync deferred mid-run for \(Int(deferral.until.timeIntervalSinceNow))s at CloudKit's request",
                level: .debug
            )
            return result
        } catch {
            endRun(recorder, result: .failed)
            throw error
        }
    }

    private func saveDeletionMarker(
        kind: CloudDeletionTargetKind,
        id: UUID,
        recordingId: UUID?,
        deletedAt: Date
    ) async throws {
        let recordID = CKRecord.ID(
            recordName: deletionMarkerRecordName(kind: kind, id: id)
        )
        let record = try await fetchOrCreateRecord(
            recordType: Self.backupDeletionRecordType,
            recordID: recordID)
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
        try await saveBackupRecord(record)
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

        try await validateiCloudAccountAvailability()

        try await saveDeletionMarker(
            kind: .recording,
            id: recordingId,
            recordingId: nil,
            deletedAt: deletedAt
        )

        let deletedCloudRecords = try await deleteCloudContentRecords(
            recordingId: recordingId,
            transcriptIds: transcriptIds,
            summaryIds: summaryIds
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

        try await validateiCloudAccountAvailability()
        try await saveDeletionMarker(
            kind: .transcript,
            id: transcriptId,
            recordingId: recordingId,
            deletedAt: deletedAt
        )
        let deletedCloudRecords = try await deleteTranscriptContentRecords(
            transcriptId: transcriptId
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

        try await validateiCloudAccountAvailability()
        try await saveDeletionMarker(
            kind: .summary,
            id: summaryId,
            recordingId: recordingId,
            deletedAt: deletedAt
        )
        let deletedCloudRecords = try await deleteSummaryContentRecords(
            summaryIds: [summaryId]
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

        try await validateiCloudAccountAvailability()

        let transcripts = appCoordinator.coreDataManager.getAllTranscripts().filter {
            $0.recordingId == recordingId
        }
        let summaries = appCoordinator.coreDataManager.getAllSummaries().filter {
            ($0.recordingId ?? $0.recording?.id) == recordingId
        }

        let deletedCloudRecords = try await deleteCloudContentRecords(
            recordingId: recordingId,
            transcriptIds: transcripts.compactMap(\.id),
            summaryIds: summaries.compactMap(\.id)
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

    func clearPendingRecordingDeletion(recordingId: UUID) {
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

    /// Durable outbound work: tombstones and removals that must reach CloudKit
    /// before this device can claim to be in sync.
    var pendingCloudDeletionCount: Int {
        pendingCloudDeletionMarkers.count +
            pendingTranscriptCloudRemovals.count +
            pendingSummaryCloudRemovals.count +
            pendingLocalOnlyCloudRemovals.count
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

    /// Applies inbound tombstones and reports which ids remain deleted.
    ///
    /// The surviving targets are returned rather than refetched: this used to run
    /// once per leg, and each leg then queried the same deletion records again, so
    /// one reconcile paid for the marker scan four times over.
    private func applyiCloudDeletionMarkers(
        appCoordinator: AppDataCoordinator
    ) async throws -> (application: DeletionMarkerApplication, targets: CloudDeletionTargets) {
        try await validateiCloudAccountAvailability()

        let deletionRecords = try await fetchBackupRecords(
            recordType: Self.backupDeletionRecordType)
        guard !deletionRecords.isEmpty else { return (DeletionMarkerApplication(), CloudDeletionTargets()) }

        var application = DeletionMarkerApplication()
        var targets = CloudDeletionTargets()

        /// Withdraws a tombstone whose target was edited here after the delete. The
        /// later edit wins, and because the marker is gone before this reconcile's
        /// backup leg runs, the surviving item uploads again for every device.
        func reviveLocallyModifiedItem(_ record: CKRecord, describedAs description: String) async throws {
            try await deleteBackupRecords([record.recordID])
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

                targets.recordings.insert(target.id)
                application.deletedCloudRecords += try await deleteCloudContentRecords(
                    recordingId: target.id,
                    transcriptIds: [],
                    summaryIds: []
                )

                guard let recording, recording.isCloudSyncDisabled == false else {
                    continue
                }
                do {
                    // Applying someone else's tombstone, so do not raise one of
                    // our own on the way back out.
                    try appCoordinator.coreDataManager.deleteRecording(
                        id: target.id,
                        enqueueCloudDeletion: false
                    )
                    application.deletedLocalItems += 1
                } catch CoreDataDeletionError.recordingNotFound {
                    // Already gone locally — the marker has nothing left to apply.
                    continue
                } catch {
                    AppLog.shared.iCloudSync(
                        "Failed to apply iCloud recording deletion locally for \(target.id.uuidString): \(error)",
                        level: .error
                    )
                }
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

                targets.transcripts.insert(target.id)
                application.deletedCloudRecords += try await deleteTranscriptContentRecords(
                    transcriptId: target.id
                )

                guard transcript != nil, transcriptParent?.isCloudSyncDisabled != true else { continue }
                do {
                    // Applying another device's marker; raising one of our own
                    // would re-create the tombstone after a revive withdrew it.
                    try appCoordinator.coreDataManager.deleteTranscript(
                        id: target.id,
                        enqueueCloudDeletion: false
                    )
                } catch {
                    AppLog.shared.iCloudSync(
                        "Failed to apply iCloud transcript deletion locally for \(target.id.uuidString): \(error)",
                        level: .error
                    )
                }
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

                targets.summaries.insert(target.id)
                application.deletedCloudRecords += try await deleteSummaryContentRecords(
                    summaryIds: [target.id]
                )

                guard summary != nil, summaryParent?.isCloudSyncDisabled != true else { continue }
                do {
                    // deleteSummary removes the attachment files itself, but only
                    // once the row deletion has committed. Doing it here first
                    // destroyed the user's notes even when that save rolled back.
                    try appCoordinator.coreDataManager.deleteSummary(
                        id: target.id,
                        enqueueCloudDeletion: false
                    )
                } catch {
                    AppLog.shared.iCloudSync(
                        "Failed to apply iCloud summary deletion locally for \(target.id.uuidString): \(error)",
                        level: .error
                    )
                }
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

        return (application, targets)
    }

    private func fetchDeletionTargets() async throws -> CloudDeletionTargets {
        let deletionRecords = try await fetchBackupRecords(
            recordType: Self.backupDeletionRecordType)
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
        summaryIds: [UUID]
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

        // The manifest names every live record, so the children of this recording
        // are found with one batched read per type instead of a full scan.
        //
        // This read must not be swallowed. Failing it quietly deleted the recording
        // and left its transcript and summary in the cloud, where the next restore
        // brings them back as orphans — and the durable deletion entry, believing
        // itself finished, would not try again.
        var manifestRecords = try await fetchBackupRecordsFromContentIndex()
        if manifestRecords.transcripts.isEmpty && manifestRecords.summaries.isEmpty {
            // No trusted manifest to name the children. A deletion that leaves
            // orphans behind is worse than one scan on a path the user drives.
            manifestRecords.transcripts = try await fetchBackupRecords(
                recordType: Self.backupTranscriptRecordType)
            manifestRecords.summaries = try await fetchBackupRecords(
                recordType: Self.backupSummaryRecordType)
        }
        let transcriptRecords = manifestRecords.transcripts
        let summaryRecords = manifestRecords.summaries
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
            summaryIds: summaryIds)

        let deletedRecordCount = try await deleteExistingCloudRecords(
            backupRecordIDs + legacySummaryRecordIDs)
        try await removeBackupRecordNamesFromContentIndex(
            recordingRecordNames: [recordingBackupRecordName],
            transcriptRecordNames: Array(Set(knownTranscriptRecordNames + discoveredTranscriptRecordNames)),
            summaryRecordNames: Array(Set(knownSummaryRecordNames + discoveredSummaryRecordNames)))
        return deletedRecordCount
    }

    private func deleteTranscriptContentRecords(
        transcriptId: UUID
    ) async throws -> Int {
        let backupTranscriptRecordName = makeBackupRecordName(
            prefix: Self.backupTranscriptRecordPrefix,
            id: transcriptId
        )
        var deletedRecordCount = try await deleteExistingCloudRecords(
            [CKRecord.ID(recordName: backupTranscriptRecordName)])
        try await removeBackupRecordNamesFromContentIndex(
            recordingRecordNames: [],
            transcriptRecordNames: [backupTranscriptRecordName],
            summaryRecordNames: [])

        // Clear the parent and summary references as part of the same cloud
        // mutation. Otherwise a device restoring only the cloud backup could
        // recreate a dangling transcript link after the transcript record was
        // removed.
        let transcriptIdString = transcriptId.uuidString
        let manifestRecords = try await fetchBackupRecordsFromContentIndex()

        // Recording records arrive without their audio assets, so the ones that
        // need editing are refetched in full before being written back.
        let recordingsToClear = manifestRecords.recordings.filter {
            $0[Self.fieldTranscriptId] as? String == transcriptIdString
        }
        let fullRecordings = try await fullRecordingRecords(for: recordingsToClear.map(\.recordID))
        var relationshipRecordsToSave: [CKRecord] = []
        for partialRecord in recordingsToClear {
            let record = fullRecordings[partialRecord.recordID] ?? partialRecord
            var shouldSave = false
            updateStringField(Self.fieldTranscriptId, value: nil, on: record, changed: &shouldSave)
            updateStringField(
                Self.fieldTranscriptionStatus,
                value: ProcessingStatus.notStarted.rawValue,
                on: record,
                changed: &shouldSave
            )
            updateDateField(Self.fieldLastModified, value: syncClock.now, on: record, changed: &shouldSave)
            if shouldSave {
                relationshipRecordsToSave.append(record)
            }
        }

        for record in manifestRecords.summaries where record[Self.fieldTranscriptId] as? String == transcriptIdString {
            var shouldSave = false
            updateStringField(Self.fieldTranscriptId, value: nil, on: record, changed: &shouldSave)
            updateDateField(Self.fieldLastModified, value: syncClock.now, on: record, changed: &shouldSave)
            if shouldSave {
                relationshipRecordsToSave.append(record)
            }
        }

        try await saveBackupRecords(relationshipRecordsToSave)
        deletedRecordCount += relationshipRecordsToSave.count

        // A legacy summary record may still point at the removed transcript. Keep the
        // summary, but clear that relationship so legacy restore cannot recreate it.
        let legacyRecords = try await fetchLegacySummarySyncRecords()
        var legacyRecordsToSave: [CKRecord] = []
        for record in legacyRecords where record[CloudKitSummaryRecord.transcriptIdField] as? String == transcriptId.uuidString {
            record[CloudKitSummaryRecord.transcriptIdField] = nil
            record[CloudKitSummaryRecord.lastModifiedField] = syncClock.now
            legacyRecordsToSave.append(record)
        }
        do {
            try await saveBackupRecords(legacyRecordsToSave)
            deletedRecordCount += legacyRecordsToSave.count
        } catch {
            AppLog.shared.iCloudSync(
                "Could not clear deleted transcript references from \(legacyRecordsToSave.count) legacy summary record(s): \(error.localizedDescription)",
                level: .error
            )
        }
        return deletedRecordCount
    }

    private func deleteSummaryContentRecords(
        summaryIds: [UUID]
    ) async throws -> Int {
        let backupSummaryRecordNames = summaryIds.map {
            makeBackupRecordName(prefix: Self.backupSummaryRecordPrefix, id: $0)
        }
        let recordIDs = summaryIds.map { CKRecord.ID(recordName: $0.uuidString) } +
            backupSummaryRecordNames.map { CKRecord.ID(recordName: $0) }

        let legacySummaryRecordIDs = try await legacySummarySyncRecordIDs(
            recordingId: nil,
            summaryIds: summaryIds)
        var deletedRecordCount = try await deleteExistingCloudRecords(
            recordIDs + legacySummaryRecordIDs)
        try await removeBackupRecordNamesFromContentIndex(
            recordingRecordNames: [],
            transcriptRecordNames: [],
            summaryRecordNames: backupSummaryRecordNames)

        // Clear the recording's scalar relationship and lifecycle status so a
        // restore cannot resurrect a dangling summary reference from the parent
        // recording record.
        let manifestRecords = try await fetchBackupRecordsFromContentIndex()
        let summaryIdStrings = Set(summaryIds.map { $0.uuidString })
        let recordingsToClear = manifestRecords.recordings.filter { record in
            guard let summaryIdString = record[Self.fieldSummaryId] as? String else { return false }
            return summaryIdStrings.contains(summaryIdString)
        }
        let fullRecordings = try await fullRecordingRecords(for: recordingsToClear.map(\.recordID))
        var relationshipRecordsToSave: [CKRecord] = []
        for partialRecord in recordingsToClear {
            let record = fullRecordings[partialRecord.recordID] ?? partialRecord
            var shouldSave = false
            updateStringField(Self.fieldSummaryId, value: nil, on: record, changed: &shouldSave)
            updateStringField(
                Self.fieldSummaryStatus,
                value: ProcessingStatus.notStarted.rawValue,
                on: record,
                changed: &shouldSave
            )
            updateDateField(Self.fieldLastModified, value: syncClock.now, on: record, changed: &shouldSave)
            if shouldSave {
                relationshipRecordsToSave.append(record)
            }
        }
        try await saveBackupRecords(relationshipRecordsToSave)
        deletedRecordCount += relationshipRecordsToSave.count
        return deletedRecordCount
    }

    /// Deletes in one batch and reports how many records were really there. The
    /// count is shown to the user, so an already-absent record must not inflate it —
    /// but it is still a success, not a failure, and never a reason to fetch first.
    private func deleteExistingCloudRecords(_ recordIDs: [CKRecord.ID]) async throws -> Int {
        guard !recordIDs.isEmpty else { return 0 }

        let outcome = try await cloudExecutor.delete(recordIDs)
        recordMetrics(modify: outcome)
        try outcome.throwIfIncomplete()
        return outcome.deleted.count - outcome.alreadyAbsent.count
    }

    private func legacySummarySyncRecordIDs(
        recordingId: UUID?,
        summaryIds: [UUID]
    ) async throws -> [CKRecord.ID] {
        let summaryIdStrings = Set(summaryIds.map { $0.uuidString })
        var recordsToDelete: [CKRecord.ID] = summaryIds.map { CKRecord.ID(recordName: $0.uuidString) }

        for record in await legacySummarySyncRecords() {
            let recordRecordingId = record[CloudKitSummaryRecord.recordingIdField] as? String
            if (recordingId.map { recordRecordingId == $0.uuidString } ?? false) ||
                summaryIdStrings.contains(record.recordID.recordName) {
                recordsToDelete.append(record.recordID)
            }
        }

        return Array(Dictionary(grouping: recordsToDelete, by: { $0.recordName }).compactMap { $0.value.first })
    }

    private func fetchLegacySummarySyncRecords() async throws -> [CKRecord] {
        await legacySummarySyncRecords()
    }

    /// The legacy `CD_EnhancedSummary` records predate the manifest, so there is no
    /// known-ID list for them and a query is the only way to find them. Compatibility
    /// paths only — nothing on the routine path calls this.
    private func legacySummarySyncRecords() async -> [CKRecord] {
        let query = CKQuery(recordType: CloudKitSummaryRecord.recordType, predicate: NSPredicate(value: true))
        var records: [CKRecord] = []

        do {
            var page = try await cloudTransport.records(
                matching: query,
                inZoneWith: nil,
                desiredKeys: nil,
                resultsLimit: CKQueryOperation.maximumResults
            )
            while true {
                records.append(contentsOf: page.records)

                guard let cursor = page.queryCursor else { break }
                page = try await cloudTransport.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: nil,
                    resultsLimit: CKQueryOperation.maximumResults
                )
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

    /// Stamps lifecycle state on a record that is being written anyway.
    ///
    /// `syncUpdatedAt` and the device identifier are only touched when something
    /// else about the record changed. Writing them unconditionally made every
    /// record dirty on every device: A would upload, B would see a different device
    /// identifier and upload it back, and the two would trade the same 161 records
    /// forever.
    private func markBackupRecordActive(_ record: CKRecord, changed: inout Bool) {
        var lifecycleChanged = false
        updateStringField(Self.fieldSyncLifecycle, value: Self.syncLifecycleActive, on: record, changed: &lifecycleChanged)
        updateIntField(Self.fieldSyncSchemaVersion, value: Self.activeManifestSchemaVersion, on: record, changed: &lifecycleChanged)

        guard changed || lifecycleChanged else { return }

        record[Self.fieldSyncUpdatedAt] = syncClock.now
        record[Self.fieldDeviceIdentifier] = deviceIdentifier
        changed = true
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

    // MARK: - Batched CloudKit I/O
    //
    // Every fetch, save, and delete below runs through `CloudKitBatchExecutor`.
    // Routine sync must never walk a collection one record at a time: 161 metadata
    // records cost minutes that way, and every extra request was another chance to
    // meet a 503 or a rate limit.

    private func validateiCloudAccountAvailability() async throws {
        let accountStatus = try await cloudTransport.accountStatus()
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
        recordID: CKRecord.ID
    ) async throws -> CKRecord {
        let outcome = try await cloudExecutor.fetch([recordID])
        recordMetrics(fetch: outcome)
        try outcome.throwIfIncomplete()

        if let existingRecord = outcome.records[recordID], existingRecord.recordType == recordType {
            return existingRecord
        }
        return CKRecord(recordType: recordType, recordID: recordID)
    }

    /// The routine read path: the manifest names every live record, so the whole
    /// dataset arrives in `ceil(count / 100)` requests. Records the manifest names
    /// but CloudKit no longer holds are simply absent from the result.
    private func fetchBackupRecordsByRecordNames(
        _ recordNames: [String],
        expectedRecordTypes: Set<String>,
        desiredKeys: [CKRecord.FieldKey]? = nil
    ) async throws -> [CKRecord] {
        guard !recordNames.isEmpty else { return [] }

        let outcome = try await cloudExecutor.fetch(
            recordNames.map { CKRecord.ID(recordName: $0) },
            desiredKeys: desiredKeys
        )
        recordMetrics(fetch: outcome)
        try outcome.throwIfIncomplete()

        return recordNames.compactMap { recordName in
            guard let record = outcome.records[CKRecord.ID(recordName: recordName)] else { return nil }
            return expectedRecordTypes.contains(record.recordType) ? record : nil
        }
    }

    private func fetchBackupRecordsByRecordNames(
        _ recordNames: [String],
        expectedRecordType: String,
        desiredKeys: [CKRecord.FieldKey]? = nil
    ) async throws -> [CKRecord] {
        guard !recordNames.isEmpty else { return [] }

        let outcome = try await cloudExecutor.fetch(
            recordNames.map { CKRecord.ID(recordName: $0) },
            desiredKeys: desiredKeys
        )
        recordMetrics(fetch: outcome)
        try outcome.throwIfIncomplete()

        return recordNames.compactMap { recordName in
            guard let record = outcome.records[CKRecord.ID(recordName: recordName)] else { return nil }
            return record.recordType == expectedRecordType ? record : nil
        }
    }

    /// Full type scan.
    ///
    /// Reserved for first install, a missing or untrusted manifest, explicit
    /// recovery, and schema diagnostics. Routine sync uses the manifest instead —
    /// a query walks every record in the zone and is what made an ordinary
    /// activation cost a full enumeration.
    private func fetchBackupRecords(recordType: String) async throws -> [CKRecord] {
        // A server-requested backoff covers queries too. Starting a scan during one
        // is exactly the traffic CloudKit asked us to stop sending — and returning
        // an empty list would let the caller read the backoff as an empty cloud.
        if let deferredUntil = cloudExecutor.deferredUntil {
            AppLog.shared.iCloudSync(
                "Skipped a \(recordType) scan: CloudKit asked for a backoff " +
                "for another \(Int(deferredUntil.timeIntervalSinceNow))s",
                level: .debug
            )
            throw CloudSyncDeferredError(until: deferredUntil, recordCount: 0)
        }

        // The query and the records it returns fail in different ways, and they are
        // not interchangeable: a query that could not run at all may be a schema
        // problem worth a fallback, while a record CloudKit could not return is a
        // hole in the dataset that no fallback fixes and none of them should hide.
        let scan: QueryScanResult
        do {
            scan = try await runQueryScan(recordType: recordType)
        } catch let error as CKError {
            // A query does not run through the batch executor, so the retry policy
            // never sees this error. Falling straight into a zone scan would put
            // another request on the wire inside a backoff the server just asked
            // for; the fallback exists for schema problems, not for throttling.
            if let deferredUntil = cloudExecutor.recordDeferralIfThrottled(error) {
                AppLog.shared.iCloudSync(
                    "CloudKit throttled a \(recordType) scan; waiting " +
                    "\(Int(deferredUntil.timeIntervalSinceNow))s instead of falling back to a zone scan",
                    level: .debug
                )
                throw CloudSyncDeferredError(until: deferredUntil, recordCount: 0)
            }
            return try await recordsFromZoneChangesIfSupported(recordType: recordType, otherwise: error)
        } catch {
            return try await recordsFromZoneChangesIfSupported(recordType: recordType, otherwise: error)
        }

        if let failure = scan.failures.first {
            // A scan is the only way a cloud-only record is ever found: the
            // manifest path only looks up ids it already knows. Reporting a
            // partial page as a complete dataset loses that record for good.
            AppLog.shared.iCloudSync(
                "A \(recordType) scan could not read \(scan.failures.count) record(s); " +
                "reporting the scan as incomplete rather than as a smaller dataset",
                level: .error
            )
            throw failure.error
        }

        if !scan.records.isEmpty {
            return scan.records
        }

        let zoneQueryRecords = try await fetchBackupRecordsInDefaultZoneQuery(recordType: recordType)
        if !zoneQueryRecords.isEmpty {
            return zoneQueryRecords
        }

        // An empty query result is the normal answer for a type with no records —
        // for example a device that has never had anything deleted asking for
        // deletion markers. Treat a zone that cannot enumerate changes as "nothing
        // more to try" rather than failing the sync around it.
        let zoneChangeRecords = try await recordsFromZoneChangesIfSupported(
            recordType: recordType,
            otherwise: nil
        )
        if !zoneChangeRecords.isEmpty {
            return zoneChangeRecords
        }

        return []
    }

    /// Change enumeration exists only in custom zones, and this app's records all
    /// live in the default one, so CloudKit rejects the call outright there. That
    /// rejection means "this listing method is unavailable", not "the sync failed":
    /// it yields no records, and any error that sent us here is rethrown instead.
    private func recordsFromZoneChangesIfSupported(
        recordType: String,
        otherwise originalError: (any Error)?
    ) async throws -> [CKRecord] {
        do {
            return try await fetchBackupRecordsUsingZoneChanges(recordType: recordType)
        } catch let error as CKError where error.isUnsupportedZoneChangeRequest {
            AppLog.shared.iCloudSync(
                "The default zone does not support change enumeration; " +
                "treating the \(recordType) query result as final",
                level: .debug
            )
            if let originalError {
                throw Self.actionableScanError(originalError, recordType: recordType)
            }
            return []
        }
    }

    /// Neither way of listing a record type works when the query has no index and
    /// the default zone cannot enumerate changes. Say which one is missing and how
    /// to add it, rather than passing CloudKit's own wording to the user.
    private static func actionableScanError(_ error: any Error, recordType: String) -> any Error {
        guard isMissingQueryableIndexDiagnostic(error.localizedDescription) else {
            return error
        }
        return cloudBackupQueryableIndexError(recordType: recordType)
    }

    private struct QueryScanResult {
        var records: [CKRecord] = []
        var failures: [(recordID: CKRecord.ID, error: any Error)] = []
    }

    /// Walks every page of a type query, keeping the records and the per-record
    /// failures apart so the caller can tell a smaller dataset from an incomplete read.
    private func runQueryScan(recordType: String) async throws -> QueryScanResult {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var scan = QueryScanResult()
        var page = try await cloudTransport.records(
            matching: query,
            inZoneWith: nil,
            desiredKeys: nil,
            resultsLimit: CKQueryOperation.maximumResults
        )

        while true {
            scan.records.append(contentsOf: page.records)
            scan.failures.append(contentsOf: page.failures)

            guard let queryCursor = page.queryCursor else {
                break
            }
            page = try await cloudTransport.records(
                continuingMatchFrom: queryCursor,
                desiredKeys: nil,
                resultsLimit: CKQueryOperation.maximumResults
            )
        }

        return scan
    }

    private func fetchBackupRecordsInDefaultZoneQuery(recordType: String) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        let page = try await cloudTransport.records(
            matching: query,
            inZoneWith: CKRecordZone.default().zoneID,
            desiredKeys: nil,
            resultsLimit: 1000
        )
        return try page.recordsOrThrow()
    }

    private func fetchBackupRecordsUsingZoneChanges(recordType: String) async throws -> [CKRecord] {
        let records = try await cloudTransport.recordZoneChanges(inZoneWith: CKRecordZone.default().zoneID)
        return records.filter { $0.recordType == recordType }
    }

    /// Answers "is there anything of ours in this CloudKit environment?" from the
    /// manifest plus a single record, instead of downloading every indexed record.
    private func cloudHasAnyContentBackupRecord() async throws -> Bool {
        let manifest = try await fetchTrustedActiveManifestRecordNames()
        guard let probeRecordName = manifest.allRecordNames.first else {
            // No trusted manifest is not proof the cloud is empty, but it is proof
            // this device cannot skip its upload: seeding again is safe and cheap
            // compared with a full scan on every activation.
            return false
        }

        let probeID = CKRecord.ID(recordName: probeRecordName)
        let outcome = try await cloudExecutor.fetch([probeID])
        recordMetrics(fetch: outcome)
        try outcome.throwIfIncomplete()
        return outcome.records[probeID] != nil
    }

    private func hasAtLeastOneBackupRecord(recordType: String) async throws -> Bool {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        do {
            let page = try await cloudTransport.records(
                matching: query,
                inZoneWith: CKRecordZone.default().zoneID,
                desiredKeys: nil,
                resultsLimit: 1
            )
            return !page.records.isEmpty
        } catch {
            // Fallback for accounts/environments where this query variant is unavailable.
            let records = try await fetchBackupRecords(recordType: recordType)
            return !records.isEmpty
        }
    }

    // MARK: - Manifest

    private func fetchTrustedActiveManifestRecordNames() async throws -> CloudActiveManifest {
        try await contentIndexCoordinator.fetchTrustedManifest()
    }

    /// Adds and removes manifest entries without overwriting what another device
    /// wrote. See `CloudContentIndexCoordinator` for why a whole-record rewrite of
    /// `content_index` is never acceptable outside repair.
    private func applyManifestDelta(_ delta: ManifestDelta) async throws {
        guard !delta.isEmpty else { return }
        _ = try await contentIndexCoordinator.apply(delta)
    }

    /// Full manifest replacement. Explicit repair and one-time migration only.
    private func replaceBackupContentIndex(with manifest: CloudActiveManifest) async throws {
        _ = try await contentIndexCoordinator.replace(with: manifest)
    }

    private func fetchBackupRecordsFromContentIndex(
        desiredKeys: [CKRecord.FieldKey]? = nil
    ) async throws -> BackupContentRecordsFromIndex {
        let manifest = try await contentIndexCoordinator.fetchTrustedManifest()
        guard !manifest.isEmpty else { return BackupContentRecordsFromIndex() }

        return BackupContentRecordsFromIndex(
            recordings: try await fetchBackupRecordsByRecordNames(
                Array(manifest.recordings).sorted(),
                expectedRecordType: Self.backupRecordingRecordType,
                desiredKeys: desiredKeys
            ),
            transcripts: try await fetchBackupRecordsByRecordNames(
                Array(manifest.transcripts).sorted(),
                expectedRecordType: Self.backupTranscriptRecordType,
                desiredKeys: desiredKeys
            ),
            summaries: try await fetchBackupRecordsByRecordNames(
                Array(manifest.summaries).sorted(),
                expectedRecordType: Self.backupSummaryRecordType,
                desiredKeys: desiredKeys
            )
        )
    }

    private func removeBackupRecordNamesFromContentIndex(
        recordingRecordNames: [String],
        transcriptRecordNames: [String],
        summaryRecordNames: [String]
    ) async throws {
        try await applyManifestDelta(
            .removing(
                recordings: Set(recordingRecordNames),
                transcripts: Set(transcriptRecordNames),
                summaries: Set(summaryRecordNames)
            )
        )
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

    /// Posted when the network comes back and durable work is still queued.
    static let networkRestoredNotification = Notification.Name("iCloudNetworkRestored")

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

    /// SummaryEntry has no `lastModified` of its own, so the backup writes this
    /// same value into both `generatedAt` and `lastModified` on the cloud record
    /// and the two dedupe rules line up. The one asymmetry is deliberate: where
    /// this returns nil the upload substitutes `Date()`, so a summary carrying
    /// neither timestamp sorts oldest locally but newest in the cloud for a
    /// single pass. The restore leg then writes that stamp back into the row and
    /// the two agree from the next cycle on.
    private func localSummaryContentTimestamp(_ summary: SummaryEntry) -> Date? {
        summary.generatedAt ?? summary.recording?.recordingDate
    }

    /// Attaches the recording's audio to its backup record when the stored signature
    /// does not match the file on disk. Returns true when a new asset was attached.
    /// Attaches the recording's audio when the file on disk differs from what the
    /// cloud record already holds.
    ///
    /// The asset is always built from an immutable staging copy: a recording that is
    /// still being written, or that the user deletes mid-upload, would otherwise
    /// fail the whole batch with `.assetFileModified`. A missing source skips the
    /// asset and keeps the metadata — audio must never be able to block metadata.
    private func attachAudioBackupIfNeeded(
        recording: RecordingEntry,
        to record: CKRecord,
        appCoordinator: AppDataCoordinator,
        staging: any CloudAssetStaging,
        includeAudioFiles: Bool,
        recorder: CloudSyncRunRecorder?,
        result: inout CloudBackupResult,
        changed: inout Bool
    ) -> Bool {
        let localURL = appCoordinator.getAbsoluteURL(for: recording)
        var sourceExists = false
        var signature: String?
        var byteCount: Int64 = 0
        if let localURL, FileManager.default.fileExists(atPath: localURL.path) {
            sourceExists = true
            signature = audioFileSignature(for: localURL)
            byteCount = (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? Int64 ?? 0
        }

        let decision = CloudAudioAssetPolicy.decide(
            includeAudioFiles: includeAudioFiles,
            sourceExists: sourceExists,
            localSignature: signature,
            cloudSignature: record[Self.fieldAudioSignature] as? String,
            byteCount: byteCount
        )

        switch decision {
        case .skippedUnchanged:
            result.audioFilesSkippedUnchanged += 1
            return false
        case .skippedDisabled, .skippedMissingSource:
            return false
        case .upload(let uploadByteCount, let uploadSignature):
            guard let localURL, let stagedURL = staging.stage(localURL) else {
                // The file went away between the check and the copy. Metadata still
                // uploads; the next run with the file present attaches the audio.
                return false
            }

            record[Self.fieldAudioAsset] = CKAsset(fileURL: stagedURL)
            changed = true
            updateStringField(Self.fieldAudioFileName, value: localURL.lastPathComponent, on: record, changed: &changed)
            updateInt64Field(Self.fieldAudioByteCount, value: uploadByteCount, on: record, changed: &changed)
            updateStringField(Self.fieldAudioSignature, value: uploadSignature, on: record, changed: &changed)
            recorder?.addAudio(fileCount: 1, byteCount: uploadByteCount, seconds: recording.duration)
            return true
        }
    }

    /// Brings the audio assets down for records that are about to be written to
    /// disk. The snapshot deliberately arrives without them.
    private func recordingRecordsWithAudioAssets(_ records: [CKRecord]) async throws -> [CKRecord] {
        let recordsMissingAssets = records.filter { record in
            record[Self.fieldAudioSignature] != nil && record[Self.fieldAudioAsset] == nil
        }
        guard !recordsMissingAssets.isEmpty else { return records }

        let outcome = try await cloudExecutor.fetch(recordsMissingAssets.map(\.recordID))
        recordMetrics(fetch: outcome)
        try outcome.throwIfIncomplete()

        return records.map { outcome.records[$0.recordID] ?? $0 }
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
        Self.isBackupRecordNewer(
            candidateTimestamp: backupRecordTimestamp(candidate, keys: timestampKeys),
            currentTimestamp: backupRecordTimestamp(current, keys: timestampKeys),
            candidateRecordName: candidate.recordID.recordName,
            currentRecordName: current.recordID.recordName
        )
    }

    /// What to do with a `SelectedAIEngine` value arriving from a settings backup.
    enum RestoredEngineSelection: Equatable {
        case accept
        case replace(String)
        case reject
    }

    /// Decides the fate of a restored engine selection.
    ///
    /// Rejecting the key whenever the backup came from the other platform drops
    /// selections that are perfectly valid on both — Mistral, Gemini, Compatible
    /// API, Apple Native — so support is judged per engine instead. Removed
    /// providers are mapped where a successor exists: an OpenAI selection is
    /// restored as Compatible API, which is where startup already migrates the
    /// matching credentials, rather than being discarded alongside them.
    static func resolveRestoredEngineSelection(_ selectedEngine: String) -> RestoredEngineSelection {
        if LegacyLlamaMigration.isLegacyEngineIdentifier(selectedEngine) {
            return .reject
        }

        // The removed cloud provider whose configuration survives under a new name.
        if selectedEngine.caseInsensitiveCompare("OpenAI") == .orderedSame {
            return .replace(AIEngineType.openAICompatible.rawValue)
        }

        guard let engine = AIEngineType(rawValue: selectedEngine) else {
            // AWS Bedrock and anything else this build no longer knows about.
            return .reject
        }

        return engine.isSupportedOnCurrentPlatform ? .accept : .reject
    }

    /// Whether a restored row should become the one the recording points at.
    /// Shared by the transcript and summary restore legs.
    ///
    /// The restore leg matches cloud rows to local rows by id, so a row
    /// carrying a *different* id has no local counterpart to arbitrate against and
    /// would otherwise be linked unconditionally. That is the delete-and-retranscribe
    /// (or delete-and-regenerate-summary) case: one device replaced its child row,
    /// another still holds the old backup, and relinking would point the recording
    /// at the older content and strand the newer row for the duplicate prune to collect.
    ///
    /// Same id always relinks — it is the row already in place. Otherwise the newer
    /// content timestamp wins, and an unknown timestamp on either side defers to the
    /// existing link rather than guessing.
    static func shouldRelinkRestoredRow(
        candidateId: UUID,
        candidateTimestamp: Date?,
        linkedId: UUID?,
        linkedTimestamp: Date?
    ) -> Bool {
        guard let linkedId, linkedId != candidateId else { return true }
        guard let candidateTimestamp, let linkedTimestamp else { return false }
        return candidateTimestamp > linkedTimestamp
    }

    /// The cloud half of the "one row per recording" rule, kept separate from the
    /// CKRecord plumbing so it can be tested directly against its local counterpart
    /// in `latestPerRecording`. The two must pick the same winner from the same
    /// facts, or devices trade uploads and deletions forever.
    ///
    /// Record names are the row identifier behind a per-type constant prefix, so
    /// ordering them is equivalent to ordering the identifiers themselves.
    static func isBackupRecordNewer(
        candidateTimestamp: Date,
        currentTimestamp: Date,
        candidateRecordName: String,
        currentRecordName: String
    ) -> Bool {
        if candidateTimestamp != currentTimestamp {
            return candidateTimestamp > currentTimestamp
        }

        // Deterministic tie-breaker for equal timestamps.
        return candidateRecordName > currentRecordName
    }

    private func backupRecordTimestamp(_ record: CKRecord, keys: [String]) -> Date {
        for key in keys {
            if let value = record[key] as? Date {
                return value
            }
        }
        return Date.distantPast
    }

    private func deleteBackupRecords(_ recordIDs: [CKRecord.ID]) async throws {
        guard !recordIDs.isEmpty else { return }
        let outcome = try await cloudExecutor.delete(recordIDs)
        recordMetrics(modify: outcome)
        try outcome.throwIfIncomplete()
    }

    private func deleteBackupRecord(_ recordID: CKRecord.ID) async throws {
        try await deleteBackupRecords([recordID])
    }

    private func saveBackupRecord(_ record: CKRecord) async throws {
        try await saveBackupRecords([record])
    }

    /// Saves a collection in batches and resolves `.serverRecordChanged` per record.
    ///
    /// Only the records that conflicted are sent again — a batch is never replayed
    /// because one item in it lost a race. The conflict itself is decided by the
    /// same newest-content-wins rule the backup leg uses, so a server copy that is
    /// newer than ours is a successful skip rather than an overwrite.
    /// - Returns: what CloudKit holds for these records afterwards — the copies
    ///   this device wrote, plus the server's copy wherever it turned out to be
    ///   newer than ours. The caller folds that into the run's snapshot, so the
    ///   restore leg applies a winning remote edit in the same pass instead of
    ///   carrying our stale local copy forward.
    @discardableResult
    private func saveBackupRecords(_ records: [CKRecord]) async throws -> [CKRecord] {
        guard !records.isEmpty else { return [] }

        var pending = records
        var settled: [CKRecord.ID: CKRecord] = [:]
        var attempt = 0

        while !pending.isEmpty {
            let outcome = try await cloudExecutor.save(pending)
            recordMetrics(modify: outcome)

            for (recordID, savedRecord) in outcome.saved {
                settled[recordID] = savedRecord
            }

            if let failure = outcome.failures.values.first {
                if let ckError = failure as? CKError,
                   let recordType = pending.first?.recordType,
                   let schemaError = cloudBackupProductionSchemaError(from: ckError, recordType: recordType) {
                    AppLog.shared.iCloudSync(schemaError.localizedDescription, level: .error)
                    throw schemaError
                }
                AppLog.shared.iCloudSync(
                    "CloudKit save failed: \(failure.localizedDescription)",
                    level: .error
                )
                throw failure
            }

            // A deferred save reached nobody. Returning here would let the caller
            // record the upload as done and skip it on the next activation.
            try outcome.throwIfIncomplete()

            guard !outcome.conflicts.isEmpty else { return Array(settled.values) }

            attempt += 1
            guard attempt <= maxRetryAttempts else {
                // These records are still unsent. Returning the ones that settled
                // would let the run commit its manifest and backup signature, and a
                // matching signature would then skip the unsent edit forever.
                AppLog.shared.iCloudSync(
                    "Gave up rebasing \(outcome.conflicts.count) record(s) another device kept changing",
                    level: .error
                )
                throw CloudSyncUnsettledRecordsError(recordCount: outcome.conflicts.count)
            }

            let byRecordID = Dictionary(uniqueKeysWithValues: pending.map { ($0.recordID, $0) })
            var retryRecords: [CKRecord] = []
            for (recordID, serverRecord) in outcome.conflicts {
                guard let localRecord = byRecordID[recordID] else { continue }
                if let rebased = resolveSaveConflict(local: localRecord, server: serverRecord) {
                    retryRecords.append(rebased)
                } else {
                    // The server's copy won. It, not our unsent local record, is
                    // what the cloud holds for this id.
                    settled[recordID] = serverRecord
                }
            }
            pending = retryRecords
        }

        return Array(settled.values)
    }

    /// Rebases one conflicted save onto the server's current record.
    /// Returns `nil` when the server's copy wins and nothing should be sent.
    private func resolveSaveConflict(local: CKRecord, server: CKRecord) -> CKRecord? {
        if local.recordType == Self.backupDeletionRecordType {
            // A deletion marker records when the user deleted, not when the marker
            // reached CloudKit, so the earliest claim survives a conflict.
            let requested = local[Self.fieldDeletedAt] as? Date ?? Date()
            let resolved = Self.resolvedDeletionTimestamp(
                existing: server[Self.fieldDeletedAt] as? Date,
                requested: requested
            )
            mergeBackupRecordFields(from: local, into: server)
            server[Self.fieldDeletedAt] = resolved
            return server
        }

        guard let timestampKeys = Self.contentTimestampKeys(for: local.recordType) else {
            mergeBackupRecordFields(from: local, into: server)
            return server
        }

        let localTimestamp = backupRecordContentTimestamp(local, keys: timestampKeys)
        let serverTimestamp = backupRecordContentTimestamp(server, keys: timestampKeys)
        guard Self.shouldUploadLocalVersion(
            localTimestamp: localTimestamp,
            cloudTimestamp: serverTimestamp
        ) else {
            // Another device holds a newer edit. Leaving it alone is the correct
            // outcome, not a failure — the restore leg brings it down.
            AppLog.shared.iCloudSync(
                "Kept a newer iCloud version of \(local.recordType) during save",
                level: .debug
            )
            return nil
        }

        mergeBackupRecordFields(from: local, into: server)
        return server
    }

    private static func contentTimestampKeys(for recordType: String) -> [String]? {
        switch recordType {
        case backupRecordingRecordType:
            return recordingContentTimestampKeys
        case backupTranscriptRecordType:
            return transcriptContentTimestampKeys
        case backupSummaryRecordType:
            return summaryContentTimestampKeys
        default:
            return nil
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

    /// CloudKit refuses a fetch-everything query unless the record type carries a
    /// QUERYABLE index on `recordName`. Saving records creates the type but never
    /// the index, so a container can hold data that cannot be listed.
    static func isMissingQueryableIndexDiagnostic(_ diagnosticText: String) -> Bool {
        let normalized = diagnosticText.lowercased()
        return normalized.contains("not queryable") || normalized.contains("not marked queryable")
    }

    static let missingQueryableIndexErrorCode = 4013

    /// Names the one thing that fixes this, because the raw CloudKit string does
    /// not: the index has to be added per record type in the CloudKit Console.
    static func cloudBackupQueryableIndexError(recordType: String) -> NSError {
        NSError(
            domain: "iCloudStorageManager",
            code: missingQueryableIndexErrorCode,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "iCloud sync cannot list \(recordType) records because that record type has no " +
                    "queryable index on recordName.",
                NSLocalizedRecoverySuggestionErrorKey:
                    "In the CloudKit Console, open Schema › Indexes for \(recordType) and add a " +
                    "QUERYABLE index on recordName, then deploy the schema to production. " +
                    "Deletions made on other devices cannot be seen until this exists."
            ]
        )
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
            recordID: recordID)

        record[Self.fieldSettingsPayload] = payloadData
        record[Self.fieldSettingsIncludesSensitive] = payload.includesSensitiveValues
        record[Self.fieldSettingsSchemaVersion] = Self.backupSchemaVersion
        record[Self.fieldSettingsUpdatedAt] = Date()
        record[Self.fieldDeviceIdentifier] = deviceIdentifier

        try await saveBackupRecord(record)
        return (true, payload.includesSensitiveValues)
    }

    private func restoreSettingsFromiCloud() async throws -> (restored: Bool, includedSensitiveSettings: Bool) {
        let recordID = CKRecord.ID(recordName: Self.backupSettingsRecordName)

        do {
            let outcome = try await cloudExecutor.fetch([recordID])
            recordMetrics(fetch: outcome)
            try outcome.throwIfIncomplete()
            guard let record = outcome.records[recordID] else {
                return (false, false)
            }
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
        if key == "SelectedAIEngine", let selectedEngine = rawValue as? String {
            switch Self.resolveRestoredEngineSelection(selectedEngine) {
            case .accept:
                return rawValue
            case .replace(let replacement):
                AppLog.shared.iCloudSync(
                    "Restored engine selection '\(selectedEngine)' as '\(replacement)'",
                    level: .debug
                )
                return replacement
            case .reject:
                AppLog.shared.iCloudSync(
                    "Skipped restoring unsupported engine selection '\(selectedEngine)'",
                    level: .debug
                )
                return nil
            }
        }

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

        return !Self.ollamaSettingsKeys.contains(key)
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
