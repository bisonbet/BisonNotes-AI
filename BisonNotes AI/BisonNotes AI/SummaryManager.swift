import Foundation

// MARK: - Engine Availability Status

struct EngineAvailabilityStatus {
    let name: String
    let description: String
    let isAvailable: Bool
    let isComingSoon: Bool
    let requirements: [String]
    let version: String
    let isCurrentEngine: Bool

    var statusMessage: String {
        if isCurrentEngine {
            return "Currently Active"
        } else if isAvailable {
            return "Available"
        } else if isComingSoon {
            return "Coming Soon"
        } else {
            return "Not Available"
        }
    }

    var statusColor: String {
        if isCurrentEngine {
            return "green"
        } else if isAvailable {
            return "blue"
        } else if isComingSoon {
            return "orange"
        } else {
            return "red"
        }
    }
}

struct LegacySummaryMigrationReport: Equatable, Sendable {
    let decodedCount: Int
    let migratedCount: Int
    let preservedExistingCount: Int
    let unresolvedCount: Int
    let failedCount: Int
    let didComplete: Bool
    let didRemoveLegacyData: Bool

    init(
        decodedCount: Int,
        migratedCount: Int,
        preservedExistingCount: Int = 0,
        unresolvedCount: Int,
        failedCount: Int,
        didComplete: Bool,
        didRemoveLegacyData: Bool = false
    ) {
        self.decodedCount = decodedCount
        self.migratedCount = migratedCount
        self.preservedExistingCount = preservedExistingCount
        self.unresolvedCount = unresolvedCount
        self.failedCount = failedCount
        self.didComplete = didComplete
        self.didRemoveLegacyData = didRemoveLegacyData
    }
}

@MainActor
func extractTasksAndRemindersFromCompleteResult(
    using engine: SummarizationEngine,
    text: String
) async throws -> (tasks: [TaskItem], reminders: [ReminderItem]) {
    let result = try await engine.processComplete(text: text)
    return (tasks: result.tasks, reminders: result.reminders)
}

@MainActor
class SummaryManager: ObservableObject {
    // MARK: - Shared Instance
    static let shared = SummaryManager()

    static let legacySummariesKey = "SavedEnhancedSummaries"
    static let legacyMigrationVersionKey = "SavedEnhancedSummariesMigrationVersion"
    static let legacyMigrationVersion = 1

    // MARK: - Enhanced Summarization Integration

    private var currentEngine: SummarizationEngine?
    private var availableEngines: [String: SummarizationEngine] = [:]
    private weak var appCoordinator: AppDataCoordinator?
    private lazy var fallbackCoreDataManager = CoreDataManager()
    // Task and Reminder Extractors for enhanced processing
    private let taskExtractor = TaskExtractor()
    private let reminderExtractor = ReminderExtractor()

    // MARK: - Background Task Management

    /// Background task ID for keeping summarization alive when the app is backgrounded.
    /// Cloud AI calls (Gemini, Mistral, and compatible APIs) use network requests that iOS will
    /// terminate after ~30s without a background task.
    private var summaryBackgroundTaskID: PlatformBackgroundTask.ID = .invalid

    // MARK: - Error Handling Integration

    private let errorHandler = ErrorHandler()
    @Published var currentError: AppError?
    @Published var showingErrorAlert = false

    // MARK: - iCloud Integration

    private let iCloudManager = iCloudStorageManager.shared

    private init() {
        initializeEngines()
    }

    func configure(with coordinator: AppDataCoordinator) {
        appCoordinator = coordinator
    }

    func getAuthoritativeSummaryData() -> [EnhancedSummaryData] {
        authoritativeCoreDataManager.getAllSummaryData()
    }

    private var authoritativeCoreDataManager: CoreDataManager {
        appCoordinator?.coreDataManager ?? fallbackCoreDataManager
    }

    @discardableResult
    private func persistSummaryIfPossible(_ summary: EnhancedSummaryData) -> EnhancedSummaryData? {
        let coreDataManager = authoritativeCoreDataManager
        guard let recordingId = summary.recordingId ?? coreDataManager.getRecording(url: summary.recordingURL)?.id else {
            AppLog.shared.summarization(
                "Cannot persist summary \(summary.id): no matching Core Data recording",
                level: .error
            )
            return nil
        }

        do {
            try coreDataManager.upsertSummary(
                summary,
                for: recordingId,
                transcriptId: summary.transcriptId
            )
            return coreDataManager.getSummaryData(for: recordingId)
        } catch {
            AppLog.shared.summarization("Failed to persist summary \(summary.id): \(error)", level: .error)
            return nil
        }
    }

