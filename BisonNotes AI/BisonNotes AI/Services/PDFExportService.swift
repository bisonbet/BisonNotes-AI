//
//  PDFExportService.swift
//  BisonNotes AI
//
//  Created by Claude on 9/17/25.
//

import Foundation
import UIKit
import PDFKit
import MapKit
import CoreLocation

// MARK: - Map Snapshot Storage (copied from SummaryDetailView)

private enum MapSnapshotStorage {
    private static let directoryName = "SummaryLocationSnapshots"

    private static func directoryURL() -> URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directory = baseURL.appendingPathComponent(directoryName, isDirectory: true)

        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                print("❌ MapSnapshotStorage: Failed to create directory: \(error)")
                return nil
            }
        }

        return directory
    }

    private static func fileURL(summaryId: UUID, locationSignature: String) -> URL? {
        directoryURL()?.appendingPathComponent("\(summaryId.uuidString)_\(locationSignature).png")
    }

    static func loadData(summaryId: UUID, locationSignature: String) -> Data? {
        guard let url = fileURL(summaryId: summaryId, locationSignature: locationSignature),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return try? Data(contentsOf: url)
    }

    static func loadImage(summaryId: UUID, locationSignature: String, scale: CGFloat) -> UIImage? {
        guard let data = loadData(summaryId: summaryId, locationSignature: locationSignature) else {
            return nil
        }

        return UIImage(data: data, scale: scale)
    }
}

class PDFExportService {
    static let shared = PDFExportService()

    private init() {}

    // MARK: - Helper Methods

    private func createLocationSignature(for locationData: LocationData) -> String {
        let safeLatitude = locationData.latitude.isFinite ? locationData.latitude : 0
        let safeLongitude = locationData.longitude.isFinite ? locationData.longitude : 0
        return String(format: "%.5f_%.5f", safeLatitude, safeLongitude)
    }

    private func loadStoredMapImage(for summaryId: UUID, locationData: LocationData, size: CGFloat) -> UIImage? {
        let locationSignature = createLocationSignature(for: locationData)
        let scale = UIScreen.main.scale

        // Try to load the stored map image (any size, we'll scale it)
        if let storedImage = MapSnapshotStorage.loadImage(
            summaryId: summaryId,
            locationSignature: locationSignature,
            scale: scale
        ) {
            print("✅ Loaded stored map image for summary \(summaryId)")
            return storedImage
        }

        // If no stored image found, create a fallback with the requested size
        print("⚠️ No stored map image found, creating fallback")
        return createSmallFallbackMapImage(for: locationData, size: CGSize(width: size, height: size * 0.75))
    }

    // MARK: - Configuration

    /// Reset the map generation flag to try generating maps again (deprecated - maps are now stored)
    /// Call this if you want to re-enable map generation after it was disabled due to failures
    @available(*, deprecated, message: "Maps are now stored persistently, this method is no longer needed")
    func resetMapGeneration() {
        UserDefaults.standard.set(false, forKey: "skipMapGeneration")
        print("✅ Map generation re-enabled")
    }

    // MARK: - Main Export Function

    @MainActor
    func generatePDF(
        summaryData: EnhancedSummaryData,
        locationData: LocationData?,
        locationAddress: String?
    ) throws -> Data {
        return try createPDF(
            summaryData: summaryData,
            locationData: locationData,
            locationAddress: locationAddress
        )
    }

    // MARK: - PDF Creation

