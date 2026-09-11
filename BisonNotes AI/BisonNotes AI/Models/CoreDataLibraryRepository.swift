import CoreData
import CryptoKit
import Foundation

/// Read-only repository adapter over the current Core Data context.
///
/// The adapter copies values while it owns the fetch and never returns managed
/// objects. It is intentionally standalone: application startup still uses
/// the existing Core Data manager until the migration coordinator is ready.
final class CoreDataLibraryRepository: LibraryRepository, @unchecked Sendable {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func fetchRecordingSummaries() async throws -> [LibraryRecordingSnapshot] {
        let context = context
        return try context.performAndWait {
            try context.fetch(Self.fetchRequest(entityName: "RecordingEntry"))
                .map(Self.snapshot(from:))
                .sorted(by: LibraryRecordingSnapshot.stableOrder)
        }
    }

    func fetchTranscriptSnapshots() async throws -> [LibraryTranscriptSnapshot] {
        let context = context
        return try context.performAndWait {
            try context.fetch(Self.fetchRequest(entityName: "TranscriptEntry"))
                .map(Self.transcriptSnapshot(from:))
                .sorted { $0.storageID < $1.storageID }
        }
    }

    func fetchSummarySnapshots() async throws -> [LibrarySummarySnapshot] {
        let context = context
        return try context.performAndWait {
            try context.fetch(Self.fetchRequest(entityName: "SummaryEntry"))
                .map(Self.summarySnapshot(from:))
                .sorted { $0.storageID < $1.storageID }
        }
    }

    func fetchProcessingJobSnapshots() async throws -> [LibraryProcessingJobSnapshot] {
        let context = context
        return try context.performAndWait {
            try context.fetch(Self.fetchRequest(entityName: "ProcessingJobEntry"))
                .map(Self.processingJobSnapshot(from:))
                .sorted { $0.storageID < $1.storageID }
        }
    }

    func fetchArchiveLocationSnapshots() async throws -> [LibraryArchiveLocationSnapshot] {
        let context = context
        return try context.performAndWait {
            try context.fetch(Self.fetchRequest(entityName: "RecordingArchiveLocationEntry"))
                .map(Self.archiveLocationSnapshot(from:))
                .sorted { $0.storageID < $1.storageID }
        }
    }

    func fetchPendingCloudMutationSnapshots() async throws -> [LibraryPendingCloudMutationSnapshot] {
        let context = context
        return try context.performAndWait {
            try context.fetch(Self.fetchRequest(entityName: "PendingCloudMutation"))
                .map(Self.pendingCloudMutationSnapshot(from:))
                .sorted { $0.storageID < $1.storageID }
        }
    }

    private static func snapshot(from object: NSManagedObject) throws -> LibraryRecordingSnapshot {
        let storageID = try storageID(for: object, entityName: "RecordingEntry")
        return LibraryRecordingSnapshot(
            storageID: storageID,
            legacyID: identifier(from: object.value(forKey: "id")),
            name: object.value(forKey: "recordingName") as? String,
            recordingDate: object.value(forKey: "recordingDate") as? Date,
            duration: (object.value(forKey: "duration") as? NSNumber)?.doubleValue,
            fileSize: (object.value(forKey: "fileSize") as? NSNumber)?.int64Value,
            recordingURL: object.value(forKey: "recordingURL") as? String,
            isArchived: (object.value(forKey: "isArchived") as? NSNumber)?.boolValue,
            isCloudSyncDisabled: (object.value(forKey: "isCloudSyncDisabled") as? NSNumber)?.boolValue,
            lastModified: object.value(forKey: "lastModified") as? Date
        )
    }

