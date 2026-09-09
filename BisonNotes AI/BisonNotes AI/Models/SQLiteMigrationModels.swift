import Foundation

/// Immutable state returned by the durable migration checkpoint store.
struct SQLiteMigrationRun: Equatable, Sendable {
    let id: String
    let sourceFingerprint: String
    let importerVersion: String
    let sourceModel: String?
    let phase: String
    let status: String
    let metadataTotal: Int?
    let metadataCompleted: Int
    let batchCursor: Data?
    let batchCount: Int
    let batchSHA256: String?
    let startedAt: Date
    let updatedAt: Date
    let errorMessage: String?
}
