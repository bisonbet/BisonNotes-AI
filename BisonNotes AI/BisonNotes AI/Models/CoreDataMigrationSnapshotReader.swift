import CoreData
import CryptoKit
import Foundation

// swiftlint:disable type_body_length
/// Reads the authoritative Core Data store into the storage-neutral snapshot
/// consumed by the SQLite migration importer.
///
/// The caller must quiesce library writes before requesting a snapshot. This
/// reader never opens SQLite directly, never reads Core Data implementation
/// tables, and never deletes or mutates source rows. It deliberately includes
/// only metadata and references; audio bytes remain outside the snapshot.
/// The source graph capture stays in one type so every fetch and relationship
/// lookup remains visibly part of the same read-only snapshot boundary.
final class CoreDataMigrationSnapshotReader: @unchecked Sendable {
    private let context: NSManagedObjectContext
    private let sourceModel: String

    convenience init(
        container: NSPersistentContainer,
        sourceModel: String? = nil
    ) {
        self.init(
            context: container.viewContext,
            sourceModel: sourceModel ?? Self.defaultSourceModel(for: container.managedObjectModel)
        )
    }

    init(
        context: NSManagedObjectContext,
        sourceModel: String
    ) {
        self.context = context
        self.sourceModel = sourceModel
    }

    /// Captures all supported metadata rows from one Core Data context
    /// execution. A temporary object ID or incomplete relationship is a hard
    /// failure because importing a partial graph would be unsafe.
    func snapshot() async throws -> SQLiteMigrationSourceSnapshot {
        let context = context
        return try context.performAndWait {
            try Self.makeSnapshot(
                in: context,
                sourceModel: sourceModel
            )
        }
    }

    // swiftlint:disable function_body_length
    private static func makeSnapshot(
        in context: NSManagedObjectContext,
        sourceModel: String
    ) throws -> SQLiteMigrationSourceSnapshot {
        guard !sourceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreDataMigrationSnapshotReaderError.invalidSourceModel
        }
        let pairs = try sourceEntityPairs(in: context)
        var descriptors = [SourceObjectDescriptor]()
        var storageIDsByURI = [String: String]()

        for pair in pairs {
            let request = NSFetchRequest<NSManagedObject>(entityName: pair.sourceName)
            request.returnsObjectsAsFaults = false
            let objects = try context.fetch(request)
            for object in objects {
                let sourceObjectID = try sourceObjectID(
                    for: object,
                    entity: pair.destinationEntity
                )
                guard !descriptors.contains(where: { $0.sourceObjectID == sourceObjectID }) else {
                    throw CoreDataMigrationSnapshotReaderError.duplicateSourceObjectID(sourceObjectID)
                }

                let destinationStorageID = destinationStorageID(
                    for: object,
                    sourceName: pair.sourceName,
                    sourceObjectID: sourceObjectID
                )
                let objectURI = object.objectID.uriRepresentation().absoluteString
                guard !objectURI.isEmpty else {
                    throw CoreDataMigrationSnapshotReaderError.invalidObjectID(pair.sourceName)
                }
                guard storageIDsByURI[objectURI] == nil else {
                    throw CoreDataMigrationSnapshotReaderError.duplicateStorageID(
                        entity: pair.sourceName,
                        storageID: destinationStorageID
                    )
                }

                descriptors.append(
                    SourceObjectDescriptor(
                        destinationEntity: pair.destinationEntity,
                        sourceName: pair.sourceName,
                        object: object,
                        sourceObjectID: sourceObjectID,
                        destinationStorageID: destinationStorageID
                    )
                )
                storageIDsByURI[objectURI] = destinationStorageID
            }
        }

