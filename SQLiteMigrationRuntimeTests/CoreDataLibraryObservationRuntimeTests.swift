import CoreData
import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class CoreDataLibraryObservationRuntimeTests: XCTestCase {
    func testPersistentHistoryProvidesDurableRelevantChanges() async throws {
        let storeURL = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("BisonNotesCoreDataObservation-\(UUID().uuidString).sqlite")
        let container = try makeContainer(at: storeURL)
        defer {
            try? container.persistentStoreCoordinator.persistentStores.forEach { store in
                try container.persistentStoreCoordinator.remove(store)
            }
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(storeURL.path)-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(storeURL.path)-wal"))
        }

        let context = container.viewContext
        context.transactionAuthor = "CoreDataLibraryObservationRuntimeTests"
        let recordingID = UUID()
        let recording = NSEntityDescription.insertNewObject(
            forEntityName: "RecordingEntry",
            into: context
        )
        recording.setValue(recordingID, forKey: "id")
        recording.setValue("Initial", forKey: "recordingName")
        try context.save()

        let unrelated = NSEntityDescription.insertNewObject(
            forEntityName: "UnrelatedEntry",
            into: context
        )
        unrelated.setValue("ignored", forKey: "value")
        try context.save()

        recording.setValue("Updated", forKey: "recordingName")
        try context.save()

        context.delete(recording)
        try context.save()

        let observation = CoreDataLibraryObservation(container: container)
        let changes = try await observation.changes(since: 0)

        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(changes.map(\.revision), [1, 2, 3])
        XCTAssertEqual(changes.map(\.entity), [.recording, .recording, .recording])
        XCTAssertEqual(
            changes.map(\.operation),
            [.inserted, .updated, .deleted]
        )
        XCTAssertEqual(Set(changes.map(\.storageID)).count, 1)
        XCTAssertTrue(changes[0].storageID.hasPrefix("core-data-recording-uri-"))
        let currentRevision = try await observation.currentRevision()
        XCTAssertEqual(currentRevision, 3)

        do {
            _ = try await observation.changes(since: 4)
            XCTFail("Expected an ahead cursor to be rejected")
        } catch {
            XCTAssertEqual(
                error as? LibraryObservationError,
                .cursorAhead(current: 3, requested: 4)
            )
        }
    }

    private func makeContainer(at storeURL: URL) throws -> NSPersistentContainer {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "RecordingEntry"
        entity.managedObjectClassName = "NSManagedObject"

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = true

        let name = NSAttributeDescription()
        name.name = "recordingName"
        name.attributeType = .stringAttributeType
        name.isOptional = true

        entity.properties = [id, name]

        let unrelatedEntity = NSEntityDescription()
        unrelatedEntity.name = "UnrelatedEntry"
        unrelatedEntity.managedObjectClassName = "NSManagedObject"
        let unrelatedValue = NSAttributeDescription()
        unrelatedValue.name = "value"
        unrelatedValue.attributeType = .stringAttributeType
        unrelatedValue.isOptional = true
        unrelatedEntity.properties = [unrelatedValue]

        model.entities = [entity, unrelatedEntity]

        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)

        let container = NSPersistentContainer(
            name: "CoreDataLibraryObservationRuntimeTests",
            managedObjectModel: model
        )
        container.persistentStoreDescriptions = [description]

        let result = StoreLoadResult()
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

private final class StoreLoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var error: Error?

    func set(error: Error?) {
        lock.lock()
        self.error = error
        lock.unlock()
    }
}
