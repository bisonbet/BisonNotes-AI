// The fixture intentionally keeps the model population and projection together
// so a source-field change is reviewed beside its snapshot disposition.
// swiftlint:disable file_length type_body_length type_name

import CoreData
import CryptoKit
import Foundation
@testable import BisonNotes_AI

enum SQLiteMigrationCoreDataModelVersion: String, CaseIterable {
    case original = "BisonNotes_AI"
    case active = "BisonNotes_AI_v2"
}

struct SQLiteMigrationCoreDataSourceFixture {
    let modelVersion: SQLiteMigrationCoreDataModelVersion
    let storeURL: URL
    let container: NSPersistentContainer
    let snapshot: SQLiteMigrationSourceSnapshot
}

enum SQLiteMigrationCoreDataSourceFixtureError: LocalizedError {
    case compiledModelNotFound
    case modelNotFound(URL)
    case storeLoadFailed(String)
    case missingEntity(String)
    case missingAttribute(entity: String, column: String)
    case unsupportedValue(entity: String, column: String, type: String)
    case invalidFixtureData(String)
    case missingRelatedStorageID(entity: String, relationship: String)
    case duplicateSourceObjectID(String)

    var errorDescription: String? {
        switch self {
        case .compiledModelNotFound:
            return "The compiled BisonNotes_AI model directory was not found."
        case .modelNotFound(let url):
            return "The compiled Core Data model was not found at \(url.path)."
        case .storeLoadFailed(let detail):
            return "The Core Data fixture store failed to load: \(detail)"
        case .missingEntity(let name):
            return "The Core Data fixture model is missing entity \(name)."
        case .missingAttribute(let entity, let column):
            return "The Core Data fixture entity \(entity) is missing attribute \(column)."
        case .unsupportedValue(let entity, let column, let type):
            return "The Core Data fixture value \(entity).\(column) has unsupported type \(type)."
        case .invalidFixtureData(let detail):
            return "The Core Data fixture data is invalid: \(detail)"
        case .missingRelatedStorageID(let entity, let relationship):
            return "The Core Data fixture relationship \(entity).\(relationship) has no destination storage ID."
        case .duplicateSourceObjectID(let sourceObjectID):
            return "The Core Data fixture contains duplicate source object ID \(sourceObjectID)."
        }
    }
}

enum SQLiteMigrationCoreDataSourceFixtureFactory {
    static func make(
        at storeURL: URL,
        version: SQLiteMigrationCoreDataModelVersion
    ) throws -> SQLiteMigrationCoreDataSourceFixture {
        let container = try makeContainer(at: storeURL, version: version)
        do {
            try populate(container: container, version: version)
            let snapshot = try snapshot(from: container, version: version)
            return SQLiteMigrationCoreDataSourceFixture(
                modelVersion: version,
                storeURL: storeURL,
                container: container,
                snapshot: snapshot
            )
        } catch {
            try? close(container: container)
            throw error
        }
    }

    static func close(container: NSPersistentContainer) throws {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }

    static func snapshot(
        from container: NSPersistentContainer,
        version: SQLiteMigrationCoreDataModelVersion
    ) throws -> SQLiteMigrationSourceSnapshot {
        let context = container.viewContext
        return try performAndWait(on: context) {
            let pairs = try sourceEntityPairs(in: container.managedObjectModel)
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
                        throw SQLiteMigrationCoreDataSourceFixtureError.duplicateSourceObjectID(
                            sourceObjectID
                        )
                    }
                    let destinationStorageID = destinationStorageID(
                        for: object,
                        entity: pair.destinationEntity,
                        sourceObjectID: sourceObjectID
                    )
                    let managedObjectURI = object.objectID.uriRepresentation().absoluteString
                    descriptors.append(
                        SourceObjectDescriptor(
                            destinationEntity: pair.destinationEntity,
                            sourceName: pair.sourceName,
                            object: object,
                            sourceObjectID: sourceObjectID,
                            destinationStorageID: destinationStorageID
                        )
                    )
                    storageIDsByURI[managedObjectURI] = destinationStorageID
                }
            }

            let rows = try descriptors.map {
                try makeRow(from: $0, storageIDsByURI: storageIDsByURI)
            }.sorted(by: rowSort)
            let fingerprint = sourceFingerprint(model: version.rawValue, rows: rows)
            return SQLiteMigrationSourceSnapshot(
                sourceModel: version.rawValue,
                sourceFingerprint: fingerprint,
                migrationRunID: nil,
                rows: rows
            )
        }
    }

    private static func makeContainer(
        at storeURL: URL,
        version: SQLiteMigrationCoreDataModelVersion
    ) throws -> NSPersistentContainer {
        guard storeURL.isFileURL, !storeURL.path.isEmpty else {
            throw SQLiteMigrationCoreDataSourceFixtureError.invalidFixtureData(
                "fixture store URL must be a file URL"
            )
        }
        guard let modelDirectoryURL = compiledModelDirectoryURL() else {
            throw SQLiteMigrationCoreDataSourceFixtureError.compiledModelNotFound
        }
        let modelURL = modelDirectoryURL.appendingPathComponent("\(version.rawValue).mom")
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
            throw SQLiteMigrationCoreDataSourceFixtureError.modelNotFound(modelURL)
        }

        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let container = NSPersistentContainer(
            name: "SQLiteMigrationFixture-\(version.rawValue)",
            managedObjectModel: model
        )
        let description = container.persistentStoreDescriptions[0]
        description.type = NSSQLiteStoreType
        description.url = storeURL
        description.shouldAddStoreAsynchronously = false
        description.setOption(
            false as NSNumber,
            forKey: NSMigratePersistentStoresAutomaticallyOption
        )
        description.setOption(
            false as NSNumber,
            forKey: NSInferMappingModelAutomaticallyOption
        )

        let loadResult = StoreLoadResult()
        let group = DispatchGroup()
        group.enter()
        container.loadPersistentStores { _, error in
            loadResult.set(error: error)
            group.leave()
        }
        group.wait()
        if let error = loadResult.error {
            throw SQLiteMigrationCoreDataSourceFixtureError.storeLoadFailed(
                error.localizedDescription
            )
        }
        return container
    }

    private static func populate(
        container: NSPersistentContainer,
        version: SQLiteMigrationCoreDataModelVersion
    ) throws {
        let context = container.viewContext
        try performAndWait(on: context) {
            let ids = try FixtureIDs()
            let recording = try insert("RecordingEntry", into: context)
            let transcript = try insert("TranscriptEntry", into: context)
            let summary = try insert("SummaryEntry", into: context)
            let processingJob = try insert("ProcessingJobEntry", into: context)
            let archiveLocation = try insert("RecordingArchiveLocationEntry", into: context)

            populateRecording(recording, ids: ids)
            populateTranscript(transcript, ids: ids)
            populateSummary(summary, ids: ids)
            populateProcessingJob(processingJob, ids: ids)
            populateArchiveLocation(archiveLocation, ids: ids)

            recording.setValue(summary, forKey: "summary")
            recording.setValue(transcript, forKey: "transcript")
            summary.setValue(recording, forKey: "recording")
            summary.setValue(transcript, forKey: "transcript")
            transcript.setValue(recording, forKey: "recording")
            processingJob.setValue(recording, forKey: "recording")

            if version == .active {
                let mutation = try insert("PendingCloudMutation", into: context)
                populatePendingMutation(mutation, ids: ids)
            }
            try context.save()
        }
    }

    private static func populateRecording(_ object: NSManagedObject, ids: FixtureIDs) {
        object.setValue("lossless", forKey: "audioQuality")
        object.setValue(Date(timeIntervalSinceReferenceDate: 100), forKey: "createdAt")
        object.setValue(7.5, forKey: "duration")
        object.setValue(Int64(42), forKey: "fileSize")
        object.setValue(ids.recordingID, forKey: "id")
        object.setValue(false, forKey: "isCloudSyncDisabled")
        object.setValue(Date(timeIntervalSinceReferenceDate: 101), forKey: "lastModified")
        object.setValue(7.0, forKey: "locationAccuracy")
        object.setValue("Fixture address", forKey: "locationAddress")
        object.setValue(39.25, forKey: "locationLatitude")
        object.setValue(-76.71, forKey: "locationLongitude")
        object.setValue(Date(timeIntervalSinceReferenceDate: 99), forKey: "locationTimestamp")
        object.setValue(Date(timeIntervalSinceReferenceDate: 100), forKey: "recordingDate")
        object.setValue("Fixture recording", forKey: "recordingName")
        object.setValue("recording.m4a", forKey: "recordingURL")
        object.setValue(ids.summaryID, forKey: "summaryId")
        object.setValue("complete", forKey: "summaryStatus")
        object.setValue(ids.transcriptID, forKey: "transcriptId")
        object.setValue("complete", forKey: "transcriptionStatus")
        object.setValue(false, forKey: "isArchived")
        object.setValue(nil, forKey: "archivedAt")
        object.setValue(nil, forKey: "archiveNote")
    }

    private static func populateTranscript(_ object: NSManagedObject, ids: FixtureIDs) {
        object.setValue(0.98, forKey: "confidence")
        object.setValue(Date(timeIntervalSinceReferenceDate: 102), forKey: "createdAt")
        object.setValue("fixture-engine", forKey: "engine")
        object.setValue(ids.transcriptID, forKey: "id")
        object.setValue(Date(timeIntervalSinceReferenceDate: 103), forKey: "lastModified")
        object.setValue(1.5, forKey: "processingTime")
        object.setValue(ids.recordingID, forKey: "recordingId")
        object.setValue("{\"segments\":[]}", forKey: "segments")
        object.setValue("{}", forKey: "speakerMappings")
    }

    private static func populateSummary(_ object: NSManagedObject, ids: FixtureIDs) {
        object.setValue("fixture-model", forKey: "aiMethod")
        object.setValue(0.25, forKey: "compressionRatio")
        object.setValue(0.9, forKey: "confidence")
        object.setValue("summary", forKey: "contentType")
        object.setValue(Date(timeIntervalSinceReferenceDate: 104), forKey: "generatedAt")
        object.setValue(ids.summaryID, forKey: "id")
        object.setValue(Int32(12), forKey: "originalLength")
        object.setValue(2.0, forKey: "processingTime")
        object.setValue(ids.recordingID, forKey: "recordingId")
        object.setValue("[{\"text\":\"follow up\"}]", forKey: "reminders")
        object.setValue("Fixture summary", forKey: "summary")
        object.setValue("[{\"text\":\"task\"}]", forKey: "tasks")
        object.setValue("[{\"text\":\"Fixture\"}]", forKey: "titles")
        object.setValue(ids.transcriptID, forKey: "transcriptId")
        object.setValue(Int32(1), forKey: "version")
        object.setValue(Int32(2), forKey: "wordCount")
    }

    private static func populateProcessingJob(_ object: NSManagedObject, ids: FixtureIDs) {
        object.setValue(Date(timeIntervalSinceReferenceDate: 106), forKey: "completionTime")
        object.setValue("fixture-engine", forKey: "engine")
        object.setValue(nil, forKey: "error")
        object.setValue(ids.jobID, forKey: "id")
        object.setValue("transcription", forKey: "jobType")
        object.setValue(Date(timeIntervalSinceReferenceDate: 105), forKey: "lastModified")
        object.setValue("fixture-model", forKey: "modelName")
        object.setValue(1.0, forKey: "progress")
        object.setValue("Fixture recording", forKey: "recordingName")
        object.setValue("recording.m4a", forKey: "recordingURL")
        object.setValue(Date(timeIntervalSinceReferenceDate: 104), forKey: "startTime")
        object.setValue("complete", forKey: "status")
    }

    private static func populateArchiveLocation(_ object: NSManagedObject, ids: FixtureIDs) {
        object.setValue(Data([1, 2, 3]), forKey: "bookmarkData")
        object.setValue("archive://fixture", forKey: "destinationURLString")
        object.setValue("Fixture archive", forKey: "displayName")
        object.setValue(Date(timeIntervalSinceReferenceDate: 106), forKey: "exportedAt")
        object.setValue("fixture.m4a", forKey: "exportedFilename")
        object.setValue(Int64(42), forKey: "fileSize")
        object.setValue(ids.archiveID, forKey: "id")
        object.setValue(Date(timeIntervalSinceReferenceDate: 107), forKey: "lastVerifiedAt")
        object.setValue("Fixture provider", forKey: "providerDisplayName")
        object.setValue(ids.recordingID, forKey: "recordingId")
        object.setValue("verified", forKey: "status")
    }

    private static func populatePendingMutation(_ object: NSManagedObject, ids: FixtureIDs) {
        object.setValue("update", forKey: "kind")
        object.setValue(Data([4, 5, 6]), forKey: "payload")
        object.setValue(ids.recordingID, forKey: "recordingId")
        object.setValue(Date(timeIntervalSinceReferenceDate: 108), forKey: "requestedAt")
        object.setValue(ids.recordingID, forKey: "targetId")
        object.setValue(Int32(1), forKey: "version")
    }

    private static func sourceEntityPairs(
        in model: NSManagedObjectModel
    ) throws -> [(destinationEntity: SQLiteMigrationSourceEntity, sourceName: String)] {
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
                throw SQLiteMigrationCoreDataSourceFixtureError.missingEntity(sourceName)
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
                    throw SQLiteMigrationCoreDataSourceFixtureError.missingAttribute(
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
            throw SQLiteMigrationCoreDataSourceFixtureError.missingRelatedStorageID(
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
        throw SQLiteMigrationCoreDataSourceFixtureError.unsupportedValue(
            entity: entity,
            column: column,
            type: String(describing: type(of: rawValue))
        )
    }

    private static func sourceObjectID(
        for object: NSManagedObject,
        entity: SQLiteMigrationSourceEntity
    ) throws -> String {
        if let id = object.value(forKey: "id") as? UUID {
            return "\(entity.rawValue)|id|\(id.uuidString.lowercased())"
        }
        let uri = object.objectID.uriRepresentation().absoluteString
        guard !uri.isEmpty else {
            throw SQLiteMigrationCoreDataSourceFixtureError.invalidFixtureData(
                "\(entity.rawValue) has no permanent object ID"
            )
        }
        return "\(entity.rawValue)|uri|\(uri)"
    }

    private static func destinationStorageID(
        for object: NSManagedObject,
        entity: SQLiteMigrationSourceEntity,
        sourceObjectID: String
    ) -> String {
        if let id = object.value(forKey: "id") as? UUID {
            return "fixture-\(entity.rawValue)-\(id.uuidString.lowercased())"
        }
        return "fixture-\(entity.rawValue)-\(digest(sourceObjectID).prefix(24))"
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
                canonical += "\(column)=\(canonicalValue(row.values[column]!))\n"
            }
        }
        return digest(canonical)
    }

    private static func canonicalValue(_ value: SQLiteMigrationValue) -> String {
        switch value {
        case .null:
            return "null"
        case .text(let value):
            return "text:\(value)"
        case .integer(let value):
            return "integer:\(value)"
        case .real(let value):
            return "real:\(value)"
        case .blob(let value):
            return "blob:\(value.base64EncodedString())"
        case .boolean(let value):
            return "boolean:\(value ? 1 : 0)"
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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

    private static func insert(
        _ entityName: String,
        into context: NSManagedObjectContext
    ) throws -> NSManagedObject {
        guard let entity = context.persistentStoreCoordinator?
            .managedObjectModel.entitiesByName[entityName] else {
            throw SQLiteMigrationCoreDataSourceFixtureError.missingEntity(entityName)
        }
        return NSManagedObject(entity: entity, insertInto: context)
    }

    private static func compiledModelDirectoryURL() -> URL? {
        var bundles: [Bundle] = [Bundle(for: SQLiteMigrationCoreDataFixtureBundleAnchor.self)]
        bundles.append(Bundle.main)
        bundles.append(contentsOf: Bundle.allBundles)
        return bundles.compactMap {
            $0.url(forResource: "BisonNotes_AI", withExtension: "momd")
        }.first
    }

    private static func fixtureUUID(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw SQLiteMigrationCoreDataSourceFixtureError.invalidFixtureData(value)
        }
        return uuid
    }

    private static func performAndWait<T>(
        on context: NSManagedObjectContext,
        _ work: @escaping () throws -> T
    ) throws -> T {
        let workBox = FixtureWorkBox(work: work)
        context.performAndWait {
            workBox.value = Result { try workBox.work() }
        }
        guard let value = workBox.value else {
            throw SQLiteMigrationCoreDataSourceFixtureError.invalidFixtureData(
                "Core Data context did not return a result"
            )
        }
        return try value.get()
    }

    private struct FixtureIDs {
        let recordingID: UUID
        let transcriptID: UUID
        let summaryID: UUID
        let jobID: UUID
        let archiveID: UUID

        init() throws {
            recordingID = try fixtureUUID("10000000-0000-0000-0000-000000000001")
            transcriptID = try fixtureUUID("10000000-0000-0000-0000-000000000002")
            summaryID = try fixtureUUID("10000000-0000-0000-0000-000000000003")
            jobID = try fixtureUUID("10000000-0000-0000-0000-000000000004")
            archiveID = try fixtureUUID("10000000-0000-0000-0000-000000000005")
        }
    }

    private struct SourceObjectDescriptor {
        let destinationEntity: SQLiteMigrationSourceEntity
        let sourceName: String
        let object: NSManagedObject
        let sourceObjectID: String
        let destinationStorageID: String
    }
}

private final class SQLiteMigrationCoreDataFixtureBundleAnchor: NSObject {}

private final class FixtureWorkBox<T>: @unchecked Sendable {
    let work: () throws -> T
    var value: Result<T, Error>?

    init(work: @escaping () throws -> T) {
        self.work = work
    }
}

private final class StoreLoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var error: Error?

    func set(error: Error?) {
        lock.lock()
        self.error = error
        lock.unlock()
    }
}

// swiftlint:enable file_length type_body_length type_name