    private static func transcriptSnapshot(
        from object: NSManagedObject
    ) throws -> LibraryTranscriptSnapshot {
        LibraryTranscriptSnapshot(
            storageID: try storageID(for: object, entityName: "TranscriptEntry"),
            legacyID: identifier(from: object.value(forKey: "id")),
            confidence: number(from: object, key: "confidence")?.doubleValue,
            createdAt: object.value(forKey: "createdAt") as? Date,
            engine: object.value(forKey: "engine") as? String,
            lastModified: object.value(forKey: "lastModified") as? Date,
            processingTime: number(from: object, key: "processingTime")?.doubleValue,
            recordingStorageID: try relatedStorageID(
                from: object,
                relationship: "recording"
            ),
            recordingLegacyID: relatedLegacyID(
                from: object,
                relationship: "recording"
            ),
            segments: object.value(forKey: "segments") as? String,
            speakerMappings: object.value(forKey: "speakerMappings") as? String
        )
    }

    private static func summarySnapshot(
        from object: NSManagedObject
    ) throws -> LibrarySummarySnapshot {
        LibrarySummarySnapshot(
            storageID: try storageID(for: object, entityName: "SummaryEntry"),
            aiMethod: object.value(forKey: "aiMethod") as? String,
            compressionRatio: number(from: object, key: "compressionRatio")?.doubleValue,
            confidence: number(from: object, key: "confidence")?.doubleValue,
            contentType: object.value(forKey: "contentType") as? String,
            generatedAt: object.value(forKey: "generatedAt") as? Date,
            legacyID: identifier(from: object.value(forKey: "id")),
            originalLength: number(from: object, key: "originalLength")?.int64Value,
            processingTime: number(from: object, key: "processingTime")?.doubleValue,
            recordingStorageID: try relatedStorageID(
                from: object,
                relationship: "recording"
            ),
            recordingLegacyID: relatedLegacyID(
                from: object,
                relationship: "recording"
            ),
            reminders: object.value(forKey: "reminders") as? String,
            summary: object.value(forKey: "summary") as? String,
            tasks: object.value(forKey: "tasks") as? String,
            titles: object.value(forKey: "titles") as? String,
            transcriptStorageID: try relatedStorageID(
                from: object,
                relationship: "transcript"
            ),
            transcriptLegacyID: relatedLegacyID(
                from: object,
                relationship: "transcript"
            ),
            version: number(from: object, key: "version")?.int64Value,
            wordCount: number(from: object, key: "wordCount")?.int64Value
        )
    }

    private static func processingJobSnapshot(
        from object: NSManagedObject
    ) throws -> LibraryProcessingJobSnapshot {
        LibraryProcessingJobSnapshot(
            storageID: try storageID(for: object, entityName: "ProcessingJobEntry"),
            completionTime: object.value(forKey: "completionTime") as? Date,
            engine: object.value(forKey: "engine") as? String,
            error: object.value(forKey: "error") as? String,
            legacyID: identifier(from: object.value(forKey: "id")),
            jobType: object.value(forKey: "jobType") as? String,
            lastModified: object.value(forKey: "lastModified") as? Date,
            modelName: object.value(forKey: "modelName") as? String,
            progress: number(from: object, key: "progress")?.doubleValue,
            recordingName: object.value(forKey: "recordingName") as? String,
            recordingURL: object.value(forKey: "recordingURL") as? String,
            recordingStorageID: try relatedStorageID(
                from: object,
                relationship: "recording"
            ),
            startTime: object.value(forKey: "startTime") as? Date,
            status: object.value(forKey: "status") as? String
        )
    }

    private static func archiveLocationSnapshot(
        from object: NSManagedObject
    ) throws -> LibraryArchiveLocationSnapshot {
        LibraryArchiveLocationSnapshot(
            storageID: try storageID(
                for: object,
                entityName: "RecordingArchiveLocationEntry"
            ),
            bookmarkData: object.value(forKey: "bookmarkData") as? Data,
            destinationURLString: object.value(forKey: "destinationURLString") as? String,
            displayName: object.value(forKey: "displayName") as? String,
            exportedAt: object.value(forKey: "exportedAt") as? Date,
            exportedFilename: object.value(forKey: "exportedFilename") as? String,
            fileSize: number(from: object, key: "fileSize")?.int64Value,
            legacyID: identifier(from: object.value(forKey: "id")),
            lastVerifiedAt: object.value(forKey: "lastVerifiedAt") as? Date,
            providerDisplayName: object.value(forKey: "providerDisplayName") as? String,
            recordingLegacyID: identifier(from: object.value(forKey: "recordingId")),
            status: object.value(forKey: "status") as? String
        )
    }

