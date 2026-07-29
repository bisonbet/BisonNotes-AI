//
//  Persistence.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/26/25.
//

import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext
        // Note: Core Data entities are RecordingEntry, SummaryEntry, and TranscriptEntry
        // This preview code is not used in the actual app
        // for _ in 0..<10 {
        //     let newItem = Item(context: viewContext)
        //     newItem.timestamp = Date()
        // }
        do {
            try viewContext.save()
        } catch {
            AppLog.shared.coreData("Preview Core Data save failed: \(error.localizedDescription)", level: .error)
        }
        return result
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        let persistentContainer = NSPersistentContainer(name: "BisonNotes_AI")
        if inMemory {
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
