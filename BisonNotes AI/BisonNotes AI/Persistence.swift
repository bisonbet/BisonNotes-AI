//
//  Persistence.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/26/25.
//

import CoreData

// MARK: - Durable Cloud Mutation Outbox

/// The five kinds of cloud removal work that used to live in separate
/// UserDefaults arrays. They deliberately stay distinct at the sync boundary,
/// while sharing one Core Data entity so local content deletion and its durable
/// cloud intent can commit in one SQLite transaction.
enum PendingCloudMutationKind: String, CaseIterable {
    case recordingDeletion
    case localOnlyRemoval
    case summaryRemoval
    case transcriptRemoval
    case importedAudioRemoval
}

struct PendingCloudMutation: Equatable {
    let kind: PendingCloudMutationKind
    let targetId: UUID
    var recordingId: UUID?
    var transcriptIds: [UUID]
    var summaryIds: [UUID]
    var requestedAt: Date

    init(
        kind: PendingCloudMutationKind,
        targetId: UUID,
        recordingId: UUID? = nil,
        transcriptIds: [UUID] = [],
        summaryIds: [UUID] = [],
        requestedAt: Date
    ) {
        self.kind = kind
        self.targetId = targetId
        self.recordingId = recordingId
        self.transcriptIds = Array(Set(transcriptIds)).sorted { $0.uuidString < $1.uuidString }
        self.summaryIds = Array(Set(summaryIds)).sorted { $0.uuidString < $1.uuidString }
        self.requestedAt = requestedAt
    }
}

enum PendingCloudMutationStoreError: LocalizedError {
    case invalidRow(String)
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidRow(let detail):
            return "Pending cloud mutation row is invalid: \(detail)"
        case .invalidPayload(let detail):
            return "Pending cloud mutation payload is invalid: \(detail)"
        }
    }
}

/// Persistence and migration for the durable cloud-removal outbox.
///
/// This type intentionally works with `NSManagedObject` rather than generated
/// model classes. The entity is internal bookkeeping, and using KVC keeps the
/// model version migration independent of Xcode's code-generation mode.
enum PendingCloudMutationStore {
    static let entityName = "PendingCloudMutation"
    static let payloadVersion: Int32 = 1

    private static let legacyDeletionMarkersKey = "iCloudPendingDeletionMarkersV1"
    private static let legacyLocalOnlyRemovalsKey = "iCloudPendingLocalOnlyRemovalsV1"
    private static let legacySummaryRemovalsKey = "iCloudPendingSummaryRemovalsV1"
    private static let legacyTranscriptRemovalsKey = "iCloudPendingTranscriptRemovalsV1"
    private static let legacyImportedAudioRemovalsKey = "iCloudPendingImportedAudioRemovalsV1"

    static let legacyQueueKeys = [
        legacyDeletionMarkersKey,
        legacyLocalOnlyRemovalsKey,
        legacySummaryRemovalsKey,
        legacyTranscriptRemovalsKey,
        legacyImportedAudioRemovalsKey
    ]

    /// Cheap enough to sit in front of every outbox read: once the upgrade has
    /// happened, none of these keys exist and no context is built at all.
    static func hasLegacyQueues(in defaults: UserDefaults = .standard) -> Bool {
        legacyQueueKeys.contains { defaults.object(forKey: $0) != nil }
    }

    private struct Payload: Codable, Equatable {
        var transcriptIds: [UUID]
        var summaryIds: [UUID]
    }

    private struct LegacyDeletionMarker: Codable {
        let recordingId: UUID
        var transcriptIds: [UUID]
        var summaryIds: [UUID]
        let requestedAt: Date
    }

    private struct LegacyLocalOnlyRemoval: Codable {
        let recordingId: UUID
        let requestedAt: Date
    }

    private struct LegacySummaryRemoval: Codable {
        let summaryId: UUID
        var recordingId: UUID?
        let requestedAt: Date
    }

    private struct LegacyTranscriptRemoval: Codable {
        let transcriptId: UUID
        var recordingId: UUID?
        let requestedAt: Date
    }

    private struct LegacyImportedAudioRemoval: Codable {
        let recordingId: UUID
        let requestedAt: Date
    }