        let rows = try descriptors
            .map { try makeRow(from: $0, storageIDsByURI: storageIDsByURI) }
            .sorted(by: rowSort)
        let fingerprint = sourceFingerprint(model: sourceModel, rows: rows)
        return SQLiteMigrationSourceSnapshot(
            sourceModel: sourceModel,
            sourceFingerprint: fingerprint,
            migrationRunID: nil,
            rows: rows
        )
    }
    // swiftlint:enable function_body_length

    private static func sourceEntityPairs(
        in context: NSManagedObjectContext
    ) throws -> [(destinationEntity: SQLiteMigrationSourceEntity, sourceName: String)] {
        guard let model = context.persistentStoreCoordinator?.managedObjectModel else {
            throw CoreDataMigrationSnapshotReaderError.modelUnavailable
        }

        let allPairs: [(SQLiteMigrationSourceEntity, String)] = [
            (.recordings, "RecordingEntry"),
            (.summaries, "SummaryEntry"),
            (.transcripts, "TranscriptEntry"),
            (.processingJobs, "ProcessingJobEntry"),
            (.archiveLocations, "RecordingArchiveLocationEntry"),
            (.pendingCloudMutations, "PendingCloudMutation")
        ]
        return try allPairs.compactMap { destinationEntity, sourceName in
            guard model.entitiesByName[sourceName] != nil else {
                if destinationEntity == .pendingCloudMutations {
                    return nil
                }
                throw CoreDataMigrationSnapshotReaderError.missingEntity(sourceName)
            }
            return (destinationEntity, sourceName)
        }
    }

    private static func makeRow(
        from descriptor: SourceObjectDescriptor,
        storageIDsByURI: [String: String]
    ) throws -> SQLiteMigrationExpectedRow {
        var values = [String: SQLiteMigrationValue]()
        for column in descriptor.destinationEntity.destinationColumns.sorted() {
            if column == "storageID" {
                values[column] = .text(descriptor.destinationStorageID)
            } else if column == "recordingStorageID" {
                values[column] = try relatedStorageID(
                    from: descriptor.object,
                    entity: descriptor.sourceName,
                    relationship: "recording",
                    storageIDsByURI: storageIDsByURI
                )
            } else if column == "transcriptStorageID" {
                values[column] = try relatedStorageID(
                    from: descriptor.object,
                    entity: descriptor.sourceName,
                    relationship: "transcript",
                    storageIDsByURI: storageIDsByURI
                )
            } else {
                guard descriptor.object.entity.attributesByName[column] != nil else {
                    throw CoreDataMigrationSnapshotReaderError.missingAttribute(
                        entity: descriptor.sourceName,
                        column: column
                    )
                }
                values[column] = try databaseValue(
                    descriptor.object.value(forKey: column),
                    entity: descriptor.sourceName,
                    column: column
                )
            }
        }

        return SQLiteMigrationExpectedRow(
            entity: descriptor.destinationEntity,
            sourceObjectID: descriptor.sourceObjectID,
            destinationStorageID: descriptor.destinationStorageID,
            values: values
        )
    }

    private static func relatedStorageID(
        from object: NSManagedObject,
        entity: String,
        relationship: String,
        storageIDsByURI: [String: String]
    ) throws -> SQLiteMigrationValue {
        guard let related = object.value(forKey: relationship) as? NSManagedObject else {
            return .null
        }
        let uri = related.objectID.uriRepresentation().absoluteString
        guard let storageID = storageIDsByURI[uri] else {
            throw CoreDataMigrationSnapshotReaderError.missingRelatedStorageID(
                entity: entity,
                relationship: relationship
            )
        }
        return .text(storageID)
    }

    private static func databaseValue(
        _ rawValue: Any?,
        entity: String,
        column: String
    ) throws -> SQLiteMigrationValue {
        guard let rawValue, !(rawValue is NSNull) else {
            return .null
        }
        if let value = rawValue as? String {
            return .text(value)
        }
        if let value = rawValue as? UUID {
            return .text(value.uuidString.lowercased())
        }
        if let value = rawValue as? Date {
            return .real(value.timeIntervalSinceReferenceDate)
        }
        if let value = rawValue as? Data {
            return .blob(value)
        }
        if let value = rawValue as? Bool {
            return .boolean(value)
        }
        if let value = rawValue as? NSNumber {
            let type = String(cString: value.objCType)
            if type == "c" || type == "B" {
                return .boolean(value.boolValue)
            }
            if type == "f" || type == "d" {
                return .real(value.doubleValue)
            }
            return .integer(value.int64Value)
        }
        throw CoreDataMigrationSnapshotReaderError.unsupportedValue(
            entity: entity,
            column: column,
            type: String(describing: type(of: rawValue))
        )
    }

    private static func sourceObjectID(
        for object: NSManagedObject,
        entity: SQLiteMigrationSourceEntity
    ) throws -> String {
        guard !object.objectID.isTemporaryID else {
            throw CoreDataMigrationSnapshotReaderError.temporaryObjectID(entity.rawValue)
        }
        if object.entity.attributesByName["id"] != nil,
           let id = object.value(forKey: "id") as? UUID {
            return "\(entity.rawValue)|id|\(id.uuidString.lowercased())"
        }
        let uri = object.objectID.uriRepresentation().absoluteString
        guard !uri.isEmpty else {
            throw CoreDataMigrationSnapshotReaderError.invalidObjectID(entity.rawValue)
        }
        return "\(entity.rawValue)|uri|\(uri)"
    }

    private static func destinationStorageID(
        for object: NSManagedObject,
        sourceName: String,
        sourceObjectID: String
    ) -> String {
        let prefix = sourceName.replacingOccurrences(of: "Entry", with: "").lowercased()
        if object.entity.attributesByName["id"] != nil,
           let id = object.value(forKey: "id") as? UUID {
            return "core-data-\(prefix)-\(id.uuidString.lowercased())"
        }
        return "core-data-\(prefix)-uri-\(digest(sourceObjectID).prefix(24))"
    }

    private static func sourceFingerprint(
        model: String,
        rows: [SQLiteMigrationExpectedRow]
    ) -> String {
        var canonical = "model=\(model)\n"
        for row in rows.sorted(by: rowSort) {
            canonical += "entity=\(row.entity.rawValue)\n"
            canonical += "source=\(row.sourceObjectID)\n"
            canonical += "storage=\(row.destinationStorageID)\n"
            for column in row.values.keys.sorted() {
                canonical += "\(column)=\(SQLiteMigrationImportSupport.canonicalValue(row.values[column]!))\n"
            }
        }
        return digest(canonical)
    }

    private static func rowSort(
        _ lhs: SQLiteMigrationExpectedRow,
        _ rhs: SQLiteMigrationExpectedRow
    ) -> Bool {
        if lhs.entity.rawValue != rhs.entity.rawValue {
            return lhs.entity.rawValue < rhs.entity.rawValue
        }
        return lhs.destinationStorageID < rhs.destinationStorageID
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func defaultSourceModel(
        for model: NSManagedObjectModel
    ) -> String {
        let identifiers = model.versionIdentifiers
            .map { String(describing: $0) }
            .sorted()
        if !identifiers.isEmpty {
            return identifiers.joined(separator: ",")
        }

        let schema = model.entities
            .compactMap { entity -> String? in
                guard let name = entity.name else { return nil }
                let attributes = entity.attributesByName.values
                    .sorted { $0.name < $1.name }
                    .map { "a:\($0.name):\($0.attributeType.rawValue):\($0.isOptional)" }
                let relationships = entity.relationshipsByName.values
                    .sorted { $0.name < $1.name }
                    .map { "r:\($0.name):\($0.destinationEntity?.name ?? ""):\($0.isOptional)" }
                return ([name] + attributes + relationships).joined(separator: "|")
            }
            .sorted()
            .joined(separator: "\n")
        return "CoreData-\(digest(schema).prefix(16))"
    }

    private struct SourceObjectDescriptor {
        let destinationEntity: SQLiteMigrationSourceEntity
        let sourceName: String
        let object: NSManagedObject
        let sourceObjectID: String
        let destinationStorageID: String
    }
}
// swiftlint:enable type_body_length

