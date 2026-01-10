import Foundation
import UIKit
import MapKit

/// Errors that can occur during RTF document generation
enum RTFExportError: LocalizedError {
    case documentGenerationFailed(String)
    case invalidDocumentData
    case memoryLimitExceeded

    var errorDescription: String? {
        switch self {
        case .documentGenerationFailed(let reason):
            return "Failed to generate RTF document: \(reason)"
        case .invalidDocumentData:
            return "Invalid document data - unable to create RTF document"
        case .memoryLimitExceeded:
            return "Document too large - memory limit exceeded during generation"
        }
    }
}

final class RTFExportService {
    static let shared = RTFExportService()

    private init() {}

    @MainActor
    func generateDocument(
        summaryData: EnhancedSummaryData,
        locationData: LocationData?,
        locationAddress: String?
    ) throws -> Data {
        print("✅ RTFExportService: Starting document generation for \(summaryData.recordingName)")

        // Validate input data
        guard !summaryData.recordingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("❌ RTFExportService: Invalid summary data - recording name is empty")
            throw RTFExportError.invalidDocumentData
        }
        
        let document = NSMutableAttributedString()

        do {
            appendTitle(for: summaryData, to: document)
            appendMetadata(for: summaryData, to: document)

            if let locationData {
                appendLocationSection(
                    summaryData: summaryData,
                    locationData: locationData,
                    locationAddress: locationAddress,
                    to: document
                )
            }

            appendSummarySection(for: summaryData, to: document)

            // Always include sections even if empty to match PDF export quality
            if !summaryData.tasks.isEmpty {
                appendTasksSection(tasks: summaryData.tasks, to: document)
            }

            if !summaryData.reminders.isEmpty {
                appendRemindersSection(reminders: summaryData.reminders, to: document)
            }

            if !summaryData.titles.isEmpty {
                appendTitlesSection(titles: summaryData.titles, to: document)
            }

            // Always include processing details
            appendProcessingDetails(for: summaryData, to: document)

            // Check document size before conversion
            let documentLength = document.length
            guard documentLength > 0 else {
                print("❌ RTFExportService: Generated document is empty")
                throw RTFExportError.invalidDocumentData
            }

            // Conservative memory limit check (10MB of attributed string)
            let estimatedMemoryUsage = documentLength * 100 // Rough estimate
            if estimatedMemoryUsage > 10_000_000 {
                print("❌ RTFExportService: Document too large, estimated memory usage: \(estimatedMemoryUsage) bytes")
                throw RTFExportError.memoryLimitExceeded
            }

            let documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [
                .documentType: NSAttributedString.DocumentType.rtf
            ]

            print("✅ RTFExportService: Converting attributed string to RTF document data")
            let data = try document.data(from: NSRange(location: 0, length: documentLength), documentAttributes: documentAttributes)

            guard !data.isEmpty else {
                print("❌ RTFExportService: Generated document data is empty")
                throw RTFExportError.invalidDocumentData
            }

            print("✅ RTFExportService: Successfully generated RTF document (\(data.count) bytes)")
            return data

        } catch let error as RTFExportError {
            throw error
        } catch {
            print("❌ RTFExportService: Document generation failed with error: \(error.localizedDescription)")
            throw RTFExportError.documentGenerationFailed(error.localizedDescription)
        }
    }

    // MARK: - Sections

    private func appendTitle(for summaryData: EnhancedSummaryData, to document: NSMutableAttributedString) {
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        titleStyle.paragraphSpacing = 12

        let title = NSAttributedString(
            string: "\(summaryData.recordingName)\n",
            attributes: [
                .font: UIFont.boldSystemFont(ofSize: 26),
                .foregroundColor: UIColor.label,
                .paragraphStyle: titleStyle
            ]
        )
        document.append(title)
    }

    private func appendMetadata(for summaryData: EnhancedSummaryData, to document: NSMutableAttributedString) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short

        let metadataStyle = NSMutableParagraphStyle()
        metadataStyle.alignment = .center
        metadataStyle.paragraphSpacing = 3
        metadataStyle.lineSpacing = 2

        // Create rich metadata with labels and values
        let metadata = NSMutableAttributedString()

        let items = [
            ("Recording Date: ", dateFormatter.string(from: summaryData.recordingDate)),
            ("AI Engine: ", summaryData.aiEngine),
            ("AI Model: ", summaryData.aiModel),
            ("Content Type: ", summaryData.contentType.rawValue),
            ("Generated: ", DateFormatter.localizedString(from: summaryData.generatedAt, dateStyle: .medium, timeStyle: .short))
        ]

        for (label, value) in items {
            let labelAttr = NSAttributedString(
                string: label,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: metadataStyle
                ]
            )

            let valueAttr = NSAttributedString(
                string: value + "\n",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: metadataStyle
                ]
            )

            metadata.append(labelAttr)
            metadata.append(valueAttr)
        }

        metadata.append(NSAttributedString(string: "\n"))
        document.append(metadata)
    }

    private func appendLocationSection(
        summaryData: EnhancedSummaryData,
        locationData: LocationData,
        locationAddress: String?,
        to document: NSMutableAttributedString
    ) {
        appendSectionTitle("📍 Location", to: document)

        // Note: Map images are not included in RTF export as they have unreliable support
        // across different RTF readers. Use PDF export for map visualization.

        let infoStyle = NSMutableParagraphStyle()
        infoStyle.paragraphSpacing = 4
        infoStyle.lineSpacing = 2

        // Build location details with rich formatting
        let locationDetails = NSMutableAttributedString()

        // Address (if available)
        if let address = locationAddress, !address.isEmpty {
            let addressAttr = NSAttributedString(
                string: address + "\n",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: infoStyle
                ]
            )
            locationDetails.append(addressAttr)
        } else if let address = locationData.address, !address.isEmpty {
            let addressAttr = NSAttributedString(
                string: address + "\n",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: infoStyle
                ]
            )
            locationDetails.append(addressAttr)
        }

        // Coordinates
        let coordLabel = NSAttributedString(
            string: "Coordinates: ",
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: infoStyle
            ]
        )
        let coordValue = NSAttributedString(
            string: "\(String(format: "%.5f", locationData.latitude)), \(String(format: "%.5f", locationData.longitude))\n",
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: UIColor.label,
                .paragraphStyle: infoStyle
            ]
        )
        locationDetails.append(coordLabel)
        locationDetails.append(coordValue)

        // Accuracy (if available)
        if let accuracy = locationData.accuracy {
            let accuracyLabel = NSAttributedString(
                string: "Accuracy: ",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: infoStyle
                ]
            )
            let accuracyValue = NSAttributedString(
                string: String(format: "±%.0f meters\n", accuracy),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: infoStyle
                ]
            )
            locationDetails.append(accuracyLabel)
            locationDetails.append(accuracyValue)
        }

        locationDetails.append(NSAttributedString(string: "\n"))
        document.append(locationDetails)
    }

    private func appendSummarySection(for summaryData: EnhancedSummaryData, to document: NSMutableAttributedString) {
        appendSectionTitle("📄 Summary", to: document)

        let cleaned = SummaryExportFormatter.cleanMarkdown(summaryData.summary)
        let flattened = SummaryExportFormatter.flattenMarkdown(cleaned)

        let summaryStyle = NSMutableParagraphStyle()
        summaryStyle.lineSpacing = 5
        summaryStyle.paragraphSpacing = 10
        summaryStyle.firstLineHeadIndent = 0
        summaryStyle.alignment = .left

        let summary = NSAttributedString(
            string: flattened + "\n\n",
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.label,
                .paragraphStyle: summaryStyle,
                .kern: 0.2  // Slight letter spacing for better readability
            ]
        )

        document.append(summary)
    }

    private func appendTasksSection(tasks: [TaskItem], to document: NSMutableAttributedString) {
        appendSectionTitle("✅ Tasks (\(tasks.count))", to: document)

        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.lineSpacing = 3
        style.firstLineHeadIndent = 0
        style.headIndent = 20

        for task in tasks {
            let priorityColor = colorForPriority(task.priority)
            let taskText = "• [\(task.priority.rawValue)] \(task.displayText)\n"

            let attributedTask = NSAttributedString(
                string: taskText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12),
                    .foregroundColor: priorityColor,
                    .paragraphStyle: style
                ]
            )
            document.append(attributedTask)
        }

        document.append(NSAttributedString(string: "\n"))
    }

    private func colorForPriority(_ priority: TaskItem.Priority) -> UIColor {
        switch priority {
        case .high: return UIColor.systemRed
        case .medium: return UIColor.systemOrange
        case .low: return UIColor.systemGreen
        }
    }

    private func appendRemindersSection(reminders: [ReminderItem], to document: NSMutableAttributedString) {
        appendSectionTitle("⏰ Reminders (\(reminders.count))", to: document)

        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.lineSpacing = 3
        style.firstLineHeadIndent = 0
        style.headIndent = 20

        for reminder in reminders {
            let urgencyColor = colorForUrgency(reminder.urgency)
            let reminderText = "• [\(reminder.urgency.rawValue)] \(reminder.displayText)\n"

            let attributedReminder = NSAttributedString(
                string: reminderText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12),
                    .foregroundColor: urgencyColor,
                    .paragraphStyle: style
                ]
            )
            document.append(attributedReminder)
        }

        document.append(NSAttributedString(string: "\n"))
    }

    private func colorForUrgency(_ urgency: ReminderItem.Urgency) -> UIColor {
        switch urgency {
        case .immediate: return UIColor.systemRed
        case .today: return UIColor.systemOrange
        case .thisWeek: return UIColor.systemBlue
        case .later: return UIColor.systemGreen
        }
    }

    private func appendTitlesSection(titles: [TitleItem], to document: NSMutableAttributedString) {
        appendSectionTitle("🏷️ Suggested Titles", to: document)

        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.lineSpacing = 3

        for (index, title) in titles.enumerated() {
            let titleText = "\(index + 1). \(title.text)\n"

            // Title text in normal color
            let titleAttr = NSMutableAttributedString(
                string: titleText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: style
                ]
            )

            document.append(titleAttr)
        }

        document.append(NSAttributedString(string: "\n"))
    }

    private func appendProcessingDetails(for summaryData: EnhancedSummaryData, to document: NSMutableAttributedString) {
        appendSectionTitle("📊 Processing Details", to: document)

        let detailStyle = NSMutableParagraphStyle()
        detailStyle.paragraphSpacing = 4
        detailStyle.lineSpacing = 2

        let details = [
            ("Word Count:", "\(summaryData.wordCount) words"),
            ("Original Length:", "\(summaryData.originalLength) characters"),
            ("Compression Ratio:", summaryData.formattedCompressionRatio),
            ("Processing Time:", summaryData.formattedProcessingTime)
        ]

        for (label, value) in details {
            let labelAttr = NSMutableAttributedString(
                string: label + " ",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: detailStyle
                ]
            )

            let valueAttr = NSAttributedString(
                string: value + "\n",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: detailStyle
                ]
            )

            labelAttr.append(valueAttr)
            document.append(labelAttr)
        }
    }

    // MARK: - Helpers

    private func appendSectionTitle(_ title: String, to document: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        style.paragraphSpacingBefore = 4

        let titleString = NSAttributedString(
            string: "\n\(title)\n",
            attributes: [
                .font: UIFont.boldSystemFont(ofSize: 18),
                .foregroundColor: UIColor.label,
                .paragraphStyle: style,
                .kern: 0.3  // Slightly wider letter spacing for headers
            ]
        )

        document.append(titleString)

        // Add a subtle separator line using underline character
        let separatorStyle = NSMutableParagraphStyle()
        separatorStyle.paragraphSpacing = 6

        let separator = NSAttributedString(
            string: "—————————————————————————————————————\n",
            attributes: [
                .font: UIFont.systemFont(ofSize: 10),
                .foregroundColor: UIColor.systemGray3,
                .paragraphStyle: separatorStyle
            ]
        )

        document.append(separator)
    }

    private func appendBulletedList(_ lines: [String], to document: NSMutableAttributedString, includeBullet: Bool = true) {
        guard !lines.isEmpty else { return }

        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.lineSpacing = 3

        let formattedLines: [String]
        if includeBullet {
            formattedLines = lines.map { line in
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("•") {
                    return line
                }
                return "• \(line)"
            }
        } else {
            formattedLines = lines
        }

        let content = formattedLines.joined(separator: "\n") + "\n\n"

        let list = NSAttributedString(
            string: content,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.label,
                .paragraphStyle: style
            ]
        )

        document.append(list)
    }
}