    @discardableResult
    func migrateLegacySummaries(from data: Data, using coordinator: AppDataCoordinator) -> LegacySummaryMigrationReport {
        let legacySummaries: [EnhancedSummaryData]
        do {
            legacySummaries = try JSONDecoder().decode([EnhancedSummaryData].self, from: data)
        } catch {
            AppLog.shared.summarization("Failed to decode legacy enhanced summaries: \(error)", level: .error)
            return LegacySummaryMigrationReport(
                decodedCount: 0,
                migratedCount: 0,
                unresolvedCount: 0,
                failedCount: 1,
                didComplete: false
            )
        }

        guard !legacySummaries.isEmpty else {
            return LegacySummaryMigrationReport(
                decodedCount: 0,
                migratedCount: 0,
                unresolvedCount: 0,
                failedCount: 0,
                didComplete: true
            )
        }

        var migratedCount = 0
        var preservedExistingCount = 0
        var unresolvedCount = 0
        var failedCount = 0

        for legacySummary in legacySummaries {
            let recording: RecordingEntry?
            if let recordingId = legacySummary.recordingId {
                // A supplied UUID is authoritative. Do not silently map a stale UUID to a
                // different recording just because their filenames happen to match.
                recording = coordinator.getRecording(id: recordingId)
            } else {
                // URL matching is only a compatibility path for older records without UUIDs.
                recording = coordinator.getRecording(url: legacySummary.recordingURL)
            }

            guard let recording, let recordingId = recording.id else {
                unresolvedCount += 1
                AppLog.shared.summarization(
                    "Retaining legacy summary \(legacySummary.id.uuidString): no matching recording",
                    level: .error
                )
                continue
            }

            if let existingSummary = coordinator.getSummary(for: recordingId),
               let existingSummaryId = existingSummary.id,
               existingSummaryId != legacySummary.id
                || (existingSummary.generatedAt ?? .distantPast) > legacySummary.generatedAt {
                preservedExistingCount += 1
                AppLog.shared.summarization(
                    "Preserving existing Core Data summary for recording \(recordingId.uuidString) during legacy migration",
                    level: .debug
                )
                continue
            }

            do {
                let transcriptId = legacySummary.transcriptId ?? recording.transcriptId
                try coordinator.coreDataManager.upsertSummary(
                    legacySummary,
                    for: recordingId,
                    transcriptId: transcriptId
                )
                migratedCount += 1

            } catch {
                failedCount += 1
                AppLog.shared.summarization(
                    "Failed to migrate legacy summary \(legacySummary.id.uuidString): \(error)",
                    level: .error
                )
            }
        }

        return LegacySummaryMigrationReport(
            decodedCount: legacySummaries.count,
            migratedCount: migratedCount,
            preservedExistingCount: preservedExistingCount,
            unresolvedCount: unresolvedCount,
            failedCount: failedCount,
            didComplete: unresolvedCount == 0 && failedCount == 0
        )
    }

    @discardableResult
    func migrateLegacySummariesIfNeeded(
        using coordinator: AppDataCoordinator,
        defaults: UserDefaults = .standard
    ) -> LegacySummaryMigrationReport {
        let hasLegacyData = defaults.data(forKey: Self.legacySummariesKey) != nil
        if defaults.integer(forKey: Self.legacyMigrationVersionKey) >= Self.legacyMigrationVersion,
           !hasLegacyData {
            return LegacySummaryMigrationReport(
                decodedCount: 0,
                migratedCount: 0,
                unresolvedCount: 0,
                failedCount: 0,
                didComplete: true
            )
        }

        guard let data = defaults.data(forKey: Self.legacySummariesKey) else {
            defaults.set(Self.legacyMigrationVersion, forKey: Self.legacyMigrationVersionKey)
            return LegacySummaryMigrationReport(
                decodedCount: 0,
                migratedCount: 0,
                unresolvedCount: 0,
                failedCount: 0,
                didComplete: true
            )
        }

        let report = migrateLegacySummaries(from: data, using: coordinator)
        guard report.didComplete else {
            // Keep both the legacy payload and the marker unset so a later launch can retry
            // unresolved or failed items without duplicating summaries already upserted.
            return report
        }

        // Delete the payload first. If the process stops before the marker is written, the next
        // launch sees no payload and safely records completion instead of losing data.
        defaults.removeObject(forKey: Self.legacySummariesKey)
        defaults.set(Self.legacyMigrationVersion, forKey: Self.legacyMigrationVersionKey)

        return LegacySummaryMigrationReport(
            decodedCount: report.decodedCount,
            migratedCount: report.migratedCount,
            preservedExistingCount: report.preservedExistingCount,
            unresolvedCount: report.unresolvedCount,
            failedCount: report.failedCount,
            didComplete: true,
            didRemoveLegacyData: true
        )
    }

    // MARK: - iCloud Access Methods

    func getiCloudManager() -> iCloudStorageManager {
        return iCloudManager
    }

    func showUnsupportedDeviceAlert() {
        let error = AppError.system(.configurationError(message: "The selected AI engine is not supported on this device. Please select another AI engine in Settings."))
        handleError(error, context: "Unsupported Device")
    }

    // MARK: - Engine Management

    func initializeEngines() {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("Initializing AI engines using AIEngineFactory...", level: .debug)
        }

        // Clear any existing engines
        availableEngines.removeAll()

        // Get all engine types from the factory
        let allEngineTypes = AIEngineFactory.getAllEngines()
        var successfullyInitialized = 0

        for engineType in allEngineTypes {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Initializing \(engineType.rawValue)...", level: .debug)
            }

            // Create engine using the factory
            let engine = AIEngineFactory.createEngine(type: engineType)

            // Key by AIEngineType.rawValue to match UserDefaults "SelectedAIEngine" values
            availableEngines[engineType.rawValue] = engine

