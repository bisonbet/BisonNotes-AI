import Foundation

struct SQLiteMediaTransferPlan: Equatable, Sendable {
    let sourceTransferID: String
    let copyPlan: SQLiteMediaCopyPlan

    func validate() throws {
        try SQLiteImportReceiptValidation.identifier(sourceTransferID)
        try copyPlan.validate()
    }
}

enum SQLiteMediaSourceRetentionDisposition: Equatable, Sendable {
    case retain
    case eligibleForRemoval
}

struct SQLiteMediaTransferResult: Equatable, Sendable {
    let operation: SQLiteMediaFileOperation
    let receipt: SQLiteImportReceipt
    let sourceRetention: SQLiteMediaSourceRetentionDisposition
}

enum SQLiteMediaSourceRetentionPolicy {
    static func disposition(
        sourceTransferID: String,
        operation: SQLiteMediaFileOperation,
        receipt: SQLiteImportReceipt?
    ) throws -> SQLiteMediaSourceRetentionDisposition {
        try SQLiteImportReceiptValidation.identifier(sourceTransferID)
        guard operation.state == "completed",
              let assetID = operation.assetID,
              let receipt,
              receipt.sourceTransferID == sourceTransferID,
              receipt.destinationStorageID == assetID,
              receipt.outcome == .committed else {
            return .retain
        }
        return .eligibleForRemoval
    }
}
