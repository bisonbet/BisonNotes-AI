import Foundation

/// The durable entity names used by the repository change stream.
enum LibraryChangeEntity: String, CaseIterable, Equatable, Sendable {
    case recording
    case transcript
    case summary
    case processingJob
    case archiveLocation
    case pendingCloudMutation
    case setting
}

enum LibraryChangeOperation: String, Equatable, Sendable {
    case inserted
    case updated
    case deleted
}

/// One committed repository change. The cursor is global to a library
/// generation, so an observer can resume without relying on wall-clock time
/// or an in-memory notification.
struct LibraryChange: Equatable, Sendable {
    let revision: Int64
    let entity: LibraryChangeEntity
    let storageID: String
    let operation: LibraryChangeOperation
    let committedAt: Date
}

protocol LibraryObservation: Sendable {
    func currentRevision() async throws -> Int64
    func changes(since revision: Int64) async throws -> [LibraryChange]
}

enum LibraryObservationError: LocalizedError, Equatable {
    case invalidCursor(Int64)
    case cursorAhead(current: Int64, requested: Int64)
    case missingStoredChange(revision: Int64)
    case invalidStoredChange(revision: Int64)
    case historyUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidCursor(let revision):
            return "The library observation cursor is invalid: \(revision)"
        case .cursorAhead(let current, let requested):
            return "The library observation cursor \(requested) is ahead of the current revision \(current)."
        case .missingStoredChange(let revision):
            return "The library change at revision \(revision) is missing."
        case .invalidStoredChange(let revision):
            return "The library change at revision \(revision) is invalid."
        case .historyUnavailable(let reason):
            return "Core Data persistent history is unavailable: \(reason)"
        }
    }
}