enum CoreDataMigrationSnapshotReaderError: LocalizedError, Equatable {
    case modelUnavailable
    case invalidSourceModel
    case missingEntity(String)
    case missingAttribute(entity: String, column: String)
    case temporaryObjectID(String)
    case invalidObjectID(String)
    case duplicateSourceObjectID(String)
    case duplicateStorageID(entity: String, storageID: String)
    case missingRelatedStorageID(entity: String, relationship: String)
    case unsupportedValue(entity: String, column: String, type: String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "The Core Data migration source model is unavailable."
        case .invalidSourceModel:
            return "The Core Data migration source model identifier is empty."
        case .missingEntity(let name):
            return "The Core Data migration source model is missing \(name)."
        case .missingAttribute(let entity, let column):
            return "The Core Data migration source entity \(entity) is missing \(column)."
        case .temporaryObjectID(let entity):
            return "The Core Data migration source entity \(entity) contains a temporary object ID."
        case .invalidObjectID(let entity):
            return "The Core Data migration source entity \(entity) has no valid object ID."
        case .duplicateSourceObjectID(let sourceObjectID):
            return "The Core Data migration source contains duplicate object ID \(sourceObjectID)."
        case .duplicateStorageID(let entity, let storageID):
            return "The Core Data migration source entity \(entity) contains duplicate storage ID \(storageID)."
        case .missingRelatedStorageID(let entity, let relationship):
            return "The Core Data migration relationship \(entity).\(relationship) "
                + "points outside the captured source graph."
        case .unsupportedValue(let entity, let column, let type):
            return "The Core Data migration value \(entity).\(column) has unsupported type \(type)."
        }
    }
}