    /// Merges a mutation into the row with the same kind and target identity.
    /// The earliest request time is load-bearing for cross-device arbitration.
    static func enqueue(_ mutation: PendingCloudMutation, in context: NSManagedObjectContext) throws {
        let matches = try matchingObjects(for: mutation, in: context)
        var merged = mutation

        for object in matches {
            let existing = try decode(object)
            merged.requestedAt = min(merged.requestedAt, existing.requestedAt)
            if merged.recordingId == nil {
                merged.recordingId = existing.recordingId
            }
            merged.transcriptIds = Array(
                Set(merged.transcriptIds + existing.transcriptIds)
            ).sorted { $0.uuidString < $1.uuidString }
            merged.summaryIds = Array(
                Set(merged.summaryIds + existing.summaryIds)
            ).sorted { $0.uuidString < $1.uuidString }
        }

        let object = matches.first
            ?? NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
        try write(merged, to: object)

        for duplicate in matches.dropFirst() {
            context.delete(duplicate)
        }
    }

    static func fetchAll(in context: NSManagedObjectContext) throws -> [PendingCloudMutation] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.sortDescriptors = [NSSortDescriptor(key: "requestedAt", ascending: true)]
        return try context.fetch(request).map(decode)
    }

    /// Removes only rows that still equal the snapshot sent to CloudKit. A
    /// changed payload or relationship id stays queued for the next replay.
    @discardableResult
    static func removeIfUnchanged(
        _ snapshot: PendingCloudMutation,
        from context: NSManagedObjectContext
    ) throws -> Bool {
        let matches = try matchingObjects(for: snapshot, in: context)
        var removed = false
        for object in matches where try decode(object) == snapshot {
            context.delete(object)
            removed = true
        }
        return removed
    }

    /// Stages the removal without saving, like `remove` and `enqueue`, so the
    /// caller decides which transaction it belongs to.
    static func removeAll(in context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        for object in try context.fetch(request) {
            context.delete(object)
        }
    }

    static func remove(
        kind: PendingCloudMutationKind,
        targetId: UUID,
        from context: NSManagedObjectContext
    ) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(
            format: "kind == %@ AND targetId == %@",
            kind.rawValue,
            targetId as CVarArg
        )
        for object in try context.fetch(request) {
            context.delete(object)
        }
    }

    static func removeAll(
        kind: PendingCloudMutationKind,
        from context: NSManagedObjectContext
    ) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(format: "kind == %@", kind.rawValue)
        for object in try context.fetch(request) {
            context.delete(object)
        }
    }

    static func count(in context: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.resultType = .countResultType
        return (try? context.count(for: request)) ?? 0
    }

    /// A context that touches nothing but this entity, on the same store as
    /// `context`.
    ///
    /// Every write here is the outbox's alone, so saving one can neither commit
    /// an unrelated caller's staged edits nor — on failure — roll them away.
    /// `viewContext.automaticallyMergesChangesFromParent` carries the result back
    /// to the UI context, and reads go to the store, so rows staged transactionally
    /// with a deletion are still seen once that deletion commits.
    static func makeIsolatedContext(basedOn context: NSManagedObjectContext) -> NSManagedObjectContext? {
        guard let coordinator = context.persistentStoreCoordinator else { return nil }
        let isolated = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        isolated.persistentStoreCoordinator = coordinator
        // Never let a stale registered object answer for a row another context
        // has since changed in the store.
        isolated.stalenessInterval = 0
        isolated.mergePolicy = NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType)
        return isolated
    }

    /// Migrates each legacy queue independently. A malformed queue is left in
    /// UserDefaults, while valid queues can still be moved in the same save.
    ///
    /// The work runs on an isolated context rather than the caller's. Bailing out
    /// when the caller's context was dirty meant a migration could be skipped
    /// silently — `fetchAll` then reported an empty outbox, and a flush walked zero
    /// of the user's pre-upgrade tombstones while reporting success.
    @discardableResult
    static func migrateLegacyQueuesIfNeeded(
        in callerContext: NSManagedObjectContext,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard hasLegacyQueues(in: defaults) else { return false }
        guard let context = makeIsolatedContext(basedOn: callerContext) else {
            AppLog.shared.coreData(
                "Could not migrate pending iCloud mutations: the context has no persistent store coordinator",
                level: .error
            )
            return false
        }

        var keysToClear: [String] = []
        var migratedAny = false

        if let data = defaults.data(forKey: legacyDeletionMarkersKey) {
            do {
                let entries = try JSONDecoder().decode([LegacyDeletionMarker].self, from: data)
                for entry in entries {
                    try enqueue(
                        PendingCloudMutation(
                            kind: .recordingDeletion,
                            targetId: entry.recordingId,
                            transcriptIds: entry.transcriptIds,
                            summaryIds: entry.summaryIds,
                            requestedAt: entry.requestedAt
                        ),
                        in: context
                    )
                }
                keysToClear.append(legacyDeletionMarkersKey)
                migratedAny = migratedAny || !entries.isEmpty
            } catch {
                AppLog.shared.coreData(
                    "Could not migrate pending recording deletions; retaining the legacy queue: \(error)",
                    level: .error
                )
            }
        }

        if let data = defaults.data(forKey: legacyLocalOnlyRemovalsKey) {
            do {
                let entries = try JSONDecoder().decode([LegacyLocalOnlyRemoval].self, from: data)
                for entry in entries {
                    try enqueue(
                        PendingCloudMutation(
                            kind: .localOnlyRemoval,
                            targetId: entry.recordingId,
                            requestedAt: entry.requestedAt
                        ),
                        in: context
                    )
                }
                keysToClear.append(legacyLocalOnlyRemovalsKey)
                migratedAny = migratedAny || !entries.isEmpty
            } catch {
                AppLog.shared.coreData(
                    "Could not migrate pending local-only removals; retaining the legacy queue: \(error)",
                    level: .error
                )
            }
        }

        if let data = defaults.data(forKey: legacySummaryRemovalsKey) {
            do {
                let entries = try JSONDecoder().decode([LegacySummaryRemoval].self, from: data)
                for entry in entries {
                    try enqueue(
                        PendingCloudMutation(
                            kind: .summaryRemoval,
                            targetId: entry.summaryId,
                            recordingId: entry.recordingId,
                            requestedAt: entry.requestedAt
                        ),
                        in: context
                    )
                }
                keysToClear.append(legacySummaryRemovalsKey)
                migratedAny = migratedAny || !entries.isEmpty
            } catch {
                AppLog.shared.coreData(
                    "Could not migrate pending summary removals; retaining the legacy queue: \(error)",
                    level: .error
                )
            }
        }

        if let data = defaults.data(forKey: legacyTranscriptRemovalsKey) {
            do {
                let entries = try JSONDecoder().decode([LegacyTranscriptRemoval].self, from: data)
                for entry in entries {
                    try enqueue(
                        PendingCloudMutation(
                            kind: .transcriptRemoval,
                            targetId: entry.transcriptId,
                            recordingId: entry.recordingId,
                            requestedAt: entry.requestedAt
                        ),
                        in: context
                    )
                }
                keysToClear.append(legacyTranscriptRemovalsKey)
                migratedAny = migratedAny || !entries.isEmpty
            } catch {
                AppLog.shared.coreData(
                    "Could not migrate pending transcript removals; retaining the legacy queue: \(error)",
                    level: .error
                )
            }
        }

        if let data = defaults.data(forKey: legacyImportedAudioRemovalsKey) {
            do {
                let entries = try JSONDecoder().decode([LegacyImportedAudioRemoval].self, from: data)
                for entry in entries {
                    try enqueue(
                        PendingCloudMutation(
                            kind: .importedAudioRemoval,
                            targetId: entry.recordingId,
                            requestedAt: entry.requestedAt
                        ),
                        in: context
                    )
                }
                keysToClear.append(legacyImportedAudioRemovalsKey)
                migratedAny = migratedAny || !entries.isEmpty
            } catch {
                AppLog.shared.coreData(
                    "Could not migrate pending imported-audio removals; retaining the legacy queue: \(error)",
                    level: .error
                )
            }
        }

        guard !keysToClear.isEmpty else { return migratedAny }

        do {
            if context.hasChanges {
                try context.save()
            }
            for key in keysToClear {
                defaults.removeObject(forKey: key)
            }
            return migratedAny
        } catch {
            context.rollback()
            AppLog.shared.coreData(
                "Could not commit pending iCloud mutation migration; legacy queues were retained: \(error)",
                level: .error
            )
            return false
        }
    }

    private static func matchingObjects(
        for mutation: PendingCloudMutation,
        in context: NSManagedObjectContext
    ) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = NSPredicate(
            format: "kind == %@ AND targetId == %@",
            mutation.kind.rawValue,
            mutation.targetId as CVarArg
        )
        request.sortDescriptors = [NSSortDescriptor(key: "requestedAt", ascending: true)]
        return try context.fetch(request)
    }

    private static func write(
        _ mutation: PendingCloudMutation,
        to object: NSManagedObject
    ) throws {
        let payload = Payload(
            transcriptIds: mutation.transcriptIds,
            summaryIds: mutation.summaryIds
        )
        let payloadData: Data
        do {
            payloadData = try JSONEncoder().encode(payload)
        } catch {
            throw PendingCloudMutationStoreError.invalidPayload(error.localizedDescription)
        }

        object.setValue(mutation.kind.rawValue, forKey: "kind")
        object.setValue(mutation.targetId, forKey: "targetId")
        object.setValue(mutation.recordingId, forKey: "recordingId")
        object.setValue(mutation.requestedAt, forKey: "requestedAt")
        object.setValue(payloadData, forKey: "payload")
        object.setValue(payloadVersion, forKey: "version")
    }

    private static func decode(_ object: NSManagedObject) throws -> PendingCloudMutation {
        guard let rawKind = object.value(forKey: "kind") as? String,
              let kind = PendingCloudMutationKind(rawValue: rawKind) else {
            throw PendingCloudMutationStoreError.invalidRow("unknown mutation kind")
        }
        guard let targetId = object.value(forKey: "targetId") as? UUID else {
            throw PendingCloudMutationStoreError.invalidRow("missing target identity")
        }
        guard let requestedAt = object.value(forKey: "requestedAt") as? Date else {
            throw PendingCloudMutationStoreError.invalidRow("missing requestedAt")
        }

        let version = (object.value(forKey: "version") as? NSNumber)?.int32Value ?? 0
        guard version == payloadVersion else {
            throw PendingCloudMutationStoreError.invalidPayload("unsupported payload version \(version)")
        }

        let payload: Payload
        if let data = object.value(forKey: "payload") as? Data {
            do {
                payload = try JSONDecoder().decode(Payload.self, from: data)
            } catch {
                throw PendingCloudMutationStoreError.invalidPayload(error.localizedDescription)
            }
        } else {
            payload = Payload(transcriptIds: [], summaryIds: [])
        }

        return PendingCloudMutation(
            kind: kind,
            targetId: targetId,
            recordingId: object.value(forKey: "recordingId") as? UUID,
            transcriptIds: payload.transcriptIds,
            summaryIds: payload.summaryIds,
            requestedAt: requestedAt
        )
    }
}

