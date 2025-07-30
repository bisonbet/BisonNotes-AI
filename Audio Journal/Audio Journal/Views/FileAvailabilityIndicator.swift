import SwiftUI

// MARK: - File Availability Indicator View

struct FileAvailabilityIndicator: View {
    let status: FileAvailabilityStatus
    let showLabel: Bool
    let size: IndicatorSize
    
    init(status: FileAvailabilityStatus, showLabel: Bool = true, size: IndicatorSize = .medium) {
        self.status = status
        self.showLabel = showLabel
        self.size = size
    }
    
    var body: some View {
        HStack(spacing: size.spacing) {
            Image(systemName: status.icon)
                .font(size.iconFont)
                .foregroundColor(colorForStatus(status))
            
            if showLabel {
                Text(status.rawValue)
                    .font(size.textFont)
                    .foregroundColor(colorForStatus(status))
            }
        }
        .help(status.description)
    }
    
    private func colorForStatus(_ status: FileAvailabilityStatus) -> Color {
        switch status.color {
        case "green":
            return .green
        case "blue":
            return .blue
        case "orange":
            return .orange
        case "purple":
            return .purple
        case "gray":
            return .gray
        default:
            return .primary
        }
    }
}

enum IndicatorSize {
    case small
    case medium
    case large
    
    var iconFont: Font {
        switch self {
        case .small:
            return .caption
        case .medium:
            return .body
        case .large:
            return .title3
        }
    }
    
    var textFont: Font {
        switch self {
        case .small:
            return .caption2
        case .medium:
            return .caption
        case .large:
            return .body
        }
    }
    
    var spacing: CGFloat {
        switch self {
        case .small:
            return 2
        case .medium:
            return 4
        case .large:
            return 6
        }
    }
}

// MARK: - File Relationship Summary View

struct FileRelationshipSummary: View {
    let relationships: FileRelationships
    let showDetails: Bool
    
    init(relationships: FileRelationships, showDetails: Bool = false) {
        self.relationships = relationships
        self.showDetails = showDetails
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                FileAvailabilityIndicator(
                    status: relationships.availabilityStatus,
                    showLabel: true,
                    size: .medium
                )
                
                Spacer()
                
                if relationships.iCloudSynced {
                    Image(systemName: "icloud.fill")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .help("Synced to iCloud")
                }
            }
            
            if showDetails {
                VStack(alignment: .leading, spacing: 2) {
                    FileDetailRow(
                        icon: "waveform",
                        label: "Recording",
                        available: relationships.hasRecording,
                        color: .blue
                    )
                    
                    FileDetailRow(
                        icon: "text.quote",
                        label: "Transcript",
                        available: relationships.transcriptExists,
                        color: .purple
                    )
                    
                    FileDetailRow(
                        icon: "doc.text",
                        label: "Summary",
                        available: relationships.summaryExists,
                        color: .orange
                    )
                }
                .font(.caption2)
                .padding(.leading, 8)
            }
            
            if relationships.isOrphaned {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text("Audio source no longer available")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                .padding(.top, 2)
            }
        }
    }
}

struct FileDetailRow: View {
    let icon: String
    let label: String
    let available: Bool
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(available ? color : .gray)
                .frame(width: 12)
            
            Text(label)
                .foregroundColor(available ? .primary : .secondary)
            
            Spacer()
            
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                .font(.caption2)
                .foregroundColor(available ? .green : .gray)
        }
    }
}

// MARK: - Preview

struct FileAvailabilityIndicator_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            Group {
                FileAvailabilityIndicator(status: .complete)
                FileAvailabilityIndicator(status: .recordingOnly)
                FileAvailabilityIndicator(status: .summaryOnly)
                FileAvailabilityIndicator(status: .transcriptOnly)
                FileAvailabilityIndicator(status: .none)
            }
            
            Divider()
            
            let sampleRelationships = FileRelationships(
                recordingURL: URL(fileURLWithPath: "/sample.m4a"),
                recordingName: "Sample Recording",
                recordingDate: Date(),
                transcriptExists: true,
                summaryExists: true,
                iCloudSynced: true
            )
            
            FileRelationshipSummary(relationships: sampleRelationships, showDetails: true)
            
            let orphanedRelationships = FileRelationships(
                recordingURL: nil,
                recordingName: "Orphaned Recording",
                recordingDate: Date(),
                transcriptExists: false,
                summaryExists: true,
                iCloudSynced: false
            )
            
            FileRelationshipSummary(relationships: orphanedRelationships, showDetails: true)
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}