import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteImportReceiptRuntimeTests: XCTestCase {
    func testReceiptSurvivesReopenAndDuplicateRetryReturnsOriginal() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let original: SQLiteImportReceipt
        do {
            let store = try SQLiteLibraryStore(databaseURL: databaseURL)
            original = try await store.recordImportReceipt(
                sourceTransferID: "watch-transfer-1",
                destinationStorageID: "asset-1",
                outcome: .committed,
                receiptID: "receipt-1",
                at: Date(timeIntervalSinceReferenceDate: 100)
            )
            let retry = try await store.recordImportReceipt(
                sourceTransferID: "watch-transfer-1",
                destinationStorageID: "asset-1",
                outcome: .committed,
                receiptID: "new-retry-receipt",
                at: Date(timeIntervalSinceReferenceDate: 200)
            )
            XCTAssertEqual(retry, original)
        }

        let reopenedStore = try SQLiteLibraryStore(databaseURL: databaseURL)
        let persisted = try await reopenedStore.importReceipt(
            sourceTransferID: "watch-transfer-1"
        )
        XCTAssertEqual(persisted, original)
    }

    func testConflictingDuplicateReceiptDoesNotOverwriteOriginal() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let store = try SQLiteLibraryStore(databaseURL: databaseURL)
        let original = try await store.recordImportReceipt(
            sourceTransferID: "share-transfer-1",
            destinationStorageID: "asset-1",
            outcome: .committed,
            receiptID: "receipt-1",
            at: Date(timeIntervalSinceReferenceDate: 300)
        )

        do {
            _ = try await store.recordImportReceipt(
                sourceTransferID: "share-transfer-1",
                destinationStorageID: "asset-2",
                outcome: .rejected,
                receiptID: "receipt-2",
                at: Date(timeIntervalSinceReferenceDate: 301)
            )
            XCTFail("Expected conflicting duplicate receipt to be rejected")
        } catch let error as SQLiteImportReceiptError {
            XCTAssertEqual(error, .receiptConflict)
        }

        let persisted = try await store.importReceipt(
            sourceTransferID: "share-transfer-1"
        )
        XCTAssertEqual(persisted, original)
    }

    func testReceiptIDCollisionAcrossTransfersIsRejected() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        _ = try await store.recordImportReceipt(
            sourceTransferID: "watch-transfer-1",
            outcome: .failed,
            receiptID: "receipt-shared"
        )

        do {
            _ = try await store.recordImportReceipt(
                sourceTransferID: "watch-transfer-2",
                outcome: .committed,
                receiptID: "receipt-shared"
            )
            XCTFail("Expected receipt ID collision to be rejected")
        } catch let error as SQLiteImportReceiptError {
            XCTAssertEqual(error, .receiptConflict)
        }
    }
}
