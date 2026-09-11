import CoreData
import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class CoreDataMigrationInputReaderRuntimeTests: XCTestCase {
    func testInputReaderCombinesMetadataAndInventoriedSettings() async throws {
        let storeURL = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("BisonNotesCoreDataMigrationInput-\(UUID().uuidString).sqlite")
        let container = try makeContainer(at: storeURL)
        let suiteName = "BisonNotesCoreDataMigrationInput-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create an isolated defaults suite")
            return
        }
        defer {
            try? container.persistentStoreCoordinator.persistentStores.forEach { store in
                try container.persistentStoreCoordinator.remove(store)
            }
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(storeURL.path)-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(storeURL.path)-wal"))
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("MLX Swift", forKey: "SelectedAIEngine")
        defaults.set(" https://example.com/v1/// ", forKey: "openAICompatibleBaseURL")
        defaults.set("do-not-copy", forKey: "openAIAPIKey")
        let maintenanceGate = LibraryMaintenanceGate()
        let reader = CoreDataMigrationInputReader(
            container: container,
            defaults: defaults,
            sourceModel: "runtime-input-fixture"
        )
        let input = try await reader.snapshot(
            sourceKeys: ["SelectedAIEngine", "openAICompatibleBaseURL", "openAIAPIKey"]
        )

        XCTAssertTrue(input.metadata.rows.isEmpty)
        XCTAssertEqual(input.metadata.sourceModel, "runtime-input-fixture")
        XCTAssertEqual(
            input.settings,
            LibrarySettingsSnapshot(values: [
                "SelectedAIEngine": .string("MLX Swift"),
                "openAICompatibleBaseURL": .string(" https://example.com/v1/// ")
            ])
        )

        defaults.set("OpenAI", forKey: "SelectedAIEngine")
        defaults.set("On Device (WhisperKit)", forKey: "selectedTranscriptionEngine")
        let normalizedInput = try await reader.snapshot(
            sourceKeys: [
                "SelectedAIEngine",
                "selectedTranscriptionEngine",
                "openAICompatibleBaseURL",
                "openAIAPIKey"
            ],
            normalizationContext: LibrarySettingsNormalizationContext(
                targetPlatform: .iOS,
                supportsMLX: true,
                supportedMLXModelIDs: ["small-model"],
                preferredMLXModelID: "small-model"
            ),
            maintenanceGate: maintenanceGate
        )
        XCTAssertEqual(
            normalizedInput.settings.values["SelectedAIEngine"],
            .string("OpenAI API Compatible")
        )
        XCTAssertEqual(
            normalizedInput.settings.values["selectedTranscriptionEngine"],
            .string("On Device")
        )
        XCTAssertEqual(
            normalizedInput.settings.values["openAICompatibleBaseURL"],
            .string("https://example.com/v1")
        )
        let maintenanceStatus = await maintenanceGate.status()
        XCTAssertEqual(maintenanceStatus.maintenanceActive, false)
    }

    func testSourceCoordinatorUsesObservationAndExclusiveGateForFullRun() async throws {
        let storeURL = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("BisonNotesSourceCoordinator-\(UUID().uuidString).sqlite")
        let container = try makeContainer(at: storeURL)
        let destinationURL = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("BisonNotesSourceCoordinatorDestination-\(UUID().uuidString).sqlite")
        let suiteName = "BisonNotesSourceCoordinator-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create an isolated defaults suite")
            return
        }
        defer {
            try? container.persistentStoreCoordinator.persistentStores.forEach { store in
                try container.persistentStoreCoordinator.remove(store)
            }
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(storeURL.path)-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(storeURL.path)-wal"))
            try? FileManager.default.removeItem(at: destinationURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(destinationURL.path)-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(destinationURL.path)-wal"))
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("OpenAI", forKey: "SelectedAIEngine")
        defaults.set("On Device (WhisperKit)", forKey: "selectedTranscriptionEngine")
        defaults.set(" https://example.com/v1/// ", forKey: "openAICompatibleBaseURL")
        let reader = CoreDataMigrationInputReader(
            container: container,
            defaults: defaults,
            sourceModel: "runtime-source-coordinator-fixture"
        )
        let observation = SourceCoordinatorObservation(currentRevision: 12, changes: [])
        let gate = LibraryMaintenanceGate()
        let progressRecorder = GateProgressRecorder()
        let coordinator = SQLiteMigrationSourceCoordinator(
            inputReader: reader,
            observation: observation,
            maintenanceGate: gate
        )

        let result = try await coordinator.migrate(
            sourceKeys: [
                "SelectedAIEngine",
                "selectedTranscriptionEngine",
                "openAICompatibleBaseURL"
            ],
            normalizationContext: LibrarySettingsNormalizationContext(
                targetPlatform: .iOS,
                supportsMLX: true,
                supportedMLXModelIDs: ["small-model"],
                preferredMLXModelID: "small-model"
            ),
            into: try SQLiteLibraryStore(databaseURL: destinationURL),
            progress: { progress in
                await progressRecorder.append(
                    phase: progress.phase,
                    maintenanceActive: await gate.status().maintenanceActive
                )
            }
        )

        XCTAssertTrue(result.verification.isValid)
        let progressValues = await progressRecorder.values
        XCTAssertFalse(progressValues.isEmpty)
        XCTAssertTrue(progressValues.allSatisfy { $0.maintenanceActive })
        let currentRevisionCallCount = await observation.currentRevisionCallCount
        let changePollCount = await observation.changePollCount
        XCTAssertEqual(currentRevisionCallCount, 1)
        XCTAssertEqual(changePollCount, 1)
        let finalStatus = await gate.status()
        XCTAssertEqual(finalStatus.maintenanceActive, false)
    }

    func testSourceCoordinatorBlocksWhenObservationReportsSourceChange() async throws {
        let storeURL = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("BisonNotesSourceChange-\(UUID().uuidString).sqlite")
        let container = try makeContainer(at: storeURL)
        let destinationURL = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("BisonNotesSourceChangeDestination-\(UUID().uuidString).sqlite")
        let suiteName = "BisonNotesSourceChange-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create an isolated defaults suite")
            return
        }
        defer {
            try? container.persistentStoreCoordinator.persistentStores.forEach { store in
                try container.persistentStoreCoordinator.remove(store)
            }
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(storeURL.path)-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(storeURL.path)-wal"))
            try? FileManager.default.removeItem(at: destinationURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(destinationURL.path)-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(destinationURL.path)-wal"))
            defaults.removePersistentDomain(forName: suiteName)
        }

        let reader = CoreDataMigrationInputReader(
            container: container,
            defaults: defaults,
            sourceModel: "runtime-source-change-fixture"
        )
        let observation = SourceCoordinatorObservation(
            currentRevision: 3,
            changes: [
                LibraryChange(
                    revision: 4,
                    entity: .recording,
                    storageID: "redacted",
                    operation: .updated,
                    committedAt: Date(timeIntervalSinceReferenceDate: 1)
                )
            ]
        )
        let gate = LibraryMaintenanceGate()
        let coordinator = SQLiteMigrationSourceCoordinator(
            inputReader: reader,
            observation: observation,
            maintenanceGate: gate
        )

        do {
            _ = try await coordinator.migrate(
                sourceKeys: ["SelectedAIEngine"],
                normalizationContext: LibrarySettingsNormalizationContext(
                    targetPlatform: .iOS,
                    supportsMLX: false
                ),
                into: try SQLiteLibraryStore(databaseURL: destinationURL)
            )
            XCTFail("Expected source revision drift to block migration")
        } catch let error as SQLiteMigrationSourceCoordinatorError {
            XCTAssertEqual(
                error,
                .sourceChanged(startingRevision: 3, endingRevision: 4)
            )
        }

        let finalStatus = await gate.status()
        XCTAssertEqual(finalStatus.maintenanceActive, false)
    }

    private func makeContainer(at storeURL: URL) throws -> NSPersistentContainer {
        let model = NSManagedObjectModel()
        model.entities = [
            "RecordingEntry",
            "SummaryEntry",
            "TranscriptEntry",
            "ProcessingJobEntry",
            "RecordingArchiveLocationEntry",
            "PendingCloudMutation"
        ].map { name in
            let entity = NSEntityDescription()
            entity.name = name
            entity.managedObjectClassName = "NSManagedObject"
            return entity
        }
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false

        let container = NSPersistentContainer(
            name: "CoreDataMigrationInputReaderRuntimeTests",
            managedObjectModel: model
        )
        container.persistentStoreDescriptions = [description]
        let result = ReaderStoreLoadResult()
        let group = DispatchGroup()
        group.enter()
        container.loadPersistentStores { _, error in
            result.set(error: error)
            group.leave()
        }
        group.wait()
        if let error = result.error {
            throw error
        }
        return container
    }
}

private actor SourceCoordinatorObservation: LibraryObservation {
    let currentRevision: Int64
    let changesToReturn: [LibraryChange]
    private(set) var currentRevisionCallCount = 0
    private(set) var changePollCount = 0

    init(currentRevision: Int64, changes: [LibraryChange]) {
        self.currentRevision = currentRevision
        self.changesToReturn = changes
    }

    func currentRevision() async throws -> Int64 {
        currentRevisionCallCount += 1
        return currentRevision
    }

    func changes(since revision: Int64) async throws -> [LibraryChange] {
        changePollCount += 1
        return changesToReturn
    }
}

private actor GateProgressRecorder {
    private(set) var values: [(phase: SQLiteMigrationCoordinatorPhase, maintenanceActive: Bool)] = []

    func append(phase: SQLiteMigrationCoordinatorPhase, maintenanceActive: Bool) {
        values.append((phase: phase, maintenanceActive: maintenanceActive))
    }
}

private final class ReaderStoreLoadResult: @unchecked Sendable {
    private(set) var error: Error?

    func set(error: Error?) {
        self.error = error
    }
}
