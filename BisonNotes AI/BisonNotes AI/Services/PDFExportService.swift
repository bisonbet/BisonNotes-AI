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
import CoreText

class PDFExportService {
    static let shared = PDFExportService()

    private init() {}

    private struct HeaderMapImages {
        let close: UIImage?
        let wide: UIImage?
    }

    // MARK: - Helper Methods

    private func createLocationSignature(for locationData: LocationData) -> String {
        let safeLatitude = locationData.latitude.isFinite ? locationData.latitude : 0
        let safeLongitude = locationData.longitude.isFinite ? locationData.longitude : 0
        return String(format: "%.5f_%.5f", safeLatitude, safeLongitude)
    }

    private func loadStoredMapImage(for summaryId: UUID, locationData: LocationData, size: CGSize) -> UIImage? {
        let locationSignature = createLocationSignature(for: locationData)
        let scale = UIScreen.main.scale

        // Try to load the stored map image (any size, we'll scale it)
        if let storedImage = MapSnapshotStorage.loadImage(
            summaryId: summaryId,
            locationSignature: locationSignature,
            scale: scale
        ) {
            print("✅ PDFExportService: Loaded stored map image for summary \(summaryId)")
            return storedImage
        }

        // If no stored image found, create a fallback with the requested size
        print("❌ PDFExportService: No stored map image found, creating fallback")
        return createSmallFallbackMapImage(for: locationData, size: size)
    }

    // MARK: - Configuration

    /// Reset the map generation flag to try generating maps again (deprecated - maps are now stored)
    /// Call this if you want to re-enable map generation after it was disabled due to failures
    @available(*, deprecated, message: "Maps are now stored persistently, this method is no longer needed")
    func resetMapGeneration() {
        UserDefaults.standard.set(false, forKey: "skipMapGeneration")
        print("✅ PDFExportService: Map generation re-enabled")
    }

    // MARK: - Main Export Function

    @MainActor
    func generatePDF(
        summaryData: EnhancedSummaryData,
        locationData: LocationData?,
        locationAddress: String?
    ) async throws -> Data {
        let headerMaps = await buildHeaderMapImages(summaryData: summaryData, locationData: locationData)
        return try createPDF(
            summaryData: summaryData,
            locationData: locationData,
            locationAddress: locationAddress,
            headerMaps: headerMaps
        )
    }

    // MARK: - PDF Creation

    private static let headerHeight: CGFloat = 28
    private static let footerHeight: CGFloat = 24
    private static let contentTop: CGFloat = 50
    private static let contentBottomOffset: CGFloat = 50 + footerHeight  // margin + footer

