import Foundation
import UIKit
import MapKit

/// Errors that can occur during Word document generation
enum WordExportError: LocalizedError {
    case documentGenerationFailed(String)
    case invalidDocumentData
    case memoryLimitExceeded
    
    var errorDescription: String? {
        switch self {
        case .documentGenerationFailed(let reason):
            return "Failed to generate Word document: \(reason)"
        case .invalidDocumentData:
            return "Invalid document data - unable to create Word document"
        case .memoryLimitExceeded:
            return "Document too large - memory limit exceeded during generation"
        }
    }
}

final class WordExportService {
    static let shared = WordExportService()

    private init() {}

    @MainActor
    func generateDocument(
        summaryData: EnhancedSummaryData,
        locationData: LocationData?,
        locationAddress: String?
    ) throws -> Data {
        print("✅ WordExportService: Starting document generation for \(summaryData.recordingName)")
        
        // Validate input data
        guard !summaryData.recordingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("❌ WordExportService: Invalid summary data - recording name is empty")
            throw WordExportError.invalidDocumentData
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

            if !summaryData.tasks.isEmpty {
                appendTasksSection(tasks: summaryData.tasks, to: document)
            }

            if !summaryData.reminders.isEmpty {
                appendRemindersSection(reminders: summaryData.reminders, to: document)
            }

            if !summaryData.titles.isEmpty {
                appendTitlesSection(titles: summaryData.titles, to: document)
            }

            appendProcessingDetails(for: summaryData, to: document)

            // Check document size before conversion
            let documentLength = document.length
            guard documentLength > 0 else {
                print("❌ WordExportService: Generated document is empty")
                throw WordExportError.invalidDocumentData
            }
            
            // Conservative memory limit check (10MB of attributed string)
            let estimatedMemoryUsage = documentLength * 100 // Rough estimate
            if estimatedMemoryUsage > 10_000_000 {
                print("❌ WordExportService: Document too large, estimated memory usage: \(estimatedMemoryUsage) bytes")
                throw WordExportError.memoryLimitExceeded
            }

            let documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [
                .documentType: NSAttributedString.DocumentType.officeOpenXML,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]

            print("✅ WordExportService: Converting attributed string to Word document data")
            let data = try document.data(from: NSRange(location: 0, length: documentLength), documentAttributes: documentAttributes)
            
            guard !data.isEmpty else {
                print("❌ WordExportService: Generated document data is empty")
                throw WordExportError.invalidDocumentData
            }
            
            print("✅ WordExportService: Successfully generated Word document (\(data.count) bytes)")
            return data
            
        } catch let error as WordExportError {
            throw error
        } catch {
            print("❌ WordExportService: Document generation failed with error: \(error.localizedDescription)")
            throw WordExportError.documentGenerationFailed(error.localizedDescription)
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
        metadataStyle.paragraphSpacing = 8

        let metadataText = """
        Recording Date: \(dateFormatter.string(from: summaryData.recordingDate))
        AI Engine: \(summaryData.aiMethod)
        Content Type: \(summaryData.contentType.rawValue)
        Generated: \(DateFormatter.localizedString(from: summaryData.generatedAt, dateStyle: .medium, timeStyle: .short))
        """

        let metadata = NSAttributedString(
            string: metadataText + "\n\n",
            attributes: [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: metadataStyle
            ]
        )

        document.append(metadata)
    }

    private func appendLocationSection(
        summaryData: EnhancedSummaryData,
        locationData: LocationData,
        locationAddress: String?,
        to document: NSMutableAttributedString
    ) {
        appendSectionTitle("📍 Location", to: document)

        if let mapImage = loadStoredMapImage(for: summaryData.id, locationData: locationData, maxWidth: 420) {
            let attachment = NSTextAttachment()
            attachment.image = mapImage

            let maxWidth: CGFloat = 420
            let scale = min(1, maxWidth / mapImage.size.width)
            let size = CGSize(width: mapImage.size.width * scale, height: mapImage.size.height * scale)
            attachment.bounds = CGRect(origin: .zero, size: size)

            let imageString = NSAttributedString(attachment: attachment)
            document.append(imageString)
            document.append(NSAttributedString(string: "\n"))
        }

        let infoStyle = NSMutableParagraphStyle()
        infoStyle.paragraphSpacing = 6

        var details: [String] = []
        if let address = locationAddress, !address.isEmpty {
            details.append(address)
        } else if let address = locationData.address, !address.isEmpty {
            details.append(address)
        }

        details.append("Coordinates: \(String(format: "%.5f", locationData.latitude)), \(String(format: "%.5f", locationData.longitude))")

        if let accuracy = locationData.accuracy {
            details.append(String(format: "Accuracy: ±%.0f meters", accuracy))
        }

        let locationText = details.joined(separator: "\n") + "\n\n"

        let location = NSAttributedString(
            string: locationText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.label,
                .paragraphStyle: infoStyle
            ]
        )

