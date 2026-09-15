import Foundation

struct RecordingArchiveLocationInfo: Identifiable, Equatable {
    let id: UUID
    let recordingId: UUID
    let providerDisplayName: String
    let displayName: String
    let exportedFilename: String
    let destinationURLString: String?
    let exportedAt: Date?
    let fileSize: Int64
    let status: String

    var exportedAtString: String? {
        guard let exportedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: exportedAt)
    }
}

enum RecordingArchiveError: LocalizedError {
    case noArchiveLocation
    case locationNotFound
    case unableToResolveLocation
    case sourceMissing(String)
    case copyFailed(String)
    case deleteFailed(String)
    case invalidAudio(String)

    var errorDescription: String? {
        switch self {
        case .noArchiveLocation:
            return "No archive location is saved for this recording."
        case .locationNotFound:
            return "The saved archive location could not be found."
        case .unableToResolveLocation:
            return "The saved archive location is no longer accessible."
        case .sourceMissing(let name):
            return "The archived audio file could not be found: \(name)"
        case .copyFailed(let reason):
            return "Could not download archived audio: \(reason)"
        case .deleteFailed(let reason):
            return "Downloaded audio, but could not remove the archived copy: \(reason)"
        case .invalidAudio(let reason):
            return "Downloaded file is not valid audio: \(reason)"
        }
    }
}
