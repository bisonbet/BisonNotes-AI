import CoreData
import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

// The fixture intentionally enumerates the complete six-entity contract so
// the source-reader test remains auditable beside the production mapping.
// swiftlint:disable function_body_length
final class CoreDataSnapshotReaderRuntimeTests: XCTestCase {
    func testReadsAllSupportedEntitiesAndRelationshipStorageIDs() async throws {
        let storeURL = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("BisonNotesCoreDataSnapshotReader-\(UUID().uuidString).sqlite")
        let container = try makeContainer(at: storeURL)
        defer {
            try? container.persistentStoreCoordinator.persistentStores.forEach { store in
                try container.persistentStoreCoordinator.remove(store)
            }
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(storeURL.path)-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: "\(storeURL.path)-wal"))
        }

        let context = container.viewContext
        let recording = NSEntityDescription.insertNewObject(
            forEntityName: "RecordingEntry",
            into: context
        )
        recording.setValue(UUID(uuidString: "20000000-0000-0000-0000-000000000001"), forKey: "id")
        recording.setValue("Reader fixture", forKey: "recordingName")
        recording.setValue(7.5, forKey: "duration")

        let transcript = NSEntityDescription.insertNewObject(
            forEntityName: "TranscriptEntry",
            into: context
        )
        transcript.setValue(UUID(uuidString: "20000000-0000-0000-0000-000000000002"), forKey: "id")
        transcript.setValue(recording, forKey: "recording")
        recording.setValue(transcript, forKey: "transcript")

        let summary = NSEntityDescription.insertNewObject(
            forEntityName: "SummaryEntry",
            into: context
        )
        summary.setValue(UUID(uuidString: "20000000-0000-0000-0000-000000000003"), forKey: "id")
        summary.setValue(recording, forKey: "recording")
        summary.setValue(transcript, forKey: "transcript")
        recording.setValue(summary, forKey: "summary")

        let processingJob = NSEntityDescription.insertNewObject(
            forEntityName: "ProcessingJobEntry",
            into: context
        )
        processingJob.setValue(UUID(uuidString: "20000000-0000-0000-0000-000000000004"), forKey: "id")
        processingJob.setValue(recording, forKey: "recording")

        let archiveLocation = NSEntityDescription.insertNewObject(
            forEntityName: "RecordingArchiveLocationEntry",
            into: context
        )
        archiveLocation.setValue(UUID(uuidString: "20000000-0000-0000-0000-000000000005"), forKey: "id")

        let pendingMutation = NSEntityDescription.insertNewObject(
            forEntityName: "PendingCloudMutation",
            into: context
        )
        pendingMutation.setValue("update", forKey: "kind")
        pendingMutation.setValue(UUID(uuidString: "20000000-0000-0000-0000-000000000001"), forKey: "targetId")
        try context.save()

        let snapshot = try await CoreDataMigrationSnapshotReader(
            container: container,
            sourceModel: "runtime-reader-fixture"
        ).snapshot()

        XCTAssertEqual(snapshot.rows.count, 6)
        let recordingRow = try XCTUnwrap(snapshot.rows.first { $0.entity == .recordings })
        let transcriptRow = try XCTUnwrap(snapshot.rows.first { $0.entity == .transcripts })
        let summaryRow = try XCTUnwrap(snapshot.rows.first { $0.entity == .summaries })
        let processingJobRow = try XCTUnwrap(snapshot.rows.first { $0.entity == .processingJobs })
        let pendingRow = try XCTUnwrap(snapshot.rows.first { $0.entity == .pendingCloudMutations })

        XCTAssertEqual(recordingRow.values["duration"], .real(7.5))
        XCTAssertEqual(
            transcriptRow.values["recordingStorageID"],
            .text(recordingRow.destinationStorageID)
        )
        XCTAssertEqual(
            summaryRow.values["recordingStorageID"],
            .text(recordingRow.destinationStorageID)
        )
        XCTAssertEqual(
            summaryRow.values["transcriptStorageID"],
            .text(transcriptRow.destinationStorageID)
        )
        XCTAssertEqual(
            processingJobRow.values["recordingStorageID"],
            .text(recordingRow.destinationStorageID)
        )
        XCTAssertTrue(pendingRow.sourceObjectID.hasPrefix("pending_cloud_mutations|uri|"))
    }

    private func makeContainer(at storeURL: URL) throws -> NSPersistentContainer {
        let model = makeModel()
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false

        let container = NSPersistentContainer(
            name: "CoreDataMigrationSnapshotReaderRuntimeTests",
            managedObjectModel: model
        )
        container.persistentStoreDescriptions = [description]

        let result = ReaderStoreLoadResult()
        let group = DispatchGroup()
        group.enter()
        container.loadPersistentStores { _, error in
            result.set(error: error)
            group.leave()
        }
        group.wait()
        if let error = result.error {
            throw error
        }
        return container
    }

    private func makeModel() -> NSManagedObjectModel {
        let recording = entity(
            "RecordingEntry",
            attributes: [
                ("audioQuality", .stringAttributeType), ("createdAt", .dateAttributeType),
                ("duration", .doubleAttributeType), ("fileSize", .integer64AttributeType),
                ("id", .UUIDAttributeType), ("isCloudSyncDisabled", .booleanAttributeType),
                ("lastModified", .dateAttributeType), ("locationAccuracy", .doubleAttributeType),
                ("locationAddress", .stringAttributeType), ("locationLatitude", .doubleAttributeType),
                ("locationLongitude", .doubleAttributeType), ("locationTimestamp", .dateAttributeType),
                ("recordingDate", .dateAttributeType), ("recordingName", .stringAttributeType),
                ("recordingURL", .stringAttributeType), ("summaryId", .UUIDAttributeType),
                ("summaryStatus", .stringAttributeType), ("transcriptId", .UUIDAttributeType),
                ("transcriptionStatus", .stringAttributeType), ("isArchived", .booleanAttributeType),
                ("archivedAt", .dateAttributeType), ("archiveNote", .stringAttributeType)
            ]
        )
        let summary = entity(
            "SummaryEntry",
            attributes: [
                ("aiMethod", .stringAttributeType), ("compressionRatio", .doubleAttributeType),
                ("confidence", .doubleAttributeType), ("contentType", .stringAttributeType),
                ("generatedAt", .dateAttributeType), ("id", .UUIDAttributeType),
                ("originalLength", .integer32AttributeType), ("processingTime", .doubleAttributeType),
                ("recordingId", .UUIDAttributeType), ("reminders", .stringAttributeType),
                ("summary", .stringAttributeType), ("tasks", .stringAttributeType),
                ("titles", .stringAttributeType), ("transcriptId", .UUIDAttributeType),
                ("version", .integer32AttributeType), ("wordCount", .integer32AttributeType)
            ]
        )
        let transcript = entity(
            "TranscriptEntry",
            attributes: [
                ("confidence", .doubleAttributeType), ("createdAt", .dateAttributeType),
                ("engine", .stringAttributeType), ("id", .UUIDAttributeType),
                ("lastModified", .dateAttributeType), ("processingTime", .doubleAttributeType),
                ("recordingId", .UUIDAttributeType), ("segments", .stringAttributeType),
                ("speakerMappings", .stringAttributeType)
            ]
        )
        let processingJob = entity(
            "ProcessingJobEntry",
            attributes: [
                ("completionTime", .dateAttributeType), ("engine", .stringAttributeType),
                ("error", .stringAttributeType), ("id", .UUIDAttributeType),
                ("jobType", .stringAttributeType), ("lastModified", .dateAttributeType),
                ("modelName", .stringAttributeType), ("progress", .doubleAttributeType),
                ("recordingName", .stringAttributeType), ("recordingURL", .stringAttributeType),
                ("startTime", .dateAttributeType), ("status", .stringAttributeType)
            ]
        )
        let archiveLocation = entity(
            "RecordingArchiveLocationEntry",
            attributes: [
                ("bookmarkData", .binaryDataAttributeType), ("destinationURLString", .stringAttributeType),
                ("displayName", .stringAttributeType), ("exportedAt", .dateAttributeType),
                ("exportedFilename", .stringAttributeType), ("fileSize", .integer64AttributeType),
                ("id", .UUIDAttributeType), ("lastVerifiedAt", .dateAttributeType),
                ("providerDisplayName", .stringAttributeType), ("recordingId", .UUIDAttributeType),
                ("status", .stringAttributeType)
            ]
        )
        let pendingMutation = entity(
            "PendingCloudMutation",
            attributes: [
                ("kind", .stringAttributeType), ("payload", .binaryDataAttributeType),
                ("recordingId", .UUIDAttributeType), ("requestedAt", .dateAttributeType),
                ("targetId", .UUIDAttributeType), ("version", .integer32AttributeType)
            ]
        )

        recording.properties += [
            relationship("summary", destination: summary),
            relationship("transcript", destination: transcript)
        ]
        summary.properties += [
            relationship("recording", destination: recording),
            relationship("transcript", destination: transcript)
        ]
        transcript.properties.append(relationship("recording", destination: recording))
        processingJob.properties.append(relationship("recording", destination: recording))
        return model(entities: [
            recording, summary, transcript, processingJob, archiveLocation, pendingMutation
        ])
    }

    private func entity(
        _ name: String,
        attributes: [(String, NSAttributeType)]
    ) -> NSEntityDescription {
        let result = NSEntityDescription()
        result.name = name
        result.managedObjectClassName = "NSManagedObject"
        result.properties = attributes.map { name, type in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = true
            return attribute
        }
        return result
    }

    private func relationship(
        _ name: String,
        destination: NSEntityDescription
    ) -> NSRelationshipDescription {
        let result = NSRelationshipDescription()
        result.name = name
        result.destinationEntity = destination
        result.minCount = 0
        result.maxCount = 1
        result.deleteRule = .nullifyDeleteRule
        return result
    }

    private func model(entities: [NSEntityDescription]) -> NSManagedObjectModel {
        let result = NSManagedObjectModel()
        result.entities = entities
        return result
    }
}

private final class ReaderStoreLoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var error: Error?

    func set(error: Error?) {
        lock.lock()
        self.error = error
        lock.unlock()
    }
}
// swiftlint:enable function_body_length
