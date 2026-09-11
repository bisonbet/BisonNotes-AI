import CoreData
import Foundation

/// The complete source input passed to the isolated migration coordinator.
///
/// Metadata and settings must be captured while the caller has quiesced both
/// Core Data writes and settings mutations. The reader deliberately does not
/// attempt to pause application work itself; the future startup gate owns that
/// coordination policy.
struct CoreDataMigrationInputSnapshot: Equatable, Sendable {
    let metadata: SQLiteMigrationSourceSnapshot
    let settings: LibrarySettingsSnapshot
}

/// Reads a closed Core Data source plus an explicitly inventoried settings
/// domain without mutating either source.
///
/// `sourceKeys` is required instead of inferred from `UserDefaults` so a new
/// or forgotten application key fails closed at the migration boundary. The
/// caller must supply the app-owned key inventory, not the global defaults
/// domain, and must keep the source quiesced until the returned snapshot is
/// handed to the coordinator.
final class CoreDataMigrationInputReader: @unchecked Sendable {
    private let metadataReader: CoreDataMigrationSnapshotReader
    private let defaults: UserDefaults

    convenience init(
        container: NSPersistentContainer,
        defaults: UserDefaults = .standard,
        sourceModel: String? = nil
    ) {
        self.init(
            metadataReader: CoreDataMigrationSnapshotReader(
                container: container,
                sourceModel: sourceModel
            ),
            defaults: defaults
        )
    }

    convenience init(
        context: NSManagedObjectContext,
        defaults: UserDefaults = .standard,
        sourceModel: String
    ) {
        self.init(
            metadataReader: CoreDataMigrationSnapshotReader(
                context: context,
                sourceModel: sourceModel
            ),
            defaults: defaults
        )
    }

    private init(
        metadataReader: CoreDataMigrationSnapshotReader,
        defaults: UserDefaults
    ) {
        self.metadataReader = metadataReader
        self.defaults = defaults
    }

    func snapshot(sourceKeys: [String]) async throws -> CoreDataMigrationInputSnapshot {
        let settings = try await LibrarySettingsCatalog.readMigratableSettings(
            from: defaults,
            sourceKeys: sourceKeys
        )
        let metadata = try await metadataReader.snapshot()
        return CoreDataMigrationInputSnapshot(
            metadata: metadata,
            settings: settings
        )
    }

    /// Captures the reviewed main application defaults domain.
    ///
    /// The explicit overload remains available for fixture isolation and
    /// future platform-specific composition. Production startup should use
    /// this overload so a caller cannot accidentally omit a catalogued key.
    func snapshot() async throws -> CoreDataMigrationInputSnapshot {
        try await snapshot(sourceKeys: LibrarySettingsSourceInventory.standardDefaultsKeys)
    }
}
