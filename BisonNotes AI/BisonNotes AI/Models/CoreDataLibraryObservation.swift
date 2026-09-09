import CoreData
import CryptoKit
import Foundation

/// A durable Core Data source observation adapter for the pre-cutover phase.
///
/// Core Data's persistent history is the source of truth here; ordinary
/// context-change notifications are intentionally not used as a migration
/// cursor because they do not survive a crash or process restart. The adapter
/// presents the relevant retained history as a compact, sequential cursor.
/// History is deliberately not purged until a later migration policy owns
/// retention and has proved that every consumer has advanced past it.
/// Core Data changes use a hashed object-URI storage ID so inserts, updates and
/// deletes retain the same identity even when a history tombstone has no
/// legacy UUID payload.
final class CoreDataLibraryObservation: LibraryObservation, @unchecked Sendable {
    static let applicationTransactionAuthor = "BisonNotes.AI"

    private let context: NSManagedObjectContext

    convenience init(container: NSPersistentContainer) {
        self.init(persistentStoreCoordinator: container.persistentStoreCoordinator)
    }

    init(persistentStoreCoordinator: NSPersistentStoreCoordinator) {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = persistentStoreCoordinator
        context.transactionAuthor = Self.applicationTransactionAuthor
        self.context = context
    }

    func currentRevision() async throws -> Int64 {
        let context = context
        return try context.performAndWait {
            Int64(try Self.loadChanges(in: context).count)
        }
    }

    func changes(since revision: Int64) async throws -> [LibraryChange] {
        guard revision >= 0 else {
            throw LibraryObservationError.invalidCursor(revision)
        }

        let context = context
        return try context.performAndWait {
            let changes = try Self.loadChanges(in: context)
            let currentRevision = Int64(changes.count)
            guard revision <= currentRevision else {
                throw LibraryObservationError.cursorAhead(
                    current: currentRevision,
                    requested: revision
                )
            }
            return Array(changes.dropFirst(Int(revision)))
        }
    }

    private static func loadChanges(
        in context: NSManagedObjectContext
    ) throws -> [LibraryChange] {
        let request = NSPersistentHistoryChangeRequest.fetchHistory(
            after: Optional<NSPersistentHistoryToken>.none
        )
        request.resultType = .transactionsAndChanges

        guard let result = try context.execute(request) as? NSPersistentHistoryResult,
              let transactions = result.result as? [NSPersistentHistoryTransaction] else {
            throw LibraryObservationError.historyUnavailable(
                "the persistent store did not return transaction history"
            )
        }

        let orderedTransactions = transactions.sorted {
            if $0.transactionNumber != $1.transactionNumber {
                return $0.transactionNumber < $1.transactionNumber
            }
            return $0.timestamp < $1.timestamp
        }

        var changes: [LibraryChange] = []
        for transaction in orderedTransactions {
            let transactionChanges = (transaction.changes ?? []).sorted {
                $0.changeID < $1.changeID
            }
            for change in transactionChanges {
                guard let entity = entity(for: change.changedObjectID.entity.name) else {
                    continue
                }
                let revision = Int64(changes.count) + 1
                changes.append(
                    LibraryChange(
                        revision: revision,
                        entity: entity,
                        storageID: try storageID(for: change),
                        operation: operation(for: change.changeType),
                        committedAt: transaction.timestamp
                    )
                )
            }
        }
        return changes
    }

    private static func entity(for name: String?) -> LibraryChangeEntity? {
        switch name {
        case "RecordingEntry":
            return .recording
        case "TranscriptEntry":
            return .transcript
        case "SummaryEntry":
            return .summary
        case "ProcessingJobEntry":
            return .processingJob
        case "RecordingArchiveLocationEntry":
            return .archiveLocation
        case "PendingCloudMutation":
            return .pendingCloudMutation
        default:
            return nil
        }
    }

    private static func operation(
        for changeType: NSPersistentHistoryChangeType
    ) -> LibraryChangeOperation {
        switch changeType {
        case .insert:
            return .inserted
        case .update:
            return .updated
        case .delete:
            return .deleted
        @unknown default:
            return .updated
        }
    }

    private static func storageID(
        for change: NSPersistentHistoryChange
    ) throws -> String {
        let entityName = change.changedObjectID.entity.name ?? "Related"
        let prefix = entityName.replacingOccurrences(of: "Entry", with: "").lowercased()

        let objectURI = change.changedObjectID.uriRepresentation().absoluteString
        guard !objectURI.isEmpty else {
            throw LibraryObservationError.invalidStoredChange(revision: 0)
        }
        let digest = SHA256.hash(data: Data(objectURI.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "core-data-\(prefix)-uri-\(digest.prefix(24))"
    }
}