        document.append(location)
    }

    private func appendSummarySection(for summaryData: EnhancedSummaryData, to document: NSMutableAttributedString) {
        appendSectionTitle("📄 Summary", to: document)

        let cleaned = SummaryExportFormatter.cleanMarkdown(summaryData.summary)
        let flattened = SummaryExportFormatter.flattenMarkdown(cleaned)

        let summaryStyle = NSMutableParagraphStyle()
        summaryStyle.lineSpacing = 4
        summaryStyle.paragraphSpacing = 8

        let summary = NSAttributedString(
            string: flattened + "\n\n",
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.label,
                .paragraphStyle: summaryStyle
            ]
        )

        document.append(summary)
    }

    private func appendTasksSection(tasks: [TaskItem], to document: NSMutableAttributedString) {
        appendSectionTitle("✅ Tasks (\(tasks.count))", to: document)
        appendBulletedList(
            tasks.map { "[\($0.priority.rawValue)] \($0.displayText)" },
            to: document
        )
    }

    private func appendRemindersSection(reminders: [ReminderItem], to document: NSMutableAttributedString) {
        appendSectionTitle("⏰ Reminders (\(reminders.count))", to: document)
        appendBulletedList(
            reminders.map { "[\($0.urgency.rawValue)] \($0.displayText)" },
            to: document
        )
    }

    private func appendTitlesSection(titles: [TitleItem], to document: NSMutableAttributedString) {
        appendSectionTitle("🏷️ Suggested Titles", to: document)
        let formatted = titles.enumerated().map { index, title in
            "\(index + 1). \(title.text) (Confidence: \(Int(title.confidence * 100))%)"
        }
        appendBulletedList(formatted, to: document, includeBullet: false)
    }

    private func appendProcessingDetails(for summaryData: EnhancedSummaryData, to document: NSMutableAttributedString) {
        appendSectionTitle("📊 Processing Details", to: document)

        let details = """
        Word Count: \(summaryData.wordCount) words
        Original Length: \(summaryData.originalLength) characters
        Compression Ratio: \(summaryData.formattedCompressionRatio)
        Processing Time: \(summaryData.formattedProcessingTime)
        Quality Rating: \(summaryData.qualityDescription)
        Confidence Score: \(Int(summaryData.confidence * 100))%
        """

        let detailStyle = NSMutableParagraphStyle()
        detailStyle.paragraphSpacing = 6

        let metadata = NSAttributedString(
            string: details,
            attributes: [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: detailStyle
            ]
        )

        document.append(metadata)
    }

    // MARK: - Helpers

    private func appendSectionTitle(_ title: String, to document: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6

        let titleString = NSAttributedString(
            string: "\n\(title)\n",
            attributes: [
                .font: UIFont.boldSystemFont(ofSize: 18),
                .foregroundColor: UIColor.label,
                .paragraphStyle: style
            ]
        )

        document.append(titleString)
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

    private func loadStoredMapImage(for summaryId: UUID, locationData: LocationData, maxWidth: CGFloat) -> UIImage? {
        let locationSignature = createLocationSignature(for: locationData)
        let scale = UIScreen.main.scale

        if let storedImage = MapSnapshotStorage.loadImage(
            summaryId: summaryId,
            locationSignature: locationSignature,
            scale: scale
        ) {
            return storedImage
        }

        return createSmallFallbackMapImage(for: locationData, size: CGSize(width: maxWidth, height: maxWidth * 0.75))
    }

    private func createLocationSignature(for locationData: LocationData) -> String {
        let safeLatitude = locationData.latitude.isFinite ? locationData.latitude : 0
        let safeLongitude = locationData.longitude.isFinite ? locationData.longitude : 0
        return String(format: "%.5f_%.5f", safeLatitude, safeLongitude)
    }

    private func createSmallFallbackMapImage(for locationData: LocationData, size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, true, 2.0)
        defer { UIGraphicsEndImageContext() }

        guard let context = UIGraphicsGetCurrentContext() else {
            return nil
        }

        let rect = CGRect(origin: .zero, size: size)

        let colors = [
            UIColor.systemBlue.withAlphaComponent(0.1).cgColor,
            UIColor.systemGreen.withAlphaComponent(0.1).cgColor
        ]

        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0.0, 1.0]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width, y: size.height), options: [])
        }

        context.setStrokeColor(UIColor.systemGray3.cgColor)
        context.setLineWidth(2.0)
        let borderPath = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 8)
        context.addPath(borderPath.cgPath)
        context.strokePath()

        let pinSize: CGFloat = 40
        let pinOrigin = CGPoint(x: (size.width - pinSize) / 2, y: (size.height - pinSize) / 2 - 20)

        context.setShadow(offset: CGSize(width: 1, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.3).cgColor)
        context.setFillColor(UIColor.red.cgColor)

        let pinPath = UIBezierPath()
        pinPath.move(to: CGPoint(x: pinOrigin.x + pinSize / 2, y: pinOrigin.y))
        pinPath.addCurve(
            to: CGPoint(x: pinOrigin.x + pinSize, y: pinOrigin.y + pinSize / 2),
            controlPoint1: CGPoint(x: pinOrigin.x + pinSize * 0.8, y: pinOrigin.y),
            controlPoint2: CGPoint(x: pinOrigin.x + pinSize, y: pinOrigin.y + pinSize * 0.2)
        )
        pinPath.addCurve(
            to: CGPoint(x: pinOrigin.x + pinSize / 2, y: pinOrigin.y + pinSize),
            controlPoint1: CGPoint(x: pinOrigin.x + pinSize, y: pinOrigin.y + pinSize * 0.8),
            controlPoint2: CGPoint(x: pinOrigin.x + pinSize * 0.8, y: pinOrigin.y + pinSize)
        )
        pinPath.addCurve(
            to: CGPoint(x: pinOrigin.x, y: pinOrigin.y + pinSize / 2),
            controlPoint1: CGPoint(x: pinOrigin.x + pinSize * 0.2, y: pinOrigin.y + pinSize),
            controlPoint2: CGPoint(x: pinOrigin.x, y: pinOrigin.y + pinSize * 0.8)
        )
        pinPath.close()
        pinPath.fill()

        let titleFont = UIFont.systemFont(ofSize: 10, weight: .medium)
        let detailFont = UIFont.systemFont(ofSize: 8)

        let coordText = "\(String(format: "%.4f", locationData.latitude)), \(String(format: "%.4f", locationData.longitude))"
        let titleText = "Location"

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: UIColor.black,
            .kern: 0.1
        ]
        let titleSize = titleText.boundingRect(with: size, options: [.usesLineFragmentOrigin], attributes: titleAttributes, context: nil)
        let titleRect = CGRect(
            x: (size.width - titleSize.width) / 2,
            y: pinOrigin.y + pinSize + 8,
            width: titleSize.width,
            height: titleSize.height
        )
        titleText.draw(in: titleRect, withAttributes: titleAttributes)

        let coordAttributes: [NSAttributedString.Key: Any] = [
            .font: detailFont,
            .foregroundColor: UIColor.darkGray,
            .kern: 0.1
        ]
        let coordSize = coordText.boundingRect(with: size, options: [.usesLineFragmentOrigin], attributes: coordAttributes, context: nil)
        let coordRect = CGRect(
            x: (size.width - coordSize.width) / 2,
            y: titleRect.maxY + 2,
            width: coordSize.width,
            height: coordSize.height
        )
        coordText.draw(in: coordRect, withAttributes: coordAttributes)

        return UIGraphicsGetImageFromCurrentImageContext()
    }
}

