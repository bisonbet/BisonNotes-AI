import XCTest
@testable import BisonNotes_AI

@MainActor
final class Swift6PersistenceIsolationTests: XCTestCase {
    func testPersistenceControllerUsesTheExpectedModelAndViewContext() {
        let persistence = PersistenceController(inMemory: true)
        let manager = CoreDataManager(persistenceController: persistence)

        XCTAssertEqual(persistence.container.name, "BisonNotes_AI")
        XCTAssertTrue(manager.contextForTesting === persistence.container.viewContext)
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