            // Only log successful initialization if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Successfully initialized \(engine.name) (Available: \(engine.isAvailable))", level: .debug)
            }
            successfullyInitialized += 1

            // Don't set any engine as current during initialization - wait for UserDefaults restoration
        }

        // Only log detailed engine lists if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("Available engines: \(getAvailableEnginesOnly())", level: .debug)
            AppLog.shared.summarization("Coming soon engines: \(getComingSoonEngines())", level: .debug)
        }

        // Now restore the user's selected engine from UserDefaults or set default
        let savedEngineName = UserDefaults.standard.string(forKey: "SelectedAIEngine")

        if let savedEngineName = savedEngineName,
           let savedEngine = availableEngines[savedEngineName],
           savedEngine.isAvailable {
            // User has a saved preference and the engine is available
            currentEngine = savedEngine
        } else if let savedEngineName = savedEngineName,
                  let savedEngine = availableEngines[savedEngineName],
                  !savedEngine.isAvailable {
            // User has a saved preference but the engine is not available
            // Try to find an available alternative, but don't overwrite their preference
            if let availableEngine = availableEngines.values.first(where: { $0.isAvailable }) {
                currentEngine = availableEngine
                AppLog.shared.summarization("Saved engine '\(savedEngineName)' not available, using '\(availableEngine.name)' temporarily", level: .default)
            }
        } else if savedEngineName == nil {
            // No saved preference, try to set MLX (the new on-device default)
            if let defaultEngine = availableEngines[AIEngineType.mlxSwift.rawValue], defaultEngine.isAvailable {
                currentEngine = defaultEngine
                UserDefaults.standard.set(defaultEngine.engineType, forKey: "SelectedAIEngine")
                AppLog.shared.summarization("No saved preference, set MLX as default engine")
            } else {
                // Try to find any available engine
                if let anyAvailableEngine = availableEngines.values.first(where: { $0.isAvailable && $0.name != "None" }) {
                    currentEngine = anyAvailableEngine
                    UserDefaults.standard.set(anyAvailableEngine.engineType, forKey: "SelectedAIEngine")
                    AppLog.shared.summarization("On-Device AI not available, using '\(anyAvailableEngine.name)' as default")
                } else {
                    // Last resort: set to None
                    UserDefaults.standard.set("None", forKey: "SelectedAIEngine")
                    AppLog.shared.summarization("No engines available, setting default engine to None")
                }
            }
        }

        // Ensure we have at least one working engine if one is selected
        if let engineName = UserDefaults.standard.string(forKey: "SelectedAIEngine"), engineName != "None" {
            if currentEngine == nil {
                AppLog.shared.summarization("No available engines found, attempting to find any available engine", level: .default)
                if let fallbackEngine = availableEngines.values.first(where: { $0.isAvailable && $0.name != "None" }) {
                    currentEngine = fallbackEngine
                    AppLog.shared.summarization("Set \(fallbackEngine.name) as fallback engine")

                    if Self.shouldPersistFallbackSelection(
                        savedEngineName: engineName,
                        knownEngineNames: Set(availableEngines.keys),
                        removedProviderMigrationCompleted: UserDefaults.standard.bool(
                            forKey: AppSettingsKeys.removedProviderSelectionsMigrated
                        )
                    ) {
                        UserDefaults.standard.set(fallbackEngine.engineType, forKey: "SelectedAIEngine")
                        AppLog.shared.summarization(
                            "Replaced unrecognized engine selection '\(engineName)' with '\(fallbackEngine.name)'"
                        )
                    }
                }
            }
        }

        AppLog.shared.summarization(
            "AI engines ready: \(successfullyInitialized)/\(allEngineTypes.count) initialized; " +
            "active engine: \(getCurrentEngineName())"
        )
    }

    /// Whether a persisted engine selection should be rewritten to the engine
    /// actually in use.
    ///
    /// A name the app still recognizes is left alone even when that engine is
    /// temporarily unavailable — it is the user's preference and can become
    /// valid again once the server is reachable or the key is entered. A name
    /// no build recognizes never will: it names a removed provider, usually
    /// arriving by way of an iCloud settings restore from an older build. Left
    /// in place it strands every reader that keys off the raw string, because
    /// their `?? default` never fires for a non-nil value.
    ///
    /// The exception is timing. This registry is built on first access to
    /// `SummaryManager.shared`, which can happen before the launch migrations
    /// run, and until they have run an unrecognized name may still be a removed
    /// provider they can map to a successor — "OpenAI" becomes Compatible API
    /// with its credentials intact. Overwriting it first would destroy the only
    /// evidence of what the user had. So the rewrite waits for them.
    nonisolated static func shouldPersistFallbackSelection(
        savedEngineName: String?,
        knownEngineNames: Set<String>,
        removedProviderMigrationCompleted: Bool
    ) -> Bool {
        guard let savedEngineName, savedEngineName != "None" else { return false }
        guard !knownEngineNames.contains(savedEngineName) else { return false }
        return removedProviderMigrationCompleted
    }

    func setEngine(_ engineName: String) {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("Setting engine to '\(engineName)'", level: .debug)
        }

        // Validate the engine using the new validation method
        let validation = validateEngineAvailability(engineName)

        guard validation.isValid else {
            AppLog.shared.summarization("\(validation.errorMessage ?? "Invalid engine")", level: .default)
            return
        }

        guard validation.isAvailable else {
            AppLog.shared.summarization("\(validation.errorMessage ?? "Engine not available")", level: .default)
            return
        }

        // Get or create the engine
        var targetEngine: SummarizationEngine?

        if let existingEngine = availableEngines[engineName] {
            targetEngine = existingEngine
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Using existing engine '\(engineName)'", level: .debug)
            }
        } else {
            // Create the engine using the factory
            if let engineType = AIEngineType.allCases.first(where: { $0.rawValue == engineName }) {
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLog.shared.summarization("Creating new engine '\(engineName)' using factory", level: .debug)
                }
                let newEngine = AIEngineFactory.createEngine(type: engineType)
                availableEngines[engineType.rawValue] = newEngine
                targetEngine = newEngine
            }
        }

        // Set the engine if we have one and it's available
        if let engine = targetEngine, engine.isAvailable {
            currentEngine = engine

            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Engine set successfully to '\(engine.name)'", level: .debug)
            }

            // Save the selected engine to UserDefaults for persistence
            UserDefaults.standard.set(engineName, forKey: "SelectedAIEngine")

            // Notify observers of the engine change
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        } else {
            AppLog.shared.summarization("Failed to set engine '\(engineName)' - engine not available", level: .default)
            if let engine = targetEngine {
                AppLog.shared.summarization("Engine details: \(engine.description) (Available: \(engine.isAvailable))", level: .debug)
            }
        }
    }

    func updateEngineConfiguration(_ engineName: String) {
        AppLog.shared.summarization("Updating configuration for engine '\(engineName)'", level: .debug)

        // Find the engine type for the given name
        guard let engineType = AIEngineType.allCases.first(where: { $0.rawValue == engineName }) else {
            AppLog.shared.summarization("Unknown engine type for '\(engineName)'", level: .error)
            return
        }

        // Recreate the engine with updated configuration using the factory
        let updatedEngine = AIEngineFactory.createEngine(type: engineType)
        availableEngines[engineType.rawValue] = updatedEngine

        // If this was the current engine, update the reference
        if currentEngine?.engineType == engineName {
            currentEngine = updatedEngine
            AppLog.shared.summarization("Updated current engine configuration for '\(engineName)'", level: .debug)
        }

        AppLog.shared.summarization("Engine configuration updated for '\(engineName)' (Available: \(updatedEngine.isAvailable))")
    }

    // MARK: - Engine Validation and Status

    func validateEngineAvailability(_ engineName: String) -> (isValid: Bool, isAvailable: Bool, errorMessage: String?) {
        // Check if engine name is valid
        guard !engineName.isEmpty else {
            return (false, false, "Engine name cannot be empty")
        }

        // Check if engine type exists
        guard AIEngineType.allCases.contains(where: { $0.rawValue == engineName }) else {
            let validEngines = AIEngineType.allCases.map { $0.rawValue }.sorted().joined(separator: ", ")
            return (false, false, "Unknown engine type '\(engineName)'. Valid engines: \(validEngines)")
        }

        // Check if engine is initialized
        if let engine = availableEngines[engineName] {
            if engine.isAvailable {
                return (true, true, nil)
            } else {
                let engineType = AIEngineType.allCases.first { $0.rawValue == engineName }
                let requirements = engineType?.requirements.joined(separator: ", ") ?? "Unknown requirements"
                return (true, false, "Engine '\(engineName)' is not available. Requirements: \(requirements)")
            }
        } else {
            // Engine not initialized, try to create it
            if let engineType = AIEngineType.allCases.first(where: { $0.rawValue == engineName }) {
                let testEngine = AIEngineFactory.createEngine(type: engineType)
                if testEngine.isAvailable {
                    return (true, true, nil)
                } else {
                    let requirements = engineType.requirements.joined(separator: ", ")
                    return (true, false, "Engine '\(engineName)' is not available. Requirements: \(requirements)")
                }
            }
        }

        return (false, false, "Unknown error validating engine '\(engineName)'")
    }

    func getCurrentEngineName() -> String {
        guard let engine = currentEngine else {
            AppLog.shared.summarization("No current engine set", level: .default)
            return "None"
        }

        // Verify the engine is still available
        if !engine.isAvailable {
            AppLog.shared.summarization("Current engine '\(engine.name)' is no longer available", level: .default)
            // Try to find an available fallback engine, but don't overwrite user's preference
            if let fallbackEngine = availableEngines.values.first(where: { $0.isAvailable }) {
                AppLog.shared.summarization("Using fallback engine '\(fallbackEngine.name)' temporarily", level: .debug)
                currentEngine = fallbackEngine
                // Don't overwrite the user's saved preference - they may want to use their selected engine when it becomes available again
                return fallbackEngine.name
            }
        }

        return engine.name
    }

    private func syncCurrentEngineWithSettings() {
        let selectedEngineName = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? AIEngineType.mlxSwift.rawValue

        // If current engine doesn't match the selected engine, update it
        if currentEngine?.engineType != selectedEngineName {
            if let selectedEngine = availableEngines[selectedEngineName], selectedEngine.isAvailable {
                currentEngine = selectedEngine
                AppLog.shared.summarization("Synced current engine to '\(selectedEngineName)' from settings", level: .debug)
            } else {
                AppLog.shared.summarization("Selected engine '\(selectedEngineName)' not available, keeping current engine", level: .default)
            }
        }
    }

    func getAvailableEnginesOnly() -> [String] {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLog.shared.summarization("Checking available engines...", level: .debug)
        }

        // Get all engine types and check their real-time availability
        let allEngineTypes = AIEngineFactory.getAllEngines()
        var availableEngines: [String] = []

        for engineType in allEngineTypes {
            let engine = AIEngineFactory.createEngine(type: engineType)

            // Perform real-time availability check
            if engine.isAvailable {
                availableEngines.append(engineType.rawValue)
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                    AppLog.shared.summarization("\(engineType.rawValue) is available", level: .debug)
                }
            } else {
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                    AppLog.shared.summarization("\(engineType.rawValue) is not available", level: .debug)
                }
            }
        }

        let sortedEngines = availableEngines.sorted()

        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLog.shared.summarization("Available engines: \(sortedEngines)", level: .debug)
        }

        return sortedEngines
    }

    func getComingSoonEngines() -> [String] {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLog.shared.summarization("Checking coming soon engines...", level: .debug)
        }

        // Get all engine types
        let allEngineTypes = AIEngineFactory.getAllEngines()
        let availableEngineNames = Set(getAvailableEnginesOnly())

        // Filter out available engines to find coming soon engines
        let comingSoonEngines = allEngineTypes
            .map { $0.rawValue }
            .filter { !availableEngineNames.contains($0) }
            .sorted()

        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLog.shared.summarization("Coming soon engines: \(comingSoonEngines)", level: .debug)
        }

        return comingSoonEngines
    }

    // MARK: - Real-time Availability Checking

    func checkEngineAvailability(_ engineName: String) async -> (isAvailable: Bool, errorMessage: String?) {
        AppLog.shared.summarization("Checking real-time availability for '\(engineName)'", level: .debug)

        // Validate engine name first
        let validation = validateEngineAvailability(engineName)
        guard validation.isValid else {
            return (false, validation.errorMessage)
        }

        // Get the engine type
        guard let engineType = AIEngineType.allCases.first(where: { $0.rawValue == engineName }) else {
            return (false, "Unknown engine type")
        }

        // Create engine instance and check availability
        let engine = AIEngineFactory.createEngine(type: engineType)

        // Check basic availability first
        let isAvailable = engine.isAvailable
        AppLog.shared.summarization("\(engineName) basic availability: \(isAvailable)", level: .debug)

        if !isAvailable {
            return (false, "Engine not available")
        }

        // For engines that support connection testing, perform additional checks
        if engineName.contains("Compatible") || engineName.contains("Ollama") {
            // Try to perform a connection test if the engine supports it
            if let testableEngine = engine as? (any SummarizationEngine & ConnectionTestable) {
                let isConnected = await testableEngine.testConnection()
                if isConnected {
                    AppLog.shared.summarization("\(engineName) connection test successful")
                    return (true, nil)
                } else {
                    AppLog.shared.summarization("\(engineName) connection test failed", level: .error)
                    return (false, "Connection test failed")
                }
            } else {
                // Engine doesn't support connection testing, rely on basic availability
                AppLog.shared.summarization("\(engineName) doesn't support connection testing", level: .debug)
                return (isAvailable, nil)
            }
        } else {
            // For local engines like On-Device AI, just check basic availability
            return (isAvailable, nil)
        }
    }

    // MARK: - Enhanced Summary Generation

    func generateEnhancedSummary(from text: String, for recordingURL: URL, recordingName: String, recordingDate: Date, coordinator: AppDataCoordinator? = nil, engineName: String? = nil) async throws -> EnhancedSummaryData {
        // Sync engine from settings before logging to avoid "No current engine set" warning
        syncCurrentEngineWithSettings()
        AppLog.shared.summarization("Starting enhanced summary generation using \(getCurrentEngineName())")
        AppLog.shared.summarization(
            "Summary generation settings: detail=\(SummaryDetailLevel.current.displayName), comedy=\(ComedyMode.current.rawValue)",
            level: .debug
        )

        let startTime = Date()

        // Count words in the transcript
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0.count > 1 }

        // If transcript has 50 words or less, return it as-is as the summary
        if words.count <= 50 {
            AppLog.shared.summarization("Transcript has 50 words or less (\(words.count) words) - returning transcript as-is")

            let shortTranscriptSummary = EnhancedSummaryData(
                recordingURL: recordingURL,
                recordingName: recordingName,
                recordingDate: recordingDate,
                summary: "## Transcript\n\n\(text)",
                tasks: [],
                reminders: [],
                titles: [],
                contentType: .general,
                aiEngine: "Local Processing",
                aiModel: "Short Transcript (Displayed As-Is)",
                originalLength: words.count,
                processingTime: Date().timeIntervalSince(startTime)
            )

            AppLog.shared.summarization("Short transcript summary created and saved")
            return shortTranscriptSummary
        }

        // Validate input before processing for longer transcripts
        let validationResult = errorHandler.validateTranscriptForSummarization(text)
        if !validationResult.isValid {
            let validationError = SummarizationError.insufficientContent
            handleError(validationError, context: "Input Validation", recordingName: recordingName)
            throw validationError
        }

        // Begin a background task so cloud AI calls (Gemini, Mistral, etc.)
        // can complete even if the user backgrounds the app during summarization.
        beginSummaryBackgroundTask()
        defer { endSummaryBackgroundTask() }

        let engineToUse: SummarizationEngine?

        if let engineName = engineName, let engine = availableEngines[engineName], engine.isAvailable {
            engineToUse = engine
        } else {
            engineToUse = currentEngine
        }

        // Ensure we have a working engine
        guard let engine = engineToUse else {
            AppLog.shared.summarization("No AI engine available, falling back to basic processing", level: .default)
            let fallbackError = SummarizationError.aiServiceUnavailable(service: "No AI engines available")
            handleError(fallbackError, context: "Engine Availability", recordingName: recordingName)
            return try await generateBasicSummary(from: text, for: recordingURL, recordingName: recordingName, recordingDate: recordingDate, coordinator: coordinator)
        }

        AppLog.shared.summarization("Using engine: \(engine.name)")

        var result: SummarizationResult
        do {
            // Use the AI engine to process the complete text
            result = try await engine.processComplete(text: text)
        } catch {
            // If the task was cancelled, propagate CancellationError immediately — don't retry
            if Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                throw CancellationError()
            }
            // Don't retry content safety blocks — they'll just fail again
            if let sumError = error as? SummarizationError, case .contentSafetyBlock = sumError {
                throw sumError
            }
            // Truncation is deterministic and the engine already retried with a
            // larger output budget; another pass would fail the same way.
            if let sumError = error as? SummarizationError, case .responseTruncated = sumError {
                throw sumError
            }
            // Check for guardrail violations that weren't caught at the engine level
            let errorDesc = String(describing: error)
            if errorDesc.contains("guardrailViolation") || errorDesc.contains("unsafe content") {
                throw SummarizationError.contentSafetyBlock(engine: engine.name)
            }
            AppLog.shared.summarization("AI engine failed: \(error) - retrying once", level: .error)
            do {
                try Task.checkCancellation()
                result = try await engine.processComplete(text: text)
                AppLog.shared.summarization("AI engine retry succeeded")
            } catch {
                // If cancelled during retry, propagate CancellationError
                if Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                    throw CancellationError()
                }
                AppLog.shared.summarization("AI engine retry failed: \(error)", level: .error)

                // Handle the error and provide recovery options
                handleError(error, context: "Enhanced Summary Generation", recordingName: recordingName)

                // If the error is already a well-formed SummarizationError, re-throw it as-is
                // to avoid wrapping it in another layer of error messages
                if let summarizationError = error as? SummarizationError {
                    throw summarizationError
                }

                // Provide more specific error messages for Ollama
                if engine.name.contains("Ollama") {
                    if error.localizedDescription.contains("parsing") || error.localizedDescription.contains("JSON") {
                        throw SummarizationError.processingFailed(reason: "Ollama returned text that couldn't be parsed. Please check your Ollama model configuration or try a different model.")
                    } else if error.localizedDescription.contains("connection") || error.localizedDescription.contains("server") {
                        throw SummarizationError.networkError(underlying: error)
                    }
                }

                // Check for guardrail violations that weren't caught at the engine level
                let retryErrorDesc = String(describing: error)
                if retryErrorDesc.contains("guardrailViolation") || retryErrorDesc.contains("unsafe content") {
                    throw SummarizationError.contentSafetyBlock(engine: engine.name)
                }

                // STOP HERE - Don't fall back to basic summary automatically
                // Let the user decide what to do instead of silently switching engines
                throw SummarizationError.aiServiceUnavailable(service: engine.name)
            }
        }

        let processingTime = Date().timeIntervalSince(startTime)

        // Generate intelligent recording name using AI analysis
        let intelligentName = generateIntelligentRecordingName(
            from: text,
            contentType: result.contentType,
            tasks: result.tasks,
            reminders: result.reminders,
            titles: result.titles
        )

        // Use the intelligent name if it's better than the original
        let finalRecordingName = intelligentName.isEmpty || intelligentName == "Recording" ? recordingName : intelligentName

        let enhancedSummary = EnhancedSummaryData(
            recordingURL: recordingURL,
            recordingName: finalRecordingName,
            recordingDate: recordingDate,
            summary: result.summary,
            tasks: result.tasks,
            reminders: result.reminders,
            titles: result.titles,
            contentType: result.contentType,
            aiEngine: engine.engineType,
            aiModel: engine.metadataName,
            originalLength: text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
            processingTime: processingTime
        )

        // Validate summary quality
        let qualityReport = errorHandler.validateSummaryQuality(enhancedSummary)
        if qualityReport.qualityLevel == .unacceptable {
            AppLog.shared.summarization("Summary quality is unacceptable, attempting recovery", level: .default)
            handleError(SummarizationError.processingFailed(reason: "Summary quality below threshold"), context: "Summary Quality", recordingName: recordingName)
        }

        // Update the recording name if we generated a better one
        if finalRecordingName != recordingName {
            try await updateRecordingNameWithAI(
                from: recordingName,
                recordingURL: recordingURL,
                transcript: text,
                contentType: result.contentType,
                tasks: result.tasks,
                reminders: result.reminders,
                titles: result.titles,
                coordinator: coordinator
            )
        }

        AppLog.shared.summarization("Enhanced summary generated successfully")
        AppLog.shared.summarization("Summary length: \(result.summary.count) characters", level: .debug)
        AppLog.shared.summarization("Tasks extracted: \(result.tasks.count)", level: .debug)
        AppLog.shared.summarization("Reminders extracted: \(result.reminders.count)", level: .debug)
        AppLog.shared.summarization("Content type: \(result.contentType.rawValue)", level: .debug)
        AppLog.shared.summarization("Recording name: '\(finalRecordingName)'", level: .debug)
        AppLog.shared.summarization("Quality score: \(qualityReport.formattedScore)", level: .debug)

        return enhancedSummary
    }

    // MARK: - Background Task Helpers

    private func beginSummaryBackgroundTask() {
        guard summaryBackgroundTaskID == .invalid else { return }
        summaryBackgroundTaskID = PlatformBackgroundTask.begin(name: "AISummarization") { [weak self] in
            // Expiration handler — iOS is about to kill us
            AppLog.shared.summarization("Background task expiring for summarization", level: .default)
            Task { @MainActor [weak self] in
                self?.endSummaryBackgroundTask()
            }
        }
        if summaryBackgroundTaskID != .invalid {
            let remaining = PlatformBackgroundTask.remainingTime
            if remaining != Double.greatestFiniteMagnitude {
                AppLog.shared.summarization("Background task started - \(Int(remaining))s remaining", level: .debug)
            } else {
                AppLog.shared.summarization("Background task started - unlimited time (foreground or audio session active)", level: .debug)
            }
        }
    }

    private func endSummaryBackgroundTask() {
        guard summaryBackgroundTaskID != .invalid else { return }
        AppLog.shared.summarization("Ending summarization background task", level: .debug)
        PlatformBackgroundTask.end(summaryBackgroundTaskID)
        summaryBackgroundTaskID = .invalid
    }

    // MARK: - Fallback Basic Summary Generation

    private func generateBasicSummary(from text: String, for recordingURL: URL, recordingName: String, recordingDate: Date, coordinator: AppDataCoordinator?) async throws -> EnhancedSummaryData {
        AppLog.shared.summarization("Using basic fallback summarization with task/reminder extraction")

        let startTime = Date()

        // Count words in the transcript
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0.count > 1 }

        // If transcript has 50 words or less, return it as-is as the summary
        if words.count <= 50 {
            AppLog.shared.summarization("Transcript has 50 words or less (\(words.count) words) - returning transcript as-is")

            let shortTranscriptSummary = EnhancedSummaryData(
                recordingURL: recordingURL,
                recordingName: recordingName,
                recordingDate: recordingDate,
                summary: "## Transcript\n\n\(text)",
                tasks: [],
                reminders: [],
                titles: [],
                contentType: .general,
                aiEngine: "Local Processing",
            aiModel: "Short Transcript (Displayed As-Is)",
                originalLength: words.count,
                processingTime: Date().timeIntervalSince(startTime)
            )

            AppLog.shared.summarization("Short transcript summary created and saved")
            return shortTranscriptSummary
        }

        // Validate input for basic processing for longer transcripts
        let validationResult = errorHandler.validateTranscriptForSummarization(text)
        if !validationResult.isValid {
            let validationError = SummarizationError.insufficientContent
            handleError(validationError, context: "Basic Summary Input Validation", recordingName: recordingName)
            throw validationError
        }

        // Use ContentAnalyzer for content classification
        let contentType = ContentAnalyzer.classifyContent(text)
        let summary = createBasicSummary(from: text, contentType: contentType)

        // Extract tasks and reminders using dedicated extractors
        let (tasks, reminders) = try await extractTasksAndRemindersFromText(text)

        let processingTime = Date().timeIntervalSince(startTime)

        // Generate intelligent recording name using AI analysis
        let intelligentName = generateIntelligentRecordingName(
            from: text,
            contentType: contentType,
            tasks: tasks,
            reminders: reminders,
            titles: []
        )

        // Use the intelligent name if it's better than the original
        let finalRecordingName = intelligentName.isEmpty || intelligentName == "Recording" ? recordingName : intelligentName

        let enhancedSummary = EnhancedSummaryData(
            recordingURL: recordingURL,
            recordingName: finalRecordingName,
            recordingDate: recordingDate,
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            contentType: contentType,
            aiEngine: "Local Processing",
            aiModel: "Basic Extraction",
            originalLength: text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
            processingTime: processingTime
        )

        // Validate basic summary quality
        let qualityReport = errorHandler.validateSummaryQuality(enhancedSummary)
        if qualityReport.qualityLevel == SummaryQualityLevel.unacceptable {
            AppLog.shared.summarization("Basic summary quality is unacceptable", level: .default)
            handleError(SummarizationError.processingFailed(reason: "Basic summary quality below threshold"), context: "Basic Summary Quality", recordingName: recordingName)
        }

        // Update the recording name if we generated a better one
        if finalRecordingName != recordingName {
            try await updateRecordingNameWithAI(
                from: recordingName,
                recordingURL: recordingURL,
                transcript: text,
                contentType: contentType,
                tasks: tasks,
                reminders: reminders,
                titles: [],
                coordinator: coordinator
            )
        }

        AppLog.shared.summarization("Basic summary with extraction completed")
        AppLog.shared.summarization("Tasks extracted: \(tasks.count)", level: .debug)
        AppLog.shared.summarization("Reminders extracted: \(reminders.count)", level: .debug)
        AppLog.shared.summarization("Recording name: '\(finalRecordingName)'", level: .debug)
        AppLog.shared.summarization("Quality score: \(qualityReport.formattedScore)", level: .debug)

        return enhancedSummary
    }

    private func createBasicSummary(from text: String, contentType: ContentType) -> String {
        AppLog.shared.summarization("Creating content-type optimized summary for: \(contentType.rawValue)", level: .debug)

        // Use ContentAnalyzer for better sentence extraction and scoring with content-type optimization
        let sentences = ContentAnalyzer.extractSentences(from: text)

        if sentences.isEmpty {
            return "## Summary\n\n*No meaningful content found for summarization.*"
        }

        // Score sentences using ContentAnalyzer with content-type specific boosting
        let scoredSentences = sentences.enumerated().map { _, sentence in
            let baseImportance = ContentAnalyzer.calculateSentenceImportance(sentence, in: text)
            var boostedScore = baseImportance

            // Apply content-type specific boosting
            switch contentType {
            case .meeting:
                let meetingKeywords = ["decision", "action item", "follow up", "next step", "agreed", "consensus", "deadline", "schedule"]
                for keyword in meetingKeywords {
                    if sentence.lowercased().contains(keyword) {
                        boostedScore += 0.3
                    }
                }
            case .personalJournal:
                let reflectionKeywords = ["i feel", "i think", "i learned", "i realized", "i discovered", "my experience", "i believe"]
                for keyword in reflectionKeywords {
                    if sentence.lowercased().contains(keyword) {
                        boostedScore += 0.3
                    }
                }
            case .technical:
                let technicalKeywords = ["algorithm", "function", "method", "solution", "implementation", "architecture", "system", "code"]
                for keyword in technicalKeywords {
                    if sentence.lowercased().contains(keyword) {
                        boostedScore += 0.2
                    }
                }
            case .general:
                // No additional boosting for general content
                break
            }

            return (sentence: sentence, score: boostedScore)
        }

        // Select top sentences based on boosted importance score
        let topSentences = scoredSentences
            .sorted { $0.score > $1.score }
            .prefix(SummaryDetailLevel.current.basicSentenceLimit)
            .map { $0.sentence }

        if topSentences.isEmpty {
            return "## Summary\n\n*No meaningful content found for summarization.*"
        }

        // Create a markdown-formatted summary with content-type specific headers
        // Note: Removed redundant "Summary" labels since user is already in summary context
        let contentTypeHeader = switch contentType {
        case .meeting: "**Key Decisions & Action Items:**"
        case .personalJournal: "**Key Insights & Experiences:**"
        case .technical: "**Key Concepts & Solutions:**"
        case .general: "**Main Points:**"
        }

        // Format the top sentences as bullet points
        let bulletPoints = topSentences.map { sentence in
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return "• \(cleanSentence)"
        }.joined(separator: "\n")

        let summary = "\(contentTypeHeader)\n\n\(bulletPoints)"
        AppLog.shared.summarization("Content-type optimized summary created: \(summary.count) characters", level: .debug)

        return summary
    }

    // MARK: - Task and Reminder Extraction

    func extractTasksAndRemindersFromText(_ text: String) async throws -> (tasks: [TaskItem], reminders: [ReminderItem]) {
        AppLog.shared.summarization("Extracting tasks and reminders from text", level: .debug)

        if let engine = currentEngine {
            do {
                let result = try await extractTasksAndRemindersFromCompleteResult(
                    using: engine,
                    text: text
                )
                AppLog.shared.summarization(
                    "Extracted \(result.tasks.count) tasks and \(result.reminders.count) reminders",
                    level: .debug
                )
                return result
            } catch {
                AppLog.shared.summarization(
                    "Complete task and reminder extraction failed, using fallback extractors: \(error)",
                    level: .debug
                )
            }
        }

        let tasks = taskExtractor.extractTasks(from: text)
        let reminders = reminderExtractor.extractReminders(from: text)
        AppLog.shared.summarization(
            "Fallback extracted \(tasks.count) tasks and \(reminders.count) reminders",
            level: .debug
        )
        return (tasks, reminders)
    }

    // MARK: - Error Handling and Recovery

    func handleError(_ error: Error, context: String = "", recordingName: String = "") {
        AppLog.shared.summarization("Error in \(context): \(error.localizedDescription)", level: .error)

        let appError = AppError.from(error, context: context)

        // Log the error
        errorHandler.handle(appError, context: context, showToUser: false)

        // Update UI state
        DispatchQueue.main.async {
            self.currentError = appError
            self.showingErrorAlert = true
        }
    }

    // MARK: - Recording Name Management

    func generateIntelligentRecordingName(from text: String, contentType: ContentType, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem]) -> String {
        AppLog.shared.summarization("Generating intelligent recording name", level: .debug)

        // Use the RecordingNameGenerator to create a meaningful name
        let generatedName = RecordingNameGenerator.generateRecordingNameFromTranscript(
            text,
            contentType: contentType,
            tasks: tasks,
            reminders: reminders,
            titles: titles
        )

        // Validate and fix the generated name
        let validatedName = RecordingNameGenerator.validateAndFixRecordingName(generatedName, originalName: "Recording")

        AppLog.shared.summarization("Generated name: '\(validatedName)'", level: .debug)
        return validatedName
    }

    func updateRecordingNameWithAI(from oldName: String, recordingURL: URL, transcript: String, contentType: ContentType, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], coordinator: AppDataCoordinator?) async throws {
        AppLog.shared.summarization("Updating recording name using AI analysis", level: .debug)

        // Generate intelligent name using AI analysis
        let newName = generateIntelligentRecordingName(from: transcript, contentType: contentType, tasks: tasks, reminders: reminders, titles: titles)

        // Only update if the new name is different and meaningful
        if newName != oldName && !newName.isEmpty && newName != "Recording" {
            AppLog.shared.summarization("Updating name from '\(oldName)' to '\(newName)'", level: .debug)
            if let coordinator = coordinator {
                try await updateRecordingName(from: oldName, to: newName, recordingURL: recordingURL, coordinator: coordinator)
            } else {
                AppLog.shared.summarization("No coordinator provided, skipping Core Data update", level: .default)
            }

        } else {
            AppLog.shared.summarization("Keeping original name '\(oldName)' (no meaningful improvement found)", level: .debug)
        }
    }

    private func updateRecordingName(from oldName: String, to newName: String, recordingURL: URL, coordinator: AppDataCoordinator) async throws {
        AppLog.shared.summarization("Starting file rename process: '\(oldName)' -> '\(newName)'", level: .debug)

        // Get the recording from Core Data using the coordinator
        guard let recordingEntry = coordinator.getRecording(url: recordingURL),
              let recordingId = recordingEntry.id else {
            AppLog.shared.summarization("Could not find recording in Core Data for file: \(recordingURL.lastPathComponent)", level: .error)
            return
        }

        AppLog.shared.summarization("Found recording in Core Data with ID: \(recordingId)", level: .debug)

        // Use the Core Data workflow manager to update the recording name
        // This will handle both the Core Data update and file renaming
        coordinator.updateRecordingName(recordingId: recordingId, newName: newName)

        AppLog.shared.summarization("Recording name updated using Core Data workflow", level: .debug)

        // Notify UI to refresh recordings list
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("RecordingRenamed"),
                object: nil,
                userInfo: [
                    "oldName": oldName,
                    "newName": newName,
                    "oldURL": recordingURL,
                    "newURL": recordingURL // The URL will be updated by the workflow manager
                ]
            )
        }
    }

    // MARK: - Summary Validation and Statistics

    func validateSummary(_ summary: EnhancedSummaryData) -> [String] {
        var issues: [String] = []

        if summary.summary.isEmpty {
            issues.append("Summary is empty")
        }

        if summary.summary.count < 50 {
            issues.append("Summary is very short (less than 50 characters)")
        }

        if summary.confidence < 0.3 {
            issues.append("Low confidence score (\(String(format: "%.1f", summary.confidence * 100))%)")
        }

        if summary.tasks.isEmpty && summary.reminders.isEmpty {
            issues.append("No tasks or reminders extracted")
        }

        return issues
    }

    func getSummaryStatistics() -> SummaryStatistics {
        let summaries = getAuthoritativeSummaryData()
        let totalSummaries = summaries.count
        let averageConfidence = summaries.isEmpty ? 0.0 : summaries.map { $0.confidence }.reduce(0, +) / Double(totalSummaries)
        let averageCompressionRatio = summaries.isEmpty ? 0.0 : summaries.map { $0.compressionRatio }.reduce(0, +) / Double(totalSummaries)
        let totalTasks = summaries.reduce(0) { $0 + $1.tasks.count }
        let totalReminders = summaries.reduce(0) { $0 + $1.reminders.count }

        let engineUsage = Dictionary(grouping: summaries, by: { $0.aiModel })
            .mapValues { $0.count }

        return SummaryStatistics(
            totalSummaries: totalSummaries,
            averageConfidence: averageConfidence,
            averageCompressionRatio: averageCompressionRatio,
            totalTasks: totalTasks,
            totalReminders: totalReminders,
            engineUsage: engineUsage
        )
    }

}
