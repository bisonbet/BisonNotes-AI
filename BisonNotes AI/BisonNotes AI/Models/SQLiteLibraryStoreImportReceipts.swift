import Foundation
import GRDB

extension SQLiteLibraryStore {
    /// Records a transfer outcome exactly once. Repeating the same source
    /// transfer with the same result returns the original receipt, even when
    /// the retry supplies a newly generated receipt ID.
    func recordImportReceipt(
        sourceTransferID: String,
        destinationStorageID: String? = nil,
        outcome: SQLiteImportReceiptOutcome,
        receiptID: String = UUID().uuidString,
        at date: Date = Date()
    ) throws -> SQLiteImportReceipt {
        try SQLiteImportReceiptValidation.validate(
            receiptID: receiptID,
            sourceTransferID: sourceTransferID,
            destinationStorageID: destinationStorageID
        )
        let receipt = SQLiteImportReceipt(
            receiptID: receiptID,
            sourceTransferID: sourceTransferID,
            destinationStorageID: destinationStorageID,
            outcome: outcome,
            createdAt: date
        )
        return try databaseQueue.write { database in
            try Self.recordImportReceipt(receipt, in: database)
        }
    }

    func importReceipt(
        sourceTransferID: String
    ) throws -> SQLiteImportReceipt? {
        try SQLiteImportReceiptValidation.identifier(sourceTransferID)
        return try databaseQueue.read { database in
            try Self.fetchImportReceipt(
                sourceTransferID: sourceTransferID,
                from: database
            )
        }
    }
}

private extension SQLiteLibraryStore {
    static func recordImportReceipt(
        _ receipt: SQLiteImportReceipt,
        in database: Database
    ) throws -> SQLiteImportReceipt {
        if let existing = try fetchImportReceipt(
            sourceTransferID: receipt.sourceTransferID,
            from: database
        ) {
            guard matches(
                existing,
                receipt: receipt
            ) else {
                throw SQLiteImportReceiptError.receiptConflict
            }
            return existing
        }

        if let existing = try fetchImportReceipt(
            receiptID: receipt.receiptID,
            from: database
        ) {
            guard matches(
                existing,
                receipt: receipt
            ) else {
                throw SQLiteImportReceiptError.receiptConflict
            }
            return existing
        }

        try database.execute(
            sql: """
            INSERT INTO import_receipts (
                receiptID, sourceTransferID, destinationStorageID, outcome, createdAt
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [
                receipt.receiptID,
                receipt.sourceTransferID,
                receipt.destinationStorageID,
                receipt.outcome.rawValue,
                receipt.createdAt.timeIntervalSinceReferenceDate
            ]
        )
        guard let receipt = try fetchImportReceipt(
            sourceTransferID: receipt.sourceTransferID,
            from: database
        ) else {
            throw SQLiteLibraryStoreError.invalidMetadata
        }
        return receipt
    }

    static func fetchImportReceipt(
        sourceTransferID: String,
        from database: Database
    ) throws -> SQLiteImportReceipt? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
            SELECT receiptID, sourceTransferID, destinationStorageID, outcome, createdAt
            FROM import_receipts
            WHERE sourceTransferID = ?
            """,
            arguments: [sourceTransferID]
        ) else {
            return nil
        }
        return try decodeImportReceipt(row)
    }

    static func fetchImportReceipt(
        receiptID: String,
        from database: Database
    ) throws -> SQLiteImportReceipt? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
            SELECT receiptID, sourceTransferID, destinationStorageID, outcome, createdAt
            FROM import_receipts
            WHERE receiptID = ?
            """,
            arguments: [receiptID]
        ) else {
            return nil
        }
        return try decodeImportReceipt(row)
    }

    static func decodeImportReceipt(_ row: Row) throws -> SQLiteImportReceipt {
        guard let receiptID: String = row["receiptID"],
              let sourceTransferID: String = row["sourceTransferID"],
              let outcomeRawValue: String = row["outcome"],
              let createdAt: Double = row["createdAt"],
              let outcome = SQLiteImportReceiptOutcome(rawValue: outcomeRawValue) else {
            throw SQLiteLibraryStoreError.invalidMetadata
        }
        return SQLiteImportReceipt(
            receiptID: receiptID,
            sourceTransferID: sourceTransferID,
            destinationStorageID: row["destinationStorageID"],
            outcome: outcome,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt)
        )
    }

    static func matches(
        _ receipt: SQLiteImportReceipt,
        receipt candidate: SQLiteImportReceipt
    ) -> Bool {
        receipt.sourceTransferID == candidate.sourceTransferID &&
            receipt.destinationStorageID == candidate.destinationStorageID &&
            receipt.outcome == candidate.outcome
    }
}
