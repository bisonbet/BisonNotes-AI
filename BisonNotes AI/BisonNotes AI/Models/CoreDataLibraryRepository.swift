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
            archivedAt: object.value(forKey: "archivedAt") as? Date,
            archiveNote: object.value(forKey: "archiveNote") as? String,
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

    func setArchiveState(
        _ command: LibraryRecordingArchiveCommand
    ) async throws -> LibraryRecordingSnapshot {
        try command.validate()
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

            recording.setValue(command.archived, forKey: "isArchived")
            recording.setValue(command.persistedArchivedAt, forKey: "archivedAt")
            recording.setValue(command.persistedArchiveNote, forKey: "archiveNote")
            recording.setValue(command.modifiedAt, forKey: "lastModified")

            do {
                try context.save()
            } catch {
                throw LibraryRepositoryError.writeFailed(
                    operation: "set archive state",
                    reason: error.localizedDescription
                )
            }

            return try Self.snapshot(from: recording)
        }
    }

    func upsertTranscript(
        _ command: LibraryTranscriptUpsertCommand
    ) async throws -> LibraryTranscriptSnapshot {
        try command.validate()
        let context = context
        return try context.performAndWait {
            let recordingRequest = Self.fetchRequest(entityName: "RecordingEntry")
            recordingRequest.fetchLimit = 2
            recordingRequest.predicate = try Self.recordingPredicate(
                for: command.recordingReference
            )

            let recordings = try context.fetch(recordingRequest)
            guard !recordings.isEmpty else {
                throw LibraryRepositoryError.recordingNotFound(
                    reference: command.recordingReference.displayValue
                )
            }
            guard recordings.count == 1 else {
                throw LibraryRepositoryError.ambiguousRecording(
                    reference: command.recordingReference.displayValue
                )
            }

            let recording = recordings[0]
            guard let recordingID = recording.value(forKey: "id") as? UUID else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "RecordingEntry",
                    field: "id"
                )
            }

            let transcriptRequest = Self.fetchRequest(entityName: "TranscriptEntry")
            transcriptRequest.fetchLimit = 2
            transcriptRequest.predicate = NSPredicate(
                format: "recording == %@ OR recordingId == %@",
                recording,
                recordingID as CVarArg
            )
            let transcripts = try context.fetch(transcriptRequest)
            guard transcripts.count <= 1 else {
                throw LibraryRepositoryError.ambiguousTranscript(
                    reference: command.recordingReference.displayValue
                )
            }

            let transcript: NSManagedObject
            let transcriptID: UUID
            let isNewTranscript = transcripts.isEmpty
            if let existingTranscript = transcripts.first {
                guard let existingID = existingTranscript.value(forKey: "id") as? UUID else {
                    throw LibraryRepositoryError.invalidRecord(
                        entity: "TranscriptEntry",
                        field: "id"
                    )
                }
                transcript = existingTranscript
                transcriptID = existingID
            } else {
                let collisionRequest = Self.fetchRequest(entityName: "TranscriptEntry")
                collisionRequest.fetchLimit = 2
                collisionRequest.predicate = NSPredicate(
                    format: "id == %@",
                    command.id as CVarArg
                )
                guard try context.fetch(collisionRequest).isEmpty else {
                    throw LibraryRepositoryError.transcriptAlreadyExists(
                        reference: command.id.uuidString.lowercased()
                    )
                }

                transcript = NSEntityDescription.insertNewObject(
                    forEntityName: "TranscriptEntry",
                    into: context
                )
                transcriptID = command.id
                transcript.setValue(command.id, forKey: "id")
                transcript.setValue(command.createdAt, forKey: "createdAt")
            }

            transcript.setValue(recordingID, forKey: "recordingId")
            transcript.setValue(command.modifiedAt, forKey: "lastModified")
            transcript.setValue(command.engine, forKey: "engine")
            transcript.setValue(command.processingTime, forKey: "processingTime")
            transcript.setValue(command.confidence, forKey: "confidence")
            transcript.setValue(command.segments, forKey: "segments")
            transcript.setValue(command.speakerMappings, forKey: "speakerMappings")
            transcript.setValue(recording, forKey: "recording")

            recording.setValue(transcript, forKey: "transcript")
            recording.setValue(transcriptID, forKey: "transcriptId")
            recording.setValue("Completed", forKey: "transcriptionStatus")
            recording.setValue(command.modifiedAt, forKey: "lastModified")

            do {
                try context.save()
            } catch {
                if isNewTranscript {
                    context.delete(transcript)
                }
                throw LibraryRepositoryError.writeFailed(
                    operation: "upsert transcript",
                    reason: error.localizedDescription
                )
            }

            return try Self.transcriptSnapshot(from: transcript)
        }
    }

    func upsertSummary(
        _ command: LibrarySummaryUpsertCommand
    ) async throws -> LibrarySummarySnapshot {
        try command.validate()
        let context = context
        return try context.performAndWait {
            let recordingRequest = Self.fetchRequest(entityName: "RecordingEntry")
            recordingRequest.fetchLimit = 2
            recordingRequest.predicate = try Self.recordingPredicate(
                for: command.recordingReference
            )

            let recordings = try context.fetch(recordingRequest)
            guard !recordings.isEmpty else {
                throw LibraryRepositoryError.recordingNotFound(
                    reference: command.recordingReference.displayValue
                )
            }
            guard recordings.count == 1 else {
                throw LibraryRepositoryError.ambiguousRecording(
                    reference: command.recordingReference.displayValue
                )
            }

            let recording = recordings[0]
            guard let recordingID = recording.value(forKey: "id") as? UUID else {
                throw LibraryRepositoryError.invalidRecord(
                    entity: "RecordingEntry",
                    field: "id"
                )
            }

            let summaryRequest = Self.fetchRequest(entityName: "SummaryEntry")
            summaryRequest.fetchLimit = 2
            summaryRequest.sortDescriptors = [
                NSSortDescriptor(key: "generatedAt", ascending: false)
            ]
            summaryRequest.predicate = NSPredicate(
                format: "recording == %@ OR recordingId == %@",
                recording,
                recordingID as CVarArg
            )
            let summaries = try context.fetch(summaryRequest)
            guard summaries.count <= 1 else {
                throw LibraryRepositoryError.ambiguousSummary(
                    reference: command.recordingReference.displayValue
                )
            }

            let summary: NSManagedObject
            let summaryID: UUID
            let isNewSummary = summaries.isEmpty
            if let existingSummary = summaries.first {
                guard let existingID = existingSummary.value(forKey: "id") as? UUID else {
                    throw LibraryRepositoryError.invalidRecord(
                        entity: "SummaryEntry",
                        field: "id"
                    )
                }
                summary = existingSummary
                summaryID = existingID
            } else {
                let collisionRequest = Self.fetchRequest(entityName: "SummaryEntry")
                collisionRequest.fetchLimit = 2
                collisionRequest.predicate = NSPredicate(
                    format: "id == %@",
                    command.id as CVarArg
                )
                guard try context.fetch(collisionRequest).isEmpty else {
                    throw LibraryRepositoryError.summaryAlreadyExists(
                        reference: command.id.uuidString.lowercased()
                    )
                }

                summary = NSEntityDescription.insertNewObject(
                    forEntityName: "SummaryEntry",
                    into: context
                )
                summaryID = command.id
                summary.setValue(command.id, forKey: "id")
            }

            let resolvedTranscript: NSManagedObject?
            if let transcriptID = command.transcriptID {
                let transcriptRequest = Self.fetchRequest(entityName: "TranscriptEntry")
                transcriptRequest.fetchLimit = 2
                transcriptRequest.predicate = NSPredicate(
                    format: "id == %@",
                    transcriptID as CVarArg
                )
                let transcripts = try context.fetch(transcriptRequest)
                guard !transcripts.isEmpty else {
                    throw LibraryRepositoryError.transcriptNotFound(
                        reference: transcriptID.uuidString.lowercased()
                    )
                }
                guard transcripts.count == 1 else {
                    throw LibraryRepositoryError.ambiguousTranscript(
                        reference: transcriptID.uuidString.lowercased()
                    )
                }
                resolvedTranscript = transcripts[0]
            } else {
                resolvedTranscript = nil
            }

            summary.setValue(recordingID, forKey: "recordingId")
            if isNewSummary {
                summary.setValue(nil, forKey: "transcriptId")
                summary.setValue(nil, forKey: "transcript")
            }
            if let transcriptID = command.transcriptID {
                summary.setValue(transcriptID, forKey: "transcriptId")
                summary.setValue(resolvedTranscript, forKey: "transcript")
            }
            summary.setValue(command.generatedAt, forKey: "generatedAt")
            summary.setValue(command.aiMethod, forKey: "aiMethod")
            summary.setValue(command.processingTime, forKey: "processingTime")
            summary.setValue(command.confidence, forKey: "confidence")
            summary.setValue(command.summary, forKey: "summary")
            summary.setValue(command.contentType, forKey: "contentType")
            summary.setValue(command.wordCount, forKey: "wordCount")
            summary.setValue(command.originalLength, forKey: "originalLength")
            summary.setValue(command.compressionRatio, forKey: "compressionRatio")
            summary.setValue(command.version, forKey: "version")
            summary.setValue(command.tasks, forKey: "tasks")
            summary.setValue(command.reminders, forKey: "reminders")
            summary.setValue(command.titles, forKey: "titles")
            summary.setValue(recording, forKey: "recording")

            recording.setValue(summary, forKey: "summary")
            recording.setValue(summaryID, forKey: "summaryId")
            recording.setValue(ProcessingStatus.completed.rawValue, forKey: "summaryStatus")
            recording.setValue(command.generatedAt, forKey: "lastModified")

            do {
                try context.save()
            } catch {
                if isNewSummary {
                    context.delete(summary)
                }
                throw LibraryRepositoryError.writeFailed(
                    operation: "upsert summary",
                    reason: error.localizedDescription
                )
            }

            return try Self.summarySnapshot(from: summary)
        }
    }

    func createProcessingJob(
        _ command: LibraryProcessingJobCreateCommand
    ) async throws -> LibraryProcessingJobSnapshot {
        try command.validate()
        let context = context
        return try context.performAndWait {
            let duplicateRequest = Self.fetchRequest(entityName: "ProcessingJobEntry")
            duplicateRequest.fetchLimit = 2
            duplicateRequest.predicate = NSPredicate(
                format: "id == %@",
                command.id as CVarArg
            )
            guard try context.fetch(duplicateRequest).isEmpty else {
                throw LibraryRepositoryError.processingJobAlreadyExists(
                    reference: command.id.uuidString.lowercased()
                )
            }

            let recording: NSManagedObject?
            if let reference = command.recordingReference {
                let request = Self.fetchRequest(entityName: "RecordingEntry")
                request.fetchLimit = 2
                request.predicate = try Self.recordingPredicate(for: reference)
                let matches = try context.fetch(request)
                guard !matches.isEmpty else {
                    throw LibraryRepositoryError.recordingNotFound(
                        reference: reference.displayValue
                    )
                }
                guard matches.count == 1 else {
                    throw LibraryRepositoryError.ambiguousRecording(
                        reference: reference.displayValue
                    )
                }
                recording = matches[0]
            } else {
                recording = nil
            }

            let job = ProcessingJobEntry(context: context)
            job.id = command.id
            job.jobType = command.jobType
            job.engine = command.engine
            job.recordingURL = command.recordingURL
            job.recordingName = command.recordingName
            job.modelName = command.modelName
            job.status = command.status
            job.progress = command.progress
            job.startTime = command.startTime
            job.completionTime = command.completionTime
            job.error = command.error
            job.lastModified = command.modifiedAt
            job.setValue(recording, forKey: "recording")

            do {
                try context.save()
            } catch {
                context.delete(job)
                throw LibraryRepositoryError.writeFailed(
                    operation: "create processing job",
                    reason: error.localizedDescription
                )
            }

            return try Self.processingJobSnapshot(from: job)
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

    func deleteTerminalProcessingJobs(
        _ command: LibraryProcessingJobTerminalCleanupCommand
    ) async throws -> [LibraryProcessingJobSnapshot] {
        try command.validate()
        let terminalStatuses = Set(command.normalizedStatuses)
        let context = context
        return try context.performAndWait {
            let jobs = try context.fetch(Self.fetchRequest(entityName: "ProcessingJobEntry"))
                .filter { job in
                    guard let status = job.value(forKey: "status") as? String else {
                        return false
                    }
                    return terminalStatuses.contains(
                        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    )
                }
            let snapshots = try jobs.map(Self.processingJobSnapshot(from:))
            guard !jobs.isEmpty else {
                return []
            }

            jobs.forEach(context.delete)
            do {
                try context.save()
            } catch {
                throw LibraryRepositoryError.writeFailed(
                    operation: "delete terminal processing jobs",
                    reason: error.localizedDescription
                )
            }
            return snapshots
        }
    }

    func recoverProcessingJobsAfterCrash(
        _ command: LibraryProcessingJobCrashRecoveryCommand
    ) async throws -> [LibraryProcessingJobSnapshot] {
        try command.validate()
        let terminalStatuses = Set(["completed", "failed", "cancelled"])
        let context = context
        return try context.performAndWait {
            var jobs: [NSManagedObject] = []
            var seenObjectIDs = Set<String>()

            for reference in command.references {
                let request = Self.fetchRequest(entityName: "ProcessingJobEntry")
                request.fetchLimit = 2
                request.predicate = try Self.processingJobPredicate(for: reference)
                let matches = try context.fetch(request)
                guard matches.count <= 1 else {
                    throw LibraryRepositoryError.ambiguousProcessingJob(
                        reference: reference.displayValue
                    )
                }
                guard let job = matches.first else {
                    continue
                }
                let objectID = job.objectID.uriRepresentation().absoluteString
                guard seenObjectIDs.insert(objectID).inserted else {
                    continue
                }
                jobs.append(job)
            }

            let jobsToRecover = jobs.filter { job in
                guard let status = job.value(forKey: "status") as? String else {
                    return true
                }
                return !terminalStatuses.contains(
                    status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            }
            guard !jobsToRecover.isEmpty else {
                return []
            }

            for job in jobsToRecover {
                job.setValue(command.status, forKey: "status")
                job.setValue(command.failureMessage, forKey: "error")
                job.setValue(command.modifiedAt, forKey: "completionTime")
                job.setValue(command.modifiedAt, forKey: "lastModified")
            }

            do {
                try context.save()
            } catch {
                throw LibraryRepositoryError.writeFailed(
                    operation: "recover processing jobs after crash",
                    reason: error.localizedDescription
                )
            }
            return try jobsToRecover.map(Self.processingJobSnapshot(from:))
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
