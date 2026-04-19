import Foundation
import CoreLocation

// MARK: - Recording File Structure

struct RecordingFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    let date: Date
    let duration: TimeInterval
    let locationData: LocationData?

    // Archive metadata
    let isArchived: Bool
    let archivedAt: Date?
    let archiveNote: String?
    let recordingId: UUID?
    let storedFileSize: Int64

    init(url: URL, name: String, date: Date, duration: TimeInterval,
         locationData: LocationData? = nil, isArchived: Bool = false,
         archivedAt: Date? = nil, archiveNote: String? = nil,
         recordingId: UUID? = nil, storedFileSize: Int64 = 0) {
        self.url = url
        self.name = name
        self.date = date
        self.duration = duration
        self.locationData = locationData
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.archiveNote = archiveNote
        self.recordingId = recordingId
        self.storedFileSize = storedFileSize
    }

    var dateString: String {
        return UserPreferences.shared.formatMediumDateTime(date)
    }

    var durationString: String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    var fileSize: Int64 {
        // For archived recordings whose local file is gone, use stored size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int64 {
            return size
        }
        return storedFileSize
    }

    var fileSizeString: String {
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var hasLocalAudio: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    var archivedAtString: String? {
        guard let archivedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: archivedAt)
    }

    // Equatable conformance - compare by URL since it's unique
    static func == (lhs: RecordingFile, rhs: RecordingFile) -> Bool {
        return lhs.url == rhs.url
    }
}