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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            return 0
        }
        return size
    }

    var fileSizeString: String {
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    // Equatable conformance - compare by URL since it's unique
    static func == (lhs: RecordingFile, rhs: RecordingFile) -> Bool {
        return lhs.url == rhs.url
    }
}