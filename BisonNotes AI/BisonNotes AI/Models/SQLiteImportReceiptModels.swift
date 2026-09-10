import Foundation

/// The durable result of accepting or rejecting one source transfer.
enum SQLiteImportReceiptOutcome: String, Equatable, Sendable {
    case committed
    case rejected
    case failed
}

struct SQLiteImportReceipt: Equatable, Sendable {
    let receiptID: String
    let sourceTransferID: String
    let destinationStorageID: String?
    let outcome: SQLiteImportReceiptOutcome
    let createdAt: Date
}

enum SQLiteImportReceiptError: LocalizedError, Equatable {
    case invalidIdentifier
    case receiptConflict

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "The import receipt identifier is invalid."
        case .receiptConflict:
            return "The import receipt conflicts with an existing transfer."
        }
    }
}

enum SQLiteImportReceiptValidation {
    static func identifier(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("\0") else {
            throw SQLiteImportReceiptError.invalidIdentifier
        }
    }

    static func validate(
        receiptID: String,
        sourceTransferID: String,
        destinationStorageID: String?
    ) throws {
        try identifier(receiptID)
        try identifier(sourceTransferID)
        if let destinationStorageID {
            try identifier(destinationStorageID)
        }
    }
}