    private static func pendingCloudMutationSnapshot(
        from object: NSManagedObject
    ) throws -> LibraryPendingCloudMutationSnapshot {
        LibraryPendingCloudMutationSnapshot(
            storageID: try storageID(for: object, entityName: "PendingCloudMutation"),
            kind: object.value(forKey: "kind") as? String,
            payload: object.value(forKey: "payload") as? Data,
            recordingLegacyID: identifier(from: object.value(forKey: "recordingId")),
            requestedAt: object.value(forKey: "requestedAt") as? Date,
            targetID: identifier(from: object.value(forKey: "targetId")),
            version: number(from: object, key: "version")?.int64Value
        )
    }

    private static func fetchRequest(
        entityName: String
    ) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.returnsObjectsAsFaults = false
        return request
    }

    private static func storageID(
        for object: NSManagedObject,
        entityName: String
    ) throws -> String {
        let prefix = entityName.replacingOccurrences(of: "Entry", with: "").lowercased()
        if object.entity.attributesByName["id"] != nil,
           let legacyID = identifier(from: object.value(forKey: "id")) {
            return "core-data-\(prefix)-\(legacyID)"
        }

        let sourceObjectID = object.objectID.uriRepresentation().absoluteString
        guard !sourceObjectID.isEmpty else {
            throw LibraryRepositoryError.invalidRecord(
                entity: entityName,
                field: "id"
            )
        }
        return "core-data-\(prefix)-uri-\(digest(sourceObjectID).prefix(24))"
    }

    private static func relatedStorageID(
        from object: NSManagedObject,
        relationship: String
    ) throws -> String? {
        guard let related = object.value(forKey: relationship) as? NSManagedObject else {
            return nil
        }
        return try storageID(
            for: related,
            entityName: related.entity.name ?? "Related"
        )
    }

    private static func relatedLegacyID(
        from object: NSManagedObject,
        relationship: String
    ) -> String? {
        guard let related = object.value(forKey: relationship) as? NSManagedObject else {
            return nil
        }
        return identifier(from: related.value(forKey: "id"))
    }

    private static func identifier(from value: Any?) -> String? {
        if let uuid = value as? UUID {
            return uuid.uuidString.lowercased()
        }
        if let string = value as? String, !string.isEmpty {
            return string
        }
        return nil
    }

    private static func number(
        from object: NSManagedObject,
        key: String
    ) -> NSNumber? {
        object.value(forKey: key) as? NSNumber
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension CoreDataLibraryRepository {
    func renameRecording(
        _ command: LibraryRecordingRenameCommand
    ) async throws -> LibraryRecordingSnapshot {
        let context = context
        return try context.performAndWait {
            let request = Self.fetchRequest(entityName: "RecordingEntry")
            request.fetchLimit = 2
            request.predicate = try Self.recordingPredicate(for: command.reference)

            let matches = try context.fetch(request)
            guard !matches.isEmpty else {
                throw LibraryRepositoryError.recordingNotFound(
                    reference: command.reference.displayValue
                )
            }
            guard matches.count == 1 else {
                throw LibraryRepositoryError.ambiguousRecording(
                    reference: command.reference.displayValue
                )
            }

            let recording = matches[0]
            let current = try Self.snapshot(from: recording)
            guard command.expectedLastModified == nil
                    || command.expectedLastModified == current.lastModified else {
                throw LibraryRepositoryError.staleRecording(
                    reference: command.reference.displayValue,
                    expected: command.expectedLastModified,
                    actual: current.lastModified
                )
            }

            recording.setValue(command.normalizedName, forKey: "recordingName")
            recording.setValue(command.modifiedAt, forKey: "lastModified")

            do {
                try context.save()
            } catch {
                throw LibraryRepositoryError.writeFailed(
                    operation: "rename recording",
                    reason: error.localizedDescription
                )
            }

            return try Self.snapshot(from: recording)
        }
    }

    func setCloudSyncDisabled(
        _ command: LibraryRecordingCloudSyncCommand
    ) async throws -> LibraryRecordingSnapshot {
        let context = context
        return try context.performAndWait {
            let request = Self.fetchRequest(entityName: "RecordingEntry")
            request.fetchLimit = 2
            request.predicate = try Self.recordingPredicate(for: command.reference)

            let matches = try context.fetch(request)
            guard !matches.isEmpty else {
                throw LibraryRepositoryError.recordingNotFound(
                    reference: command.reference.displayValue
                )
            }
            guard matches.count == 1 else {
                throw LibraryRepositoryError.ambiguousRecording(
                    reference: command.reference.displayValue
                )
            }

            let recording = matches[0]
            let current = try Self.snapshot(from: recording)
            guard command.expectedLastModified == nil
                    || command.expectedLastModified == current.lastModified else {
                throw LibraryRepositoryError.staleRecording(
                    reference: command.reference.displayValue,
                    expected: command.expectedLastModified,
                    actual: current.lastModified
                )
            }

            guard let legacyID = current.legacyID,
                  let targetID = UUID(uuidString: legacyID) else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "RecordingEntry",
                    field: "id"
                )
            }

            recording.setValue(command.disabled, forKey: "isCloudSyncDisabled")
            recording.setValue(command.modifiedAt, forKey: "lastModified")
            if command.disabled {
                try PendingCloudMutationStore.enqueue(
                    PendingCloudMutation(
                        kind: .localOnlyRemoval,
                        targetId: targetID,
                        requestedAt: command.requestedAt
                    ),
                    in: context
                )
            } else {
                try PendingCloudMutationStore.remove(
                    kind: .localOnlyRemoval,
                    targetId: targetID,
                    from: context
                )
            }

            do {
                try context.save()
            } catch {
                throw LibraryRepositoryError.writeFailed(
                    operation: "set cloud sync preference",
                    reason: error.localizedDescription
                )
            }

            return try Self.snapshot(from: recording)
        }
    }

    func updateProcessingJob(
        _ command: LibraryProcessingJobUpdateCommand
    ) async throws -> LibraryProcessingJobSnapshot {
        try command.validate()
        let context = context
        return try context.performAndWait {
            let request = Self.fetchRequest(entityName: "ProcessingJobEntry")
            request.fetchLimit = 2
            request.predicate = try Self.processingJobPredicate(for: command.reference)

            let matches = try context.fetch(request)
            guard !matches.isEmpty else {
                throw LibraryRepositoryError.processingJobNotFound(
                    reference: command.reference.displayValue
                )
            }
            guard matches.count == 1 else {
                throw LibraryRepositoryError.ambiguousProcessingJob(
                    reference: command.reference.displayValue
                )
            }

            let job = matches[0]
            let current = try Self.processingJobSnapshot(from: job)
            guard command.expectedLastModified == nil
                    || command.expectedLastModified == current.lastModified else {
                throw LibraryRepositoryError.staleProcessingJob(
                    reference: command.reference.displayValue,
                    expected: command.expectedLastModified,
                    actual: current.lastModified
                )
            }

            let error: String?
            switch command.error {
            case .preserve:
                error = current.error
            case .set(let value):
                error = value
            }

            let completionTime: Date?
            switch command.completionTime {
            case .preserve:
                completionTime = current.completionTime
            case .set(let value):
                completionTime = value
            }

            job.setValue(command.status, forKey: "status")
            job.setValue(command.progress, forKey: "progress")
            job.setValue(error, forKey: "error")
            job.setValue(completionTime, forKey: "completionTime")
            job.setValue(command.modifiedAt, forKey: "lastModified")

            do {
                try context.save()
            } catch {
                throw LibraryRepositoryError.writeFailed(
                    operation: "update processing job",
                    reason: error.localizedDescription
                )
            }

            return try Self.processingJobSnapshot(from: job)
        }
    }

    func deleteProcessingJob(
        _ command: LibraryProcessingJobDeleteCommand
    ) async throws -> LibraryProcessingJobSnapshot {
        guard command.deletedAt.timeIntervalSinceReferenceDate.isFinite,
              command.expectedLastModified?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job deletion dates must be finite"
            )
        }
        let context = context
        return try context.performAndWait {
            let request = Self.fetchRequest(entityName: "ProcessingJobEntry")
            request.fetchLimit = 2
            request.predicate = try Self.processingJobPredicate(for: command.reference)

            let matches = try context.fetch(request)
            guard !matches.isEmpty else {
                throw LibraryRepositoryError.processingJobNotFound(
                    reference: command.reference.displayValue
                )
            }
            guard matches.count == 1 else {
                throw LibraryRepositoryError.ambiguousProcessingJob(
                    reference: command.reference.displayValue
                )
            }

            let job = matches[0]
            let current = try Self.processingJobSnapshot(from: job)
            guard command.expectedLastModified == nil
                    || command.expectedLastModified == current.lastModified else {
                throw LibraryRepositoryError.staleProcessingJob(
                    reference: command.reference.displayValue,
                    expected: command.expectedLastModified,
                    actual: current.lastModified
                )
            }

            context.delete(job)
            do {
                try context.save()
            } catch {
                throw LibraryRepositoryError.writeFailed(
                    operation: "delete processing job",
                    reason: error.localizedDescription
                )
            }
            return current
        }
    }

    private static func recordingPredicate(
        for reference: LibraryRecordingReference
    ) throws -> NSPredicate {
        if let legacyID = reference.legacyID {
            guard let uuid = UUID(uuidString: legacyID) else {
                throw LibraryRepositoryError.invalidCommand(
                    "recording legacy ID is not a UUID"
                )
            }
            return NSPredicate(format: "id == %@", uuid as CVarArg)
        }

        guard let storageID = reference.storageID,
              storageID.hasPrefix("core-data-recording-") else {
            throw LibraryRepositoryError.invalidCommand(
                "Core Data requires a recording legacy ID or a resolvable storage ID"
            )
        }

        let legacyID = String(storageID.dropFirst("core-data-recording-".count))
        guard let uuid = UUID(uuidString: legacyID) else {
            throw LibraryRepositoryError.invalidCommand(
                "Core Data storage ID does not contain a resolvable UUID"
            )
        }
        return NSPredicate(format: "id == %@", uuid as CVarArg)
    }

    private static func processingJobPredicate(
        for reference: LibraryProcessingJobReference
    ) throws -> NSPredicate {
        if let legacyID = reference.legacyID {
            guard let uuid = UUID(uuidString: legacyID) else {
                throw LibraryRepositoryError.invalidCommand(
                    "processing-job legacy ID is not a UUID"
                )
            }
            return NSPredicate(format: "id == %@", uuid as CVarArg)
        }

        guard let storageID = reference.storageID,
              storageID.hasPrefix("core-data-processingjob-") else {
            throw LibraryRepositoryError.invalidCommand(
                "Core Data requires a processing-job legacy ID or a resolvable storage ID"
            )
        }

        let legacyID = String(storageID.dropFirst("core-data-processingjob-".count))
        guard let uuid = UUID(uuidString: legacyID) else {
            throw LibraryRepositoryError.invalidCommand(
                "Core Data processing-job storage ID does not contain a resolvable UUID"
            )
        }
        return NSPredicate(format: "id == %@", uuid as CVarArg)
    }
}
