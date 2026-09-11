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
            )
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

private final class ReaderStoreLoadResult: @unchecked Sendable {
    private(set) var error: Error?

    func set(error: Error?) {
        self.error = error
    }
}