    private func createPDF(
        summaryData: EnhancedSummaryData,
        locationData: LocationData?,
        locationAddress: String?,
        headerMaps: HeaderMapImages?
    ) throws -> Data {
        let pageSize = CGSize(width: 612, height: 792) // US Letter size
        let margins = UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
        let contentWidth = pageSize.width - margins.left - margins.right
        let contentBottom = pageSize.height - Self.contentBottomOffset
        let exportDate = summaryData.generatedAt

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))

        return renderer.pdfData { context in
            var currentY: CGFloat = Self.contentTop
            var pageNumber = 1

            // Start first page and draw branding header
            context.beginPage()
            drawPageHeader(context: context, pageSize: pageSize, margins: margins, exportDate: exportDate)

            // Title
            currentY = drawTitle(summaryData.recordingName, at: currentY, contentWidth: contentWidth, margins: margins, context: context)

            // Header with metadata and map
            currentY = drawHeaderWithMap(
                summaryData: summaryData,
                locationData: locationData,
                locationAddress: locationAddress,
                headerMaps: headerMaps,
                at: currentY,
                contentWidth: contentWidth,
                margins: margins,
                context: context
            )

            // Summary section (attributed, with proper wrapping and pagination)
            currentY = drawSummarySection(
                summaryData: summaryData,
                at: currentY,
                contentWidth: contentWidth,
                margins: margins,
                context: context,
                pageSize: pageSize,
                contentBottom: contentBottom,
                pageNumber: &pageNumber,
                exportDate: exportDate
            )

            // Tasks
            if !summaryData.tasks.isEmpty {
                currentY = drawTasksSection(
                    summaryData.tasks,
                    at: currentY,
                    contentWidth: contentWidth,
                    margins: margins,
                    context: context,
                    pageSize: pageSize,
                    contentBottom: contentBottom,
                    pageNumber: &pageNumber,
                    exportDate: exportDate
                )
            }

            // Reminders
            if !summaryData.reminders.isEmpty {
                currentY = drawRemindersSection(
                    summaryData.reminders,
                    at: currentY,
                    contentWidth: contentWidth,
                    margins: margins,
                    context: context,
                    pageSize: pageSize,
                    contentBottom: contentBottom,
                    pageNumber: &pageNumber,
                    exportDate: exportDate
                )
            }

            // Footer on last page
            drawPageFooter(context: context, pageSize: pageSize, margins: margins, pageNumber: pageNumber)
        }
    }

    private func drawPageHeader(context: UIGraphicsPDFRendererContext, pageSize: CGSize, margins: UIEdgeInsets, exportDate: Date) {
        let font = UIFont.systemFont(ofSize: 9)
        let color = UIColor.darkGray
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let contentWidth = pageSize.width - margins.left - margins.right
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let line1 = "\(SummaryExportFormatter.exportAppName) · Summary Export"
        let line2 = dateFormatter.string(from: exportDate)
        line1.draw(in: CGRect(x: margins.left, y: 14, width: contentWidth, height: 12), withAttributes: attrs)
        line2.draw(in: CGRect(x: margins.left, y: 24, width: contentWidth, height: 12), withAttributes: attrs)
    }

    private func drawPageFooter(context: UIGraphicsPDFRendererContext, pageSize: CGSize, margins: UIEdgeInsets, pageNumber: Int) {
        let font = UIFont.systemFont(ofSize: 9)
        let color = UIColor.darkGray
        let contentWidth = pageSize.width - margins.left - margins.right
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = "— \(pageNumber) —"
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        text.draw(in: CGRect(x: margins.left, y: pageSize.height - 20, width: contentWidth, height: 12), withAttributes: attrs)
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
        headerMaps: HeaderMapImages?,
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext
    ) -> CGFloat {
        let headerHeight: CGFloat = 210
        let gap: CGFloat = 10
        let paneWidth = (contentWidth - (gap * 2)) / 3

        let leftRect = CGRect(x: margins.left, y: y, width: paneWidth, height: headerHeight)
        let middleRect = CGRect(x: leftRect.maxX + gap, y: y, width: paneWidth, height: headerHeight)
        let rightRect = CGRect(x: middleRect.maxX + gap, y: y, width: paneWidth, height: headerHeight)

        drawCard(in: leftRect, context: context, fillColor: UIColor(red: 0.95, green: 0.97, blue: 1.0, alpha: 1.0))
        drawCard(in: middleRect, context: context, fillColor: UIColor.white)
        drawCard(in: rightRect, context: context, fillColor: UIColor(red: 0.96, green: 0.98, blue: 0.96, alpha: 1.0))

        // Left pane: location + metadata
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: UIColor.darkGray
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: UIColor.black
        ]

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIColor.darkGray
        ]
        "LOCATION".draw(
            in: CGRect(x: leftRect.minX + 12, y: leftRect.minY + 14, width: leftRect.width - 24, height: 14),
            withAttributes: titleAttributes
        )

        let preferredLocation = formatHighLevelLocation(from: locationAddress ?? locationData?.address)
            ?? (locationData != nil ? "Recorded location available" : "No location attached to this recording.")
        let locationTextRect = CGRect(
            x: leftRect.minX + 12,
            y: leftRect.minY + 34,
            width: leftRect.width - 24,
            height: 42
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        preferredLocation.draw(
            in: locationTextRect,
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraphStyle
            ]
        )

        var leftY = locationTextRect.maxY + 4
        drawMetadataCompactRow(
            label: "DATE",
            value: formatter.string(from: summaryData.recordingDate),
            x: leftRect.minX + 12,
            y: &leftY,
            width: leftRect.width - 24,
            labelAttributes: labelAttributes,
            valueAttributes: valueAttributes
        )
        drawMetadataCompactRow(
            label: "AI PROVIDER",
            value: summaryData.aiEngine,
            x: leftRect.minX + 12,
            y: &leftY,
            width: leftRect.width - 24,
            labelAttributes: labelAttributes,
            valueAttributes: valueAttributes
        )
        drawMetadataCompactRow(
            label: "MODEL",
            value: summaryData.aiModel,
            x: leftRect.minX + 12,
            y: &leftY,
            width: leftRect.width - 24,
            labelAttributes: labelAttributes,
            valueAttributes: valueAttributes
        )

        // Middle pane: local map
        let mapLabelHeight: CGFloat = 14
        let localMapLabelRect = CGRect(
            x: middleRect.minX + 12,
            y: middleRect.minY + 8,
            width: middleRect.width - 24,
            height: mapLabelHeight
        )
        let localMapRect = CGRect(
            x: middleRect.minX + 12,
            y: localMapLabelRect.maxY + 2,
            width: middleRect.width - 24,
            height: middleRect.height - 26
        )
        let mapLabelAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIColor.darkGray
        ]
        "Local View".draw(in: localMapLabelRect, withAttributes: mapLabelAttributes)

        if headerMaps?.close != nil {
            drawMapImageAspectFill(headerMaps?.close, in: localMapRect, context: context)
        } else {
            drawMapPlaceholder("No Location Data", in: localMapRect, context: context)
        }

        // Right pane: regional map
        let regionalMapLabelRect = CGRect(
            x: rightRect.minX + 12,
            y: rightRect.minY + 8,
            width: rightRect.width - 24,
            height: mapLabelHeight
        )
        let regionalMapRect = CGRect(
            x: rightRect.minX + 12,
            y: regionalMapLabelRect.maxY + 2,
            width: rightRect.width - 24,
            height: rightRect.height - 26
        )
        "Regional View".draw(in: regionalMapLabelRect, withAttributes: mapLabelAttributes)

        if headerMaps?.wide != nil || headerMaps?.close != nil {
            drawMapImageAspectFill(headerMaps?.wide ?? headerMaps?.close, in: regionalMapRect, context: context)
        } else {
            drawMapPlaceholder("No Location Data", in: regionalMapRect, context: context)
        }

        let lineY = y + headerHeight + 8
        drawLine(
            from: CGPoint(x: margins.left, y: lineY),
            to: CGPoint(x: margins.left + contentWidth, y: lineY),
            context: context
        )
        return lineY + 18
    }

    private func drawSimplifiedHeader(summaryData: EnhancedSummaryData, at y: CGFloat, contentWidth: CGFloat, margins: UIEdgeInsets, context: UIGraphicsPDFRendererContext) -> CGFloat {
        // This method is now deprecated - using drawHeaderWithMap instead
        return drawHeaderWithMap(
            summaryData: summaryData,
            locationData: nil,
            locationAddress: nil,
            headerMaps: nil,
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
        pageSize: CGSize,
        contentBottom: CGFloat,
        pageNumber: inout Int,
        exportDate: Date
    ) -> CGFloat {
        var currentY = y

        currentY = checkAndStartNewPageWithBranding(
            currentY: currentY,
            requiredHeight: 80,
            pageSize: pageSize,
            margins: margins,
            context: context,
            contentBottom: contentBottom,
            pageNumber: &pageNumber,
            exportDate: exportDate
        )

        // Section title (text-only)
        currentY = drawSectionTitle("Summary", at: currentY, contentWidth: contentWidth, margins: margins, context: context)

        let attributed = SummaryExportFormatter.attributedSummary(
            for: summaryData.summary,
            baseFontSize: 12,
            textColor: .black
        )
        currentY = drawAttributedSummary(
            attributed,
            at: currentY,
            contentWidth: contentWidth,
            margins: margins,
            context: context,
            pageSize: pageSize,
            contentBottom: contentBottom,
            pageNumber: &pageNumber,
            exportDate: exportDate
        )

        return currentY + 20
    }

    private func drawAttributedSummary(
        _ attributed: NSAttributedString,
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize,
        contentBottom: CGFloat,
        pageNumber: inout Int,
        exportDate: Date
    ) -> CGFloat {
        guard attributed.length > 0 else { return y }

        let cgContext = context.cgContext
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        var currentY = y
        var range = CFRange(location: 0, length: attributed.length)

        while range.length > 0 {
            let availableHeight = contentBottom - currentY
            let pathRect = CGRect(x: 0, y: 0, width: contentWidth, height: availableHeight)
            let path = CGPath(rect: pathRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            let drawnCount = visibleRange.length
            if drawnCount == 0 { break }

            cgContext.saveGState()
            // Flip context so path origin is at bottom-left of rect (Core Text convention).
            cgContext.translateBy(x: margins.left, y: currentY + availableHeight)
            cgContext.scaleBy(x: 1, y: -1)
            // Set text matrix to identity so glyphs render right-side up after context flip.
            cgContext.textMatrix = .identity
            CTFrameDraw(frame, cgContext)
            cgContext.restoreGState()

            currentY += availableHeight

            range = CFRange(location: range.location + drawnCount, length: range.length - drawnCount)
            if range.length > 0 {
                drawPageFooter(context: context, pageSize: pageSize, margins: margins, pageNumber: pageNumber)
                pageNumber += 1
                context.beginPage()
                drawPageHeader(context: context, pageSize: pageSize, margins: margins, exportDate: exportDate)
                currentY = Self.contentTop
            }
        }
        return currentY
    }

    private func drawTasksSection(
        _ tasks: [TaskItem],
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize,
        contentBottom: CGFloat,
        pageNumber: inout Int,
        exportDate: Date
    ) -> CGFloat {
        var currentY = y

        currentY = checkAndStartNewPageWithBranding(
            currentY: currentY,
            requiredHeight: 80,
            pageSize: pageSize,
            margins: margins,
            context: context,
            contentBottom: contentBottom,
            pageNumber: &pageNumber,
            exportDate: exportDate
        )
        currentY = drawSectionTitle("Tasks (\(tasks.count))", at: currentY, contentWidth: contentWidth, margins: margins, context: context)

        for task in tasks {
            currentY = checkAndStartNewPageWithBranding(
                currentY: currentY,
                requiredHeight: 40,
                pageSize: pageSize,
                margins: margins,
                context: context,
                contentBottom: contentBottom,
                pageNumber: &pageNumber,
                exportDate: exportDate
            )

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
        _ reminders: [ReminderItem],
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize,
        contentBottom: CGFloat,
        pageNumber: inout Int,
        exportDate: Date
    ) -> CGFloat {
        var currentY = y

        currentY = checkAndStartNewPageWithBranding(
            currentY: currentY,
            requiredHeight: 80,
            pageSize: pageSize,
            margins: margins,
            context: context,
            contentBottom: contentBottom,
            pageNumber: &pageNumber,
            exportDate: exportDate
        )
        currentY = drawSectionTitle("Reminders (\(reminders.count))", at: currentY, contentWidth: contentWidth, margins: margins, context: context)

        for reminder in reminders {
            currentY = checkAndStartNewPageWithBranding(
                currentY: currentY,
                requiredHeight: 40,
                pageSize: pageSize,
                margins: margins,
                context: context,
                contentBottom: contentBottom,
                pageNumber: &pageNumber,
                exportDate: exportDate
            )

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
        _ titles: [TitleItem],
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize,
        contentBottom: CGFloat,
        pageNumber: inout Int,
        exportDate: Date
    ) -> CGFloat {
        var currentY = y

        currentY = checkAndStartNewPageWithBranding(
            currentY: currentY,
            requiredHeight: 80,
            pageSize: pageSize,
            margins: margins,
            context: context,
            contentBottom: contentBottom,
            pageNumber: &pageNumber,
            exportDate: exportDate
        )
        currentY = drawSectionTitle("Suggested Titles", at: currentY, contentWidth: contentWidth, margins: margins, context: context)

        for (index, title) in titles.enumerated() {
            currentY = checkAndStartNewPageWithBranding(
                currentY: currentY,
                requiredHeight: 30,
                pageSize: pageSize,
                margins: margins,
                context: context,
                contentBottom: contentBottom,
                pageNumber: &pageNumber,
                exportDate: exportDate
            )

            let titleText = "\(index + 1). \(title.text)"

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
        pageSize: CGSize,
        contentBottom: CGFloat,
        pageNumber: inout Int,
        exportDate: Date
    ) -> CGFloat {
        var currentY = y

        currentY = checkAndStartNewPageWithBranding(
            currentY: currentY,
            requiredHeight: 100,
            pageSize: pageSize,
            margins: margins,
            context: context,
            contentBottom: contentBottom,
            pageNumber: &pageNumber,
            exportDate: exportDate
        )
        currentY = drawSectionTitle("Processing Details", at: currentY, contentWidth: contentWidth, margins: margins, context: context)

        let metadataText = """
        AI Engine: \(summaryData.aiEngine)
        AI Model: \(summaryData.aiModel)
        Word Count: \(summaryData.wordCount) words
        Original Length: \(summaryData.originalLength) characters
        Compression Ratio: \(summaryData.formattedCompressionRatio)
        Processing Time: \(summaryData.formattedProcessingTime)
        Quality: \(summaryData.qualityDescription)
        """

        currentY = drawMultilineTextWithBranding(
            metadataText,
            at: currentY,
            contentWidth: contentWidth,
            margins: margins,
            context: context,
            pageSize: pageSize,
            font: UIFont.systemFont(ofSize: 10),
            color: UIColor.darkGray,
            contentBottom: contentBottom,
            pageNumber: &pageNumber,
            exportDate: exportDate
        )

        return currentY
    }

    // MARK: - Data Structures

    // MARK: - Helper Functions

    @MainActor
    private func buildHeaderMapImages(summaryData: EnhancedSummaryData, locationData: LocationData?) async -> HeaderMapImages? {
        guard let locationData else { return nil }

        let closeSize = CGSize(width: 680, height: 360)
        let wideSize = CGSize(width: 680, height: 360)

        let closeImage = loadStoredMapImage(
            for: summaryData.id,
            locationData: locationData,
            size: closeSize
        ) ?? createSmallFallbackMapImage(for: locationData, size: closeSize)

        let wideImage = await createZoomedOutMapImage(
            for: locationData,
            size: wideSize,
            latitudeDelta: 18,
            longitudeDelta: 18
        ) ?? closeImage

        return HeaderMapImages(close: closeImage, wide: wideImage)
    }

    @MainActor
    private func createZoomedOutMapImage(
        for locationData: LocationData,
        size: CGSize,
        latitudeDelta: CLLocationDegrees,
        longitudeDelta: CLLocationDegrees
    ) async -> UIImage? {
        guard locationData.latitude.isFinite,
              locationData.longitude.isFinite,
              size.width > 10,
              size.height > 10 else {
            return nil
        }

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
        options.size = size
        options.scale = UIScreen.main.scale
        options.showsBuildings = false
        options.pointOfInterestFilter = .excludingAll

        let snapshotter = MKMapSnapshotter(options: options)

        do {
            let snapshot: MKMapSnapshotter.Snapshot = try await withCheckedThrowingContinuation { continuation in
                snapshotter.start { snapshot, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let snapshot else {
                        continuation.resume(throwing: NSError(domain: "PDFExportService", code: -1, userInfo: nil))
                        return
                    }
                    continuation.resume(returning: snapshot)
                }
            }

            let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
            let pinImage = UIImage(systemName: "mappin.circle.fill")?
                .withTintColor(.systemRed, renderingMode: .alwaysOriginal)

            return renderer.image { _ in
                snapshot.image.draw(at: .zero)
                if let pinImage {
                    let point = snapshot.point(for: CLLocationCoordinate2D(
                        latitude: locationData.latitude,
                        longitude: locationData.longitude
                    ))
                    let pinSize = CGSize(width: 26, height: 26)
                    let pinRect = CGRect(
                        x: point.x - pinSize.width / 2,
                        y: point.y - pinSize.height,
                        width: pinSize.width,
                        height: pinSize.height
                    )
                    pinImage.draw(in: pinRect)
                }
            }
        } catch {
            print("⚠️ PDFExportService: Regional map generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func drawCard(in rect: CGRect, context: UIGraphicsPDFRendererContext, fillColor: UIColor) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 10)
        fillColor.setFill()
        path.fill()

        context.cgContext.saveGState()
        context.cgContext.setStrokeColor(UIColor(white: 0.82, alpha: 1).cgColor)
        context.cgContext.setLineWidth(1.0)
        context.cgContext.addPath(path.cgPath)
        context.cgContext.strokePath()
        context.cgContext.restoreGState()
    }

    private func drawMetadataRow(
        label: String,
        value: String,
        x: CGFloat,
        y: inout CGFloat,
        width: CGFloat,
        labelAttributes: [NSAttributedString.Key: Any],
        valueAttributes: [NSAttributedString.Key: Any]
    ) {
        label.draw(in: CGRect(x: x, y: y, width: width, height: 13), withAttributes: labelAttributes)
        y += 13

        let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanedValue.draw(in: CGRect(x: x, y: y, width: width, height: 36), withAttributes: valueAttributes)
        y += 44
    }

    private func drawMetadataCompactRow(
        label: String,
        value: String,
        x: CGFloat,
        y: inout CGFloat,
        width: CGFloat,
        labelAttributes: [NSAttributedString.Key: Any],
        valueAttributes: [NSAttributedString.Key: Any]
    ) {
        label.draw(in: CGRect(x: x, y: y, width: width, height: 12), withAttributes: labelAttributes)
        y += 12

        let compactAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10.5),
            .foregroundColor: valueAttributes[.foregroundColor] ?? UIColor.black
        ]
        let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanedValue.draw(in: CGRect(x: x, y: y, width: width, height: 16), withAttributes: compactAttributes)
        y += 20
    }

    private func drawMapImageAspectFill(_ image: UIImage?, in rect: CGRect, context: UIGraphicsPDFRendererContext) {
        let cgContext = context.cgContext
        let clippingPath = UIBezierPath(roundedRect: rect, cornerRadius: 8)

        cgContext.saveGState()
        cgContext.addPath(clippingPath.cgPath)
        cgContext.clip()

        if let image {
            let imageSize = image.size
            let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let drawOrigin = CGPoint(
                x: rect.minX + (rect.width - drawSize.width) / 2,
                y: rect.minY + (rect.height - drawSize.height) / 2
            )
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        } else {
            UIColor.systemGray5.setFill()
            cgContext.fill(rect)
        }

        cgContext.restoreGState()

        cgContext.saveGState()
        cgContext.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
        cgContext.setLineWidth(0.8)
        cgContext.addPath(clippingPath.cgPath)
        cgContext.strokePath()
        cgContext.restoreGState()
    }

    private func drawMapPlaceholder(_ text: String, in rect: CGRect, context: UIGraphicsPDFRendererContext) {
        drawMapImageAspectFill(nil, in: rect, context: context)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: UIColor.gray,
            .paragraphStyle: style
        ]
        text.draw(in: rect.insetBy(dx: 10, dy: 10), withAttributes: attrs)
    }

    private func formatHighLevelLocation(from rawAddress: String?) -> String? {
        guard let rawAddress else { return nil }

        let components = rawAddress
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !components.isEmpty else { return nil }

        let filtered = components.filter { component in
            // Drop likely postal codes-only segments
            let digits = component.filter { $0.isNumber }.count
            return !(digits > 0 && digits == component.count)
        }

        let source = filtered.isEmpty ? components : filtered
        let scoped = source.count > 3 ? Array(source.suffix(3)) : source
        let cleaned = scoped.map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) }

        return cleaned.joined(separator: ", ")
    }

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
            let lines = text.components(separatedBy: .newlines)

            for line in lines {
                let lineAttributedString = NSAttributedString(string: line, attributes: attributes)
                let lineRect = CGRect(x: margins.left, y: currentY, width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
                let lineBoundingRect = lineAttributedString.boundingRect(with: lineRect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)

                if currentY + lineBoundingRect.height > pageSize.height - margins.bottom {
                    context.beginPage()
                    currentY = margins.top
                }

                let drawRect = CGRect(x: margins.left, y: currentY, width: contentWidth, height: lineBoundingRect.height)
                lineAttributedString.draw(in: drawRect)
                currentY += lineBoundingRect.height + 4
            }
        } else {
            let drawRect = CGRect(x: margins.left, y: currentY, width: contentWidth, height: boundingRect.height)
            attributedString.draw(in: drawRect)
            currentY += boundingRect.height
        }

        return currentY
    }

    private func drawMultilineTextWithBranding(
        _ text: String,
        at y: CGFloat,
        contentWidth: CGFloat,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize,
        font: UIFont,
        color: UIColor,
        contentBottom: CGFloat,
        pageNumber: inout Int,
        exportDate: Date
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
        let maxHeightPerPage = contentBottom - margins.top - 50

        if boundingRect.height > maxHeightPerPage {
            let lines = text.components(separatedBy: .newlines)

            for line in lines {
                let lineAttributedString = NSAttributedString(string: line, attributes: attributes)
                let lineRect = CGRect(x: margins.left, y: currentY, width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
                let lineBoundingRect = lineAttributedString.boundingRect(with: lineRect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)

                if currentY + lineBoundingRect.height > contentBottom {
                    drawPageFooter(context: context, pageSize: pageSize, margins: margins, pageNumber: pageNumber)
                    pageNumber += 1
                    context.beginPage()
                    drawPageHeader(context: context, pageSize: pageSize, margins: margins, exportDate: exportDate)
                    currentY = Self.contentTop
                }

                let drawRect = CGRect(x: margins.left, y: currentY, width: contentWidth, height: lineBoundingRect.height)
                lineAttributedString.draw(in: drawRect)
                currentY += lineBoundingRect.height + 4
            }
        } else {
            let drawRect = CGRect(x: margins.left, y: currentY, width: contentWidth, height: boundingRect.height)
            attributedString.draw(in: drawRect)
            currentY += boundingRect.height
        }

        return currentY
    }

    private func checkAndStartNewPage(
        currentY: CGFloat,
        requiredHeight: CGFloat,
        pageSize: CGSize,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext
    ) -> CGFloat {
        if currentY + requiredHeight > pageSize.height - margins.bottom {
            context.beginPage()
            return margins.top
        }
        return currentY
    }

    private func checkAndStartNewPageWithBranding(
        currentY: CGFloat,
        requiredHeight: CGFloat,
        pageSize: CGSize,
        margins: UIEdgeInsets,
        context: UIGraphicsPDFRendererContext,
        contentBottom: CGFloat,
        pageNumber: inout Int,
        exportDate: Date
    ) -> CGFloat {
        if currentY + requiredHeight > contentBottom {
            drawPageFooter(context: context, pageSize: pageSize, margins: margins, pageNumber: pageNumber)
            pageNumber += 1
            context.beginPage()
            drawPageHeader(context: context, pageSize: pageSize, margins: margins, exportDate: exportDate)
            return Self.contentTop
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
