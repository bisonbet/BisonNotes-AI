import Foundation

/// Storage-neutral recording values returned by the first repository boundary.
///
/// The snapshot deliberately contains values that can be copied out of either
/// Core Data or SQLite. It does not expose managed objects, GRDB rows, or
/// mutable relationships to callers.
struct LibraryRecordingSnapshot: Equatable, Sendable {
    let storageID: String
    let legacyID: String?
    let name: String?
    let recordingDate: Date?
    let duration: Double?
    let fileSize: Int64?
    let recordingURL: String?
    let isArchived: Bool?
    let lastModified: Date?

    static func stableOrder(
        _ lhs: LibraryRecordingSnapshot,
        _ rhs: LibraryRecordingSnapshot
    ) -> Bool {
        switch (lhs.recordingDate, rhs.recordingDate) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate < rightDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.storageID < rhs.storageID
        }
    }
}

/// The deliberately small read-only contract used while the migration is
/// being introduced. Existing Core Data callers remain authoritative until a
/// later checkpoint wires this capability into application startup.
protocol LibraryRepository {
    func fetchRecordingSummaries() async throws -> [LibraryRecordingSnapshot]
}

enum LibraryRepositoryError: LocalizedError, Equatable {
    case invalidRecord(entity: String, field: String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord(let entity, let field):
            return "The \(entity) record has an invalid \(field) value."
        }
    }
}
