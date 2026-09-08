import CoreData
import XCTest
@testable import BisonNotes_AI

@MainActor
final class Swift6PersistenceIsolationTests: XCTestCase {
    func testPersistenceControllerUsesTheExpectedModelAndViewContext() {
        let persistence = PersistenceController(inMemory: true)
        let manager = CoreDataManager(persistenceController: persistence)

        XCTAssertEqual(persistence.container.name, "BisonNotes_AI")
        XCTAssertTrue(manager.contextForTesting === persistence.container.viewContext)
        XCTAssertEqual(persistence.storageStatus, .inMemory)
        XCTAssertTrue(persistence.storageStatus.isOperational)
        XCTAssertFalse(persistence.storageStatus.isDurable)
    }

    func testDurableStoreFailureDoesNotInstallAnInMemoryFallback() {
        let missingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("BisonNotesStorageFailure-\(UUID().uuidString)", isDirectory: true)
        let storeURL = missingParent.appendingPathComponent("library.sqlite")
        let persistence = PersistenceController(storeURL: storeURL)

        XCTAssertEqual(persistence.storageStatus, .unavailable)
        XCTAssertFalse(persistence.storageStatus.isOperational)
        XCTAssertTrue(persistence.container.persistentStoreCoordinator.persistentStores.isEmpty)
    }

    func testDurableStoreLoadsSynchronouslyAndReportsReady() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BisonNotesStorageReady-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("library.sqlite")
        let persistence = PersistenceController(storeURL: storeURL)
        defer {
            try? persistence.container.persistentStoreCoordinator.destroyPersistentStore(
                at: storeURL,
                ofType: NSSQLiteStoreType,
                options: nil
            )
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertEqual(persistence.storageStatus, .ready)
        XCTAssertTrue(persistence.storageStatus.isDurable)
        XCTAssertEqual(persistence.container.persistentStoreCoordinator.persistentStores.count, 1)
    }

    func testAttachmentStoreRoundTripPreservesNotesAndAttachments() throws {
        let summaryID = UUID()
        let store = SummaryAttachmentStore.shared
        defer { try? store.deleteAll(for: summaryID) }

        try store.saveUserNotes("  Keep this note.  ", summaryId: summaryID)

        let supplemental = store.load(for: summaryID)
        XCTAssertEqual(supplemental.userNotes, "Keep this note.")
        XCTAssertTrue(supplemental.attachments.isEmpty)
    }

    func testAttachmentMigrationPreservesStoredFiles() throws {
        let oldSummaryID = UUID()
        let newSummaryID = UUID()
        let store = SummaryAttachmentStore.shared
        defer {
            try? store.deleteAll(for: oldSummaryID)
            try? store.deleteAll(for: newSummaryID)
        }

        try store.saveUserNotes("Migrated note", summaryId: oldSummaryID)
        try store.migrate(from: oldSummaryID, to: newSummaryID)

        XCTAssertEqual(store.load(for: newSummaryID).userNotes, "Migrated note")
        XCTAssertNil(store.load(for: oldSummaryID).userNotes)
    }
}