    private func createPDF(
        summaryData: EnhancedSummaryData,
        locationData: LocationData?,
        locationAddress: String?
    ) throws -> Data {
        let pageSize = CGSize(width: 612, height: 792) // US Letter size
        let margins = UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
        let contentWidth = pageSize.width - margins.left - margins.right

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))

        return renderer.pdfData { context in
            var currentY: CGFloat = margins.top

            // Start first page
            context.beginPage()

            // Title
            currentY = drawTitle(summaryData.recordingName, at: currentY, contentWidth: contentWidth, margins: margins, context: context)

            // Header with metadata and map
            currentY = drawHeaderWithMap(
                summaryData: summaryData,
                locationData: locationData,
                locationAddress: locationAddress,
                at: currentY,
                contentWidth: contentWidth,
                margins: margins,
                context: context
            )

            // Summary section
            currentY = drawSummarySection(
                summaryData: summaryData,
                at: currentY,
                contentWidth: contentWidth,
                margins: margins,
                context: context,
                pageSize: pageSize
            )

            // Location information is now shown in the header with the map
            // No need for redundant location section at the bottom
        }
    }

    // MARK: - Drawing Functions

    private func drawTitle(_ title: String, at y: CGFloat, contentWidth: CGFloat, margins: UIEdgeInsets, context: UIGraphicsPDFRendererContext) -> CGFloat {
        let titleFont = UIFont.boldSystemFont(ofSize: 24)
        let titleColor = UIColor.black

        let titleRect = CGRect(x: margins.left, y: y, width: contentWidth, height: 40)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: titleColor,
            .paragraphStyle: titleStyle
        ]

        title.draw(in: titleRect, withAttributes: titleAttributes)
        return y + 50
    }

    private func drawHeaderWithMap(
        summaryData: EnhancedSummaryData,
        locationData: LocationData?,
        locationAddress: String?,
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext
    ) -> CGFloat {
        // Adjusted proportions for better map display:
        // Left: 30% for date, Middle: 40% for map, Right: 30% for location info
        let leftWidth = contentWidth * 0.3
        let middleWidth = contentWidth * 0.4
        let rightWidth = contentWidth * 0.3
        let headerHeight: CGFloat = 180 // Height accommodates map and location details

        // Left third: Date
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short
        let dateText = "Recording Date: \(dateFormatter.string(from: summaryData.recordingDate))"
        let dateFont = UIFont.systemFont(ofSize: 12)
        let dateColor = UIColor.darkGray

        let dateRect = CGRect(x: margins.left, y: y, width: leftWidth, height: 30)
        let dateAttributes: [NSAttributedString.Key: Any] = [
            .font: dateFont,
            .foregroundColor: dateColor
        ]
        dateText.draw(in: dateRect, withAttributes: dateAttributes)

        // Middle section: Map (fits better in rectangular area) or empty if no location
        if let locationData = locationData {
            let mapOrigin = CGPoint(
                x: margins.left + leftWidth + 5, // Start after left section
                y: y + 5
            )

            // Load stored map image or create fallback
            if let mapImage = loadStoredMapImage(for: summaryData.id, locationData: locationData, size: middleWidth) {
                // Draw the image maintaining its aspect ratio, centered in the available space
                let imageSize = mapImage.size
                let aspectRatio = imageSize.width / imageSize.height
                let availableHeight = headerHeight - 10
                var drawWidth = middleWidth
                var drawHeight = middleWidth / aspectRatio

                // If the image is too tall, scale it down
                if drawHeight > availableHeight {
                    drawHeight = availableHeight
                    drawWidth = availableHeight * aspectRatio
                }

                let drawOrigin = CGPoint(
                    x: mapOrigin.x + (middleWidth - drawWidth) / 2, // Center horizontally
                    y: mapOrigin.y + (availableHeight - drawHeight) / 2 // Center vertically
                )

                mapImage.draw(in: CGRect(origin: drawOrigin, size: CGSize(width: drawWidth, height: drawHeight)))
            }
        }

        // Right section: Location information or "No Location Data" message
        let locationX = margins.left + leftWidth + middleWidth + 5
        let locationWidth = rightWidth - 10
        let locationY = y + 5

        let locationFont = UIFont.systemFont(ofSize: 11, weight: .medium)
        let locationColor = UIColor.black

        if let locationData = locationData {
            var currentY = locationY

            // Location name/address
            if let address = locationAddress, !address.isEmpty {
                // Use multiline text for address to allow wrapping
                let addressText = drawMultilineText(
                    address,
                    at: currentY,
                    contentWidth: locationWidth,
                    margins: UIEdgeInsets(top: 0, left: locationX, bottom: 0, right: margins.right),
                    context: context,
                    pageSize: CGSize(width: contentWidth + margins.left + margins.right, height: headerHeight + margins.top + margins.bottom),
                    font: locationFont,
                    color: locationColor
                )
                currentY = addressText + 5
            }

            // Coordinates
            let coordText = "\(String(format: "%.4f", locationData.latitude)), \(String(format: "%.4f", locationData.longitude))"
            let coordAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10),
                .foregroundColor: UIColor.darkGray
            ]
            let coordRect = CGRect(x: locationX, y: currentY, width: locationWidth, height: 20)
            coordText.draw(in: coordRect, withAttributes: coordAttributes)
            currentY += 25

            // Accuracy
            if let accuracy = locationData.accuracy {
                let accuracyText = "±\(Int(accuracy))m"
                let accuracyRect = CGRect(x: locationX, y: currentY, width: locationWidth, height: 20)
                accuracyText.draw(in: accuracyRect, withAttributes: coordAttributes)
            }
        } else {
            // No location data - show message
            let noLocationText = "No Location Data"
            let noLocationAttributes: [NSAttributedString.Key: Any] = [
                .font: locationFont,
                .foregroundColor: UIColor.gray
            ]
            let noLocationRect = CGRect(x: locationX, y: locationY, width: locationWidth, height: 30)
            noLocationText.draw(in: noLocationRect, withAttributes: noLocationAttributes)
        }

        // Draw separator line
        let lineY = y + headerHeight
        drawLine(from: CGPoint(x: margins.left, y: lineY), to: CGPoint(x: margins.left + contentWidth, y: lineY), context: context)

        return lineY + 20
    }

    private func drawSimplifiedHeader(summaryData: EnhancedSummaryData, at y: CGFloat, contentWidth: CGFloat, margins: UIEdgeInsets, context: UIGraphicsPDFRendererContext) -> CGFloat {
        // This method is now deprecated - using drawHeaderWithMap instead
        return drawHeaderWithMap(
            summaryData: summaryData,
            locationData: nil,
            locationAddress: nil,
            at: y,
            contentWidth: contentWidth,
            margins: margins,
            context: context
        )
    }

    private func drawLocationSection(
        locationData: LocationData,
        address: String?,
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize
    ) -> CGFloat {
        var currentY = y

        // Check if we need a new page
        currentY = checkAndStartNewPage(currentY: currentY, requiredHeight: 250, pageSize: pageSize, margins: margins, context: context)

        // Section title
        currentY = drawSectionTitle("📍 Location", at: currentY, contentWidth: contentWidth, margins: margins, context: context)

        // Use simple location display instead of complex map generation
        let locationRect = CGRect(x: margins.left, y: currentY, width: contentWidth, height: 120)
        drawLocationInfo(locationData: locationData, address: address, in: locationRect, context: context)
        currentY += 130

        // Location details
        let detailFont = UIFont.systemFont(ofSize: 12)
        let detailColor = UIColor.darkGray

        var locationText = "Coordinates: \(locationData.latitude), \(locationData.longitude)"
        if let address = address {
            locationText += "\nAddress: \(address)"
        }
        if let accuracy = locationData.accuracy {
            locationText += "\nAccuracy: \(Int(accuracy))m"
        }

        let detailRect = CGRect(x: margins.left, y: currentY, width: contentWidth, height: 60)
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: detailFont,
            .foregroundColor: detailColor
        ]

        locationText.draw(in: detailRect, withAttributes: detailAttributes)
        currentY += 80

        return currentY
    }

    private func drawSummarySection(
        summaryData: EnhancedSummaryData,
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize
    ) -> CGFloat {
        var currentY = y

        // Section title
        currentY = drawSectionTitle("📄 Summary", at: currentY, contentWidth: contentWidth, margins: margins, context: context)

        let cleanedSummary = cleanMarkdownForPDF(summaryData.summary)
        let flattenedSummary = flattenMarkdownForPDF(cleanedSummary)

        currentY = drawMultilineText(
            flattenedSummary,
            at: currentY,
            contentWidth: contentWidth,
            margins: margins,
            context: context,
            pageSize: pageSize
        )

        return currentY + 20
    }

    // MARK: - Markdown Parsing

    private func cleanMarkdownForPDF(_ text: String) -> String {
        var cleaned = text

        // Normalize escaped newlines and carriage returns
        cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\\r", with: "\n")

        // Remove JSON-style wrappers if present
        cleaned = cleaned.replacingOccurrences(of: "^\"summary\"\\s*:\\s*\"", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^\"content\"\\s*:\\s*\"", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^\"text\"\\s*:\\s*\"", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\"\\s*$", with: "", options: .regularExpression)

        // Collapse excessive blank lines
        cleaned = cleaned.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func flattenMarkdownForPDF(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var pendingBlank = false

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                pendingBlank = !result.isEmpty
                continue
            }

            var line = trimmed

            // Remove image syntax entirely
            if line.hasPrefix("![") {
                continue
            }

            // Headers (#, ##, ...)
            if let headerRange = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                let headerText = line[headerRange.upperBound...].trimmingCharacters(in: .whitespaces)
                if result.last?.isEmpty == false {
                    result.append("")
                }
                result.append(headerText.uppercased())
                result.append("")
                pendingBlank = false
                continue
            }

            // Block quotes
            if line.hasPrefix(">") {
                line = line.dropFirst().trimmingCharacters(in: .whitespaces)
                line = "“\(line)”"
            }

            // Replace unordered list markers with bullet
            if let bulletRange = line.range(of: "^[-*+]\\s+", options: .regularExpression) {
                line.replaceSubrange(bulletRange, with: "• ")
            }

            // Normalize ordered list spacing (e.g., 1. item)
            if let orderedRange = line.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                // Already formatted; ensure single space after number
                let prefix = String(line[orderedRange])
                let normalizedPrefix = prefix.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                line.replaceSubrange(orderedRange, with: normalizedPrefix)
            }

            // Convert markdown links to "text (url)"
            line = replaceMarkdownLinks(in: line)

            // Remove emphasis markers
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "__", with: "")
            line = line.replacingOccurrences(of: "*", with: "")
            line = line.replacingOccurrences(of: "_", with: "")
            line = line.replacingOccurrences(of: "`", with: "")

            if pendingBlank && (result.last?.isEmpty == false) {
                result.append("")
            }

            result.append(line)
            pendingBlank = false
        }

        // Remove trailing blank lines
        while result.last?.isEmpty == true {
            result.removeLast()
        }

        return result.joined(separator: "\n")
    }

    private func replaceMarkdownLinks(in line: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, options: []) else {
            return line
        }

        let matches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count))
        if matches.isEmpty {
            return line
        }

        let mutable = NSMutableString(string: line)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let textRange = Range(match.range(at: 1), in: line),
                  let urlRange = Range(match.range(at: 2), in: line) else {
                continue
            }

            let text = String(line[textRange])
            let url = String(line[urlRange])
            let replacement = "\(text) (\(url))"
            mutable.replaceCharacters(in: match.range, with: replacement)
        }

        return String(mutable)
    }

    private func drawTasksSection(
        tasks: [TaskItem],
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize
    ) -> CGFloat {
        var currentY = y

        // Section title
        currentY = drawSectionTitle("✅ Tasks (\(tasks.count))", at: currentY, contentWidth: contentWidth, margins: margins, context: context)

        for task in tasks {
            // Check if we need a new page
            currentY = checkAndStartNewPage(currentY: currentY, requiredHeight: 40, pageSize: pageSize, margins: margins, context: context)

            let priorityColor = colorForPriority(task.priority)
            let bullet = "•"
            let taskText = "\(bullet) [\(task.priority.rawValue)] \(task.displayText)"

            currentY = drawBulletPoint(
                taskText,
                at: currentY,
                contentWidth: contentWidth,
                margins: margins,
                context: context,
                color: priorityColor
            )
        }

        return currentY + 10
    }

    private func drawRemindersSection(
        reminders: [ReminderItem],
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize
    ) -> CGFloat {
        var currentY = y

        // Section title
        currentY = drawSectionTitle("⏰ Reminders (\(reminders.count))", at: currentY, contentWidth: contentWidth, margins: margins, context: context)

        for reminder in reminders {
            // Check if we need a new page
            currentY = checkAndStartNewPage(currentY: currentY, requiredHeight: 40, pageSize: pageSize, margins: margins, context: context)

            let urgencyColor = colorForUrgency(reminder.urgency)
            let bullet = "•"
            let reminderText = "\(bullet) [\(reminder.urgency.rawValue)] \(reminder.displayText)"

            currentY = drawBulletPoint(
                reminderText,
                at: currentY,
                contentWidth: contentWidth,
                margins: margins,
                context: context,
                color: urgencyColor
            )
        }

        return currentY + 10
    }

    private func drawTitlesSection(
        titles: [TitleItem],
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize
    ) -> CGFloat {
        var currentY = y

        // Section title
        currentY = drawSectionTitle("🏷️ Suggested Titles", at: currentY, contentWidth: contentWidth, margins: margins, context: context)

        for (index, title) in titles.enumerated() {
            // Check if we need a new page
            currentY = checkAndStartNewPage(currentY: currentY, requiredHeight: 30, pageSize: pageSize, margins: margins, context: context)

            let titleText = "\(index + 1). \(title.text) (Confidence: \(Int(title.confidence * 100))%)"

            currentY = drawBulletPoint(
                titleText,
                at: currentY,
                contentWidth: contentWidth,
                margins: margins,
                context: context,
                color: UIColor.black
            )
        }

        return currentY + 10
    }

    private func drawMetadataSection(
        summaryData: EnhancedSummaryData,
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize
    ) -> CGFloat {
        var currentY = y

        // Check if we need a new page
        currentY = checkAndStartNewPage(currentY: currentY, requiredHeight: 100, pageSize: pageSize, margins: margins, context: context)

        // Section title
        currentY = drawSectionTitle("📊 Processing Details", at: currentY, contentWidth: contentWidth, margins: margins, context: context)

        let metadataText = """
        Word Count: \(summaryData.wordCount) words
        Original Length: \(summaryData.originalLength) characters
        Compression Ratio: \(summaryData.formattedCompressionRatio)
        Processing Time: \(summaryData.formattedProcessingTime)
        Quality Rating: \(summaryData.qualityDescription)
        Confidence Score: \(Int(summaryData.confidence * 100))%
        """

        currentY = drawMultilineText(
            metadataText,
            at: currentY,
            contentWidth: contentWidth,
            margins: margins,
            context: context,
            pageSize: pageSize,
            font: UIFont.systemFont(ofSize: 10),
            color: UIColor.darkGray
        )

        return currentY
    }

    // MARK: - Data Structures

    // MARK: - Helper Functions

    private func drawSectionTitle(_ title: String, at y: CGFloat, contentWidth: CGFloat, margins: UIEdgeInsets, context: UIGraphicsPDFRendererContext) -> CGFloat {
        let titleFont = UIFont.boldSystemFont(ofSize: 16)
        let titleColor = UIColor.black

        let titleRect = CGRect(x: margins.left, y: y, width: contentWidth, height: 25)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: titleColor
        ]

        title.draw(in: titleRect, withAttributes: titleAttributes)
        return y + 35
    }

    private func drawBulletPoint(_ text: String, at y: CGFloat, contentWidth: CGFloat, margins: UIEdgeInsets, context: UIGraphicsPDFRendererContext, color: UIColor = UIColor.black) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 11)

        let textRect = CGRect(x: margins.left + 10, y: y, width: contentWidth - 10, height: 25)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        text.draw(in: textRect, withAttributes: textAttributes)
        return y + 25
    }

    private func drawMultilineText(
        _ text: String,
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize,
        font: UIFont = UIFont.systemFont(ofSize: 12),
        color: UIColor = UIColor.black
    ) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 6

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]

        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let textRect = CGRect(x: margins.left, y: y, width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        let boundingRect = attributedString.boundingRect(with: textRect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)

        var currentY = y
        let maxHeightPerPage = pageSize.height - margins.top - margins.bottom - 50

        if boundingRect.height > maxHeightPerPage {
            // Split text across multiple pages
            let lines = text.components(separatedBy: .newlines)

            for line in lines {
                let lineAttributedString = NSAttributedString(string: line, attributes: attributes)
                let lineRect = CGRect(x: margins.left, y: currentY, width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
                let lineBoundingRect = lineAttributedString.boundingRect(with: lineRect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)

                // Check if we need a new page
                if currentY + lineBoundingRect.height > pageSize.height - margins.bottom {
                    context.beginPage()
                    currentY = margins.top
                }

                let drawRect = CGRect(x: margins.left, y: currentY, width: contentWidth, height: lineBoundingRect.height)
                lineAttributedString.draw(in: drawRect)
                currentY += lineBoundingRect.height + 4
            }
        } else {
            // Draw all text at once
            let drawRect = CGRect(x: margins.left, y: currentY, width: contentWidth, height: boundingRect.height)
            attributedString.draw(in: drawRect)
            currentY += boundingRect.height
        }

        return currentY
    }

    private func checkAndStartNewPage(currentY: CGFloat, requiredHeight: CGFloat, pageSize: CGSize, margins: UIEdgeInsets, context: UIGraphicsPDFRendererContext) -> CGFloat {
        if currentY + requiredHeight > pageSize.height - margins.bottom {
            context.beginPage()
            return margins.top
        }
        return currentY
    }

    private func drawLine(from start: CGPoint, to end: CGPoint, context: UIGraphicsPDFRendererContext, color: UIColor = UIColor.lightGray, width: CGFloat = 1.0) {
        let cgContext = context.cgContext
        cgContext.setStrokeColor(color.cgColor)
        cgContext.setLineWidth(width)
        cgContext.move(to: start)
        cgContext.addLine(to: end)
        cgContext.strokePath()
    }


    private func drawLocationInfo(locationData: LocationData, address: String?, in rect: CGRect, context: UIGraphicsPDFRendererContext) {
        let cgContext = context.cgContext

        // Draw background
        cgContext.setFillColor(UIColor.systemGray6.cgColor)
        cgContext.fill(rect)

        // Draw border
        cgContext.setStrokeColor(UIColor.systemGray4.cgColor)
        cgContext.setLineWidth(1.0)
        cgContext.stroke(rect)

        // Draw map pin icon
        let pinSize: CGFloat = 40
        let pinRect = CGRect(x: rect.minX + 20, y: rect.minY + 20, width: pinSize, height: pinSize)

        // Simple pin drawing
        cgContext.setFillColor(UIColor.red.cgColor)
        cgContext.fillEllipse(in: pinRect)

        // Pin stem
        let stemRect = CGRect(x: pinRect.midX - 2, y: pinRect.maxY - 5, width: 4, height: 15)
        cgContext.fill(stemRect)

        // Location text
        let textX = pinRect.maxX + 15
        let textFont = UIFont.systemFont(ofSize: 14, weight: .medium)
        let detailFont = UIFont.systemFont(ofSize: 12)

        var currentY = rect.minY + 25

        if let address = address, !address.isEmpty {
            let addressAttributes: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: UIColor.label
            ]
            let addressRect = CGRect(x: textX, y: currentY, width: rect.maxX - textX - 10, height: 20)
            address.draw(in: addressRect, withAttributes: addressAttributes)
            currentY += 25
        }

        let coordText = "Coordinates: \(locationData.latitude), \(locationData.longitude)"
        let coordAttributes: [NSAttributedString.Key: Any] = [
            .font: detailFont,
            .foregroundColor: UIColor.secondaryLabel
        ]
        let coordRect = CGRect(x: textX, y: currentY, width: rect.maxX - textX - 10, height: 20)
        coordText.draw(in: coordRect, withAttributes: coordAttributes)
        currentY += 20

        if let accuracy = locationData.accuracy {
            let accuracyText = "Accuracy: ±\(Int(accuracy))m"
            let accuracyRect = CGRect(x: textX, y: currentY, width: rect.maxX - textX - 10, height: 20)
            accuracyText.draw(in: accuracyRect, withAttributes: coordAttributes)
        }
    }

    private func createSmallFallbackMapImage(for locationData: LocationData, size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, true, 2.0) // 2x scale for crisp rendering
        defer { UIGraphicsEndImageContext() }

        let context = UIGraphicsGetCurrentContext()!
        let rect = CGRect(origin: .zero, size: size)

        // Draw gradient background - more attractive
        let colors = [UIColor.systemBlue.withAlphaComponent(0.1).cgColor,
                     UIColor.systemGreen.withAlphaComponent(0.1).cgColor]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0.0, 1.0])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width, y: size.height), options: [])

        // Draw border with rounded corners
        context.setStrokeColor(UIColor.systemGray3.cgColor)
        context.setLineWidth(2.0)
        let borderPath = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 8)
        context.addPath(borderPath.cgPath)
        context.strokePath()

        // Draw map pin icon - larger and more prominent
        let pinSize: CGFloat = 40
        let pinOrigin = CGPoint(x: (size.width - pinSize) / 2, y: (size.height - pinSize) / 2 - 20)

        // Create a better pin shape with shadow
        context.setShadow(offset: CGSize(width: 1, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.3).cgColor)
        context.setFillColor(UIColor.red.cgColor)
        let pinPath = UIBezierPath()
        pinPath.move(to: CGPoint(x: pinOrigin.x + pinSize/2, y: pinOrigin.y))
        pinPath.addCurve(to: CGPoint(x: pinOrigin.x + pinSize, y: pinOrigin.y + pinSize/2),
                       controlPoint1: CGPoint(x: pinOrigin.x + pinSize*0.8, y: pinOrigin.y),
                       controlPoint2: CGPoint(x: pinOrigin.x + pinSize, y: pinOrigin.y + pinSize*0.2))
        pinPath.addCurve(to: CGPoint(x: pinOrigin.x + pinSize/2, y: pinOrigin.y + pinSize),
                       controlPoint1: CGPoint(x: pinOrigin.x + pinSize, y: pinOrigin.y + pinSize*0.8),
                       controlPoint2: CGPoint(x: pinOrigin.x + pinSize*0.8, y: pinOrigin.y + pinSize))
        pinPath.addCurve(to: CGPoint(x: pinOrigin.x, y: pinOrigin.y + pinSize/2),
                       controlPoint1: CGPoint(x: pinOrigin.x + pinSize*0.2, y: pinOrigin.y + pinSize),
                       controlPoint2: CGPoint(x: pinOrigin.x, y: pinOrigin.y + pinSize*0.8))
        pinPath.close()
        pinPath.fill()

        // Draw location info below the pin - better formatting
        let titleFont = UIFont.systemFont(ofSize: 10, weight: .medium)
        let detailFont = UIFont.systemFont(ofSize: 8)

        let coordText = "\(String(format: "%.4f", locationData.latitude)), \(String(format: "%.4f", locationData.longitude))"
        let titleText = "Location"

        // Draw title
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

        // Draw coordinates
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


    private func colorForPriority(_ priority: TaskItem.Priority) -> UIColor {
        switch priority {
        case .high: return UIColor.red
        case .medium: return UIColor.orange
        case .low: return UIColor.systemGreen
        }
    }

    private func colorForUrgency(_ urgency: ReminderItem.Urgency) -> UIColor {
        switch urgency {
        case .immediate: return UIColor.red
        case .today: return UIColor.orange
        case .thisWeek: return UIColor.systemBlue
        case .later: return UIColor.systemGreen
        }
    }
}
