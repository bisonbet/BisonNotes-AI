import CoreData
import CryptoKit
import Foundation

/// Read-only repository adapter over the current Core Data context.
///
/// The adapter copies values while it owns the fetch and never returns managed
/// objects. It is intentionally standalone: application startup still uses
/// the existing Core Data manager until the migration coordinator is ready.
final class CoreDataLibraryRepository: LibraryRepository {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func fetchRecordingSummaries() async throws -> [LibraryRecordingSnapshot] {
        let context = context
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "RecordingEntry")
            request.returnsObjectsAsFaults = false

            return try context.fetch(request)
                .map(Self.snapshot(from:))
                .sorted(by: LibraryRecordingSnapshot.stableOrder)
        }
    }

    private static func snapshot(from object: NSManagedObject) throws -> LibraryRecordingSnapshot {
        let legacyID = (object.value(forKey: "id") as? UUID)?.uuidString.lowercased()
        let storageID: String
        if let legacyID {
            storageID = "core-data-recording-\(legacyID)"
        } else {
            let sourceObjectID = object.objectID.uriRepresentation().absoluteString
            guard !sourceObjectID.isEmpty else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "RecordingEntry",
                    field: "id"
                )
            }
            storageID = "core-data-recording-uri-\(digest(sourceObjectID).prefix(24))"
        }

        return LibraryRecordingSnapshot(
            storageID: storageID,
            legacyID: legacyID,
            name: object.value(forKey: "recordingName") as? String,
            recordingDate: object.value(forKey: "recordingDate") as? Date,
            duration: (object.value(forKey: "duration") as? NSNumber)?.doubleValue,
            fileSize: (object.value(forKey: "fileSize") as? NSNumber)?.int64Value,
            recordingURL: object.value(forKey: "recordingURL") as? String,
            isArchived: (object.value(forKey: "isArchived") as? NSNumber)?.boolValue,
            lastModified: object.value(forKey: "lastModified") as? Date
        )
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