struct PersistenceController {
    /// Core Data's container and view context are confined to the main actor.
    /// The shared controller is only used to construct the main-actor data
    /// managers; it is not a Sendable value that may cross actor boundaries.
    @MainActor
    static let shared = PersistenceController()

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext
        // Note: Core Data entities are RecordingEntry, SummaryEntry, and TranscriptEntry
        // This preview code is not used in the actual app
        do {
            try viewContext.save()
        } catch {
            AppLog.shared.coreData("Preview Core Data save failed: \(error.localizedDescription)", level: .error)
        }
        return result
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false, storeURL: URL? = nil) {
        let persistentContainer = NSPersistentContainer(name: "BisonNotes_AI")
        if let storeURL {
            persistentContainer.persistentStoreDescriptions.first?.url = storeURL
        } else if inMemory {
            persistentContainer.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        persistentContainer.persistentStoreDescriptions.forEach { description in
            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
            #if os(iOS)
            // iOS Data Protection; macOS relies on FileVault for encryption at rest.
            description.setOption(
                AppFileProtection.sensitiveFileProtection.rawValue as NSString,
                forKey: NSPersistentStoreFileProtectionKey
            )
            #endif
        }
        persistentContainer.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                Self.handlePersistentStoreLoadFailure(error, container: persistentContainer, inMemory: inMemory)
                return
            }

            if let storeURL = storeDescription.url, !inMemory {
                AppFileProtection.apply(to: storeURL)
                AppFileProtection.apply(to: URL(fileURLWithPath: storeURL.path + "-wal"))
                AppFileProtection.apply(to: URL(fileURLWithPath: storeURL.path + "-shm"))
            }
        })
        container = persistentContainer
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    private static func handlePersistentStoreLoadFailure(_ error: NSError,
                                                         container: NSPersistentContainer,
                                                         inMemory: Bool) {
        AppLog.shared.coreData(
            "Core Data persistent store failed to load: \(error.localizedDescription) userInfo=\(error.userInfo)",
            level: .fault
        )

        guard !inMemory else { return }

        do {
            try container.persistentStoreCoordinator.addPersistentStore(
                ofType: NSInMemoryStoreType,
                configurationName: nil,
                at: nil,
                options: nil
            )
            AppLog.shared.coreData(
                "Loaded temporary in-memory Core Data fallback after persistent store failure. Existing recordings may be unavailable until the app restarts successfully.",
                level: .error
            )
        } catch {
            AppLog.shared.coreData(
                "Failed to load in-memory Core Data fallback after persistent store failure: \(error.localizedDescription)",
                level: .fault
            )
        }
    }
}
