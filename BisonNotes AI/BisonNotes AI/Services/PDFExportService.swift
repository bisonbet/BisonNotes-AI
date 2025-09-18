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

class PDFExportService {
    static let shared = PDFExportService()

    private init() {}

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

            // Header with metadata (simplified)
            currentY = drawSimplifiedHeader(summaryData: summaryData, at: currentY, contentWidth: contentWidth, margins: margins, context: context)

            // Summary section
            currentY = drawSummarySection(
                summaryData: summaryData,
                at: currentY,
                contentWidth: contentWidth,
                margins: margins,
                context: context,
                pageSize: pageSize
            )

            // Location section at the bottom (if available)
            if let locationData = locationData {
                currentY = drawLocationSection(
                    locationData: locationData,
                    address: locationAddress,
                    at: currentY,
                    contentWidth: contentWidth,
                    margins: margins,
                    context: context,
                    pageSize: pageSize
                )
            }
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

    private func drawSimplifiedHeader(summaryData: EnhancedSummaryData, at y: CGFloat, contentWidth: CGFloat, margins: UIEdgeInsets, context: UIGraphicsPDFRendererContext) -> CGFloat {
        let headerFont = UIFont.systemFont(ofSize: 14)
        let headerColor = UIColor.darkGray

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short

        let headerText = "Recording Date: \(dateFormatter.string(from: summaryData.recordingDate))"

        let headerRect = CGRect(x: margins.left, y: y, width: contentWidth, height: 30)
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: headerColor
        ]

        headerText.draw(in: headerRect, withAttributes: headerAttributes)

        // Draw separator line
        let lineY = y + 40
        drawLine(from: CGPoint(x: margins.left, y: lineY), to: CGPoint(x: margins.left + contentWidth, y: lineY), context: context)

        return lineY + 20
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

        // Summary content
        currentY = drawMultilineText(
            summaryData.summary,
            at: currentY,
            contentWidth: contentWidth,
            margins: margins,
            context: context,
            pageSize: pageSize,
            font: UIFont.systemFont(ofSize: 12),
            color: UIColor.black
        )

        return currentY + 20
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

    private func generateStaticMapImage(for locationData: LocationData) -> UIImage? {
        let mapSize = CGSize(width: 400, height: 150)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )

        let mapOptions = MKMapSnapshotter.Options()
        mapOptions.region = region
        mapOptions.size = mapSize
        mapOptions.mapType = .standard

        let semaphore = DispatchSemaphore(value: 0)
        var resultImage: UIImage?

        let snapshotter = MKMapSnapshotter(options: mapOptions)
        snapshotter.start { snapshot, error in
            defer { semaphore.signal() }

            if let error = error {
                print("❌ Map snapshot error: \(error)")
                return
            }

            guard let snapshot = snapshot else {
                print("❌ No map snapshot available")
                return
            }

            // Add a pin to the map
            UIGraphicsBeginImageContextWithOptions(mapOptions.size, true, 0)
            defer { UIGraphicsEndImageContext() }

            snapshot.image.draw(at: .zero)

            // Draw a pin at the center
            if let pin = UIImage(systemName: "mappin.circle.fill")?.withTintColor(.red, renderingMode: .alwaysOriginal) {
                let pinSize = CGSize(width: 30, height: 30)
                let pinPoint = CGPoint(
                    x: mapOptions.size.width / 2 - pinSize.width / 2,
                    y: mapOptions.size.height / 2 - pinSize.height / 2
                )
                pin.draw(in: CGRect(origin: pinPoint, size: pinSize))
            }

            resultImage = UIGraphicsGetImageFromCurrentImageContext()
        }

        // Add a timeout to prevent hanging
        let timeout = DispatchTime.now() + .seconds(5)
        if semaphore.wait(timeout: timeout) == .timedOut {
            print("⚠️ Map generation timed out")
            snapshotter.cancel()
            return createFallbackMapImage(for: locationData, size: mapSize)
        }

        return resultImage ?? createFallbackMapImage(for: locationData, size: mapSize)
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

    private func createFallbackMapImage(for locationData: LocationData, size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, true, 0)
        defer { UIGraphicsEndImageContext() }

        // Draw a simple background
        UIColor.systemGray5.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))

        // Draw location info
        let font = UIFont.systemFont(ofSize: 14, weight: .medium)
        let text = "📍 Location\n\(locationData.latitude), \(locationData.longitude)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label
        ]

        let textSize = text.boundingRect(with: size, options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        let textRect = CGRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )

        text.draw(in: textRect, withAttributes: attributes)

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