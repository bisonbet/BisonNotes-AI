import XCTest
@testable import BisonNotes_AI

/// The attachment store keeps one directory per summary id, so reconciling that
/// root against the store is what catches folders no delete path cleaned up —
/// including Core Data cascade deletes, which never run app code at all.
@MainActor
final class SummaryAttachmentOrphanTests: XCTestCase {
    private var store: SummaryAttachmentStore { .shared }
    private var created: [UUID] = []

    // async so it stays on the main actor: SummaryAttachmentStore is @MainActor
    // and the synchronous tearDown override is not.
    override func tearDown() async throws {
        created.forEach { try? store.deleteAll(for: $0) }
        created.removeAll()
        try await super.tearDown()
    }

    private func makeAttachmentFolder() throws -> UUID {
        let summaryId = UUID()
        try store.saveUserNotes("note for \(summaryId.uuidString)", summaryId: summaryId)
        created.append(summaryId)
        return summaryId
    }

    func testOrphanedFoldersAreThoseWithNoSummaryLeft() throws {
        let live = try makeAttachmentFolder()
        let orphan = try makeAttachmentFolder()

        let orphans = store.orphanedSummaryIds(knownSummaryIds: [live])
        XCTAssertTrue(orphans.contains(orphan))
        XCTAssertFalse(orphans.contains(live), "a summary that still exists must never be swept")
    }

    func testDeletingOrphansLeavesLiveNotesUntouched() throws {
        let live = try makeAttachmentFolder()
        let orphan = try makeAttachmentFolder()

        store.deleteOrphaned(knownSummaryIds: [live])

        XCTAssertEqual(
            store.load(for: live).userNotes,
            "note for \(live.uuidString)",
            "the surviving summary kept its notes"
        )
        XCTAssertNil(store.load(for: orphan).userNotes, "the orphan's folder is gone")
    }

    func testSweepIsIdempotent() throws {
        let orphan = try makeAttachmentFolder()
        XCTAssertGreaterThanOrEqual(store.deleteOrphaned(knownSummaryIds: []), 1)
        // Second pass finds nothing left to do rather than erroring on the
        // directory it just removed.
        XCTAssertFalse(store.orphanedSummaryIds(knownSummaryIds: []).contains(orphan))
    }
}
