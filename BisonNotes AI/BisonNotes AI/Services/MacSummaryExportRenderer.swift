#if os(macOS)
import AppKit
import CoreText
import Foundation
enum MacSummaryExportRenderer {
    enum RenderError: LocalizedError {
        case invalidDocument
        case documentTooLarge
        case pdfContextUnavailable
        var errorDescription: String? {
            switch self {
            case .invalidDocument:
                return "The summary did not contain enough information to export."
            case .documentTooLarge:
                return "The summary is too large to export safely."
            case .pdfContextUnavailable:
                return "The Mac PDF renderer could not create an output document."
            }
        }
    }
    private static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let textRect = CGRect(x: 50, y: 52, width: 512, height: 688)
    static func rtfData(
        summaryData: EnhancedSummaryData,
        locationData: LocationData?,
        locationAddress: String?
    ) throws -> Data {
        let document = try attributedDocument(
            summaryData: summaryData,
            locationData: locationData,
            locationAddress: locationAddress
        )
        let data = try document.data(
            from: NSRange(location: 0, length: document.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        guard !data.isEmpty else { throw RenderError.invalidDocument }
        return data
    }
    static func pdfData(
        summaryData: EnhancedSummaryData,
        locationData: LocationData?,
        locationAddress: String?
    ) throws -> Data {
        let document = try attributedDocument(
            summaryData: summaryData,
            locationData: locationData,
            locationAddress: locationAddress
        )
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw RenderError.pdfContextUnavailable
        }
        var mediaBox = pageRect
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw RenderError.pdfContextUnavailable
        }
        let framesetter = CTFramesetterCreateWithAttributedString(document as CFAttributedString)
        var location = 0
        var pageNumber = 1
        while location < document.length {
            context.beginPDFPage(nil)
            drawHeader(in: context, generatedAt: summaryData.generatedAt)
            drawFooter(in: context, pageNumber: pageNumber)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            guard visibleRange.length > 0 else {
                context.endPDFPage()
                context.closePDF()
                throw RenderError.invalidDocument
            }
            CTFrameDraw(frame, context)
            context.endPDFPage()
            location += visibleRange.length
            pageNumber += 1
        }
        context.closePDF()
        guard output.length > 0 else { throw RenderError.invalidDocument }
        return output as Data
    }

    private static func attributedDocument(
        summaryData: EnhancedSummaryData,
        locationData: LocationData?,
        locationAddress: String?
    ) throws -> NSAttributedString {
        let recordingName = summaryData.recordingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recordingName.isEmpty else { throw RenderError.invalidDocument }

        let document = NSMutableAttributedString()
        appendTitle(recordingName, to: document)
        appendMetadata(summaryData, to: document)
        appendLocation(locationData, address: locationAddress, to: document)
        appendSection("Summary", body: cleanedMarkdown(summaryData.summary), to: document)

        if let notes = summaryData.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            appendSection("User Notes", body: cleanedMarkdown(notes), to: document)
        }
        appendTasks(summaryData.tasks, to: document)
        appendReminders(summaryData.reminders, to: document)
        appendTitles(summaryData.titles, to: document)
        appendProcessingDetails(summaryData, to: document)
        appendFooter(summaryData.generatedAt, to: document)

        guard document.length > 0 else { throw RenderError.invalidDocument }
        guard document.length * 100 <= 10_000_000 else { throw RenderError.documentTooLarge }
        return document
    }
}

private extension MacSummaryExportRenderer {
    private static func appendTitle(_ title: String, to document: NSMutableAttributedString) {
        let style = paragraph(alignment: .center, spacing: 14)
        append(
            title + "\n",
            font: .boldSystemFont(ofSize: 26),
            color: .black,
            paragraphStyle: style,
            to: document
        )
    }

    private static func appendMetadata(_ summary: EnhancedSummaryData, to document: NSMutableAttributedString) {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let lines = [
            "Recording Date: \(formatter.string(from: summary.recordingDate))",
            "AI Provider: \(summary.aiEngine)",
            "AI Model: \(summary.aiModel)",
            "Content Type: \(summary.contentType.rawValue)",
            "Generated: " + DateFormatter.localizedString(
                from: summary.generatedAt,
                dateStyle: .medium,
                timeStyle: .short
            )
        ]
        append(
            lines.joined(separator: "\n") + "\n\n",
            font: .systemFont(ofSize: 11),
            color: .darkGray,
            paragraphStyle: paragraph(spacing: 3),
            to: document
        )
    }

    private static func appendLocation(
        _ location: LocationData?,
        address: String?,
        to document: NSMutableAttributedString
    ) {
        guard let location else { return }
        appendSectionHeading("Location", to: document)

        var lines: [String] = []
        if let address = address ?? location.address,
           !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(address)
        }
        lines.append(String(format: "Coordinates: %.5f, %.5f", location.latitude, location.longitude))
        if let accuracy = location.accuracy {
            lines.append(String(format: "Accuracy: ±%.0f meters", accuracy))
        }
        append(
            lines.joined(separator: "\n") + "\n\n",
            font: .systemFont(ofSize: 11),
            color: .black,
            paragraphStyle: paragraph(spacing: 3),
            to: document
        )
    }

    private static func appendSection(
        _ title: String,
        body: String,
        to document: NSMutableAttributedString
    ) {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        appendSectionHeading(title, to: document)
        append(
            body + "\n\n",
            font: .systemFont(ofSize: 12),
            color: .black,
            paragraphStyle: paragraph(spacing: 4, lineSpacing: 2),
            to: document
        )
    }

    private static func appendTasks(_ tasks: [TaskItem], to document: NSMutableAttributedString) {
        guard !tasks.isEmpty else { return }
        appendSectionHeading("Tasks (\(tasks.count))", to: document)
        for task in tasks {
            append(
                "• [\(task.priority.rawValue)] \(task.displayText)\n",
                font: .systemFont(ofSize: 11),
                color: color(for: task.priority),
                paragraphStyle: listParagraph(),
                to: document
            )
        }
        document.append(NSAttributedString(string: "\n"))
    }

    private static func appendReminders(_ reminders: [ReminderItem], to document: NSMutableAttributedString) {
        guard !reminders.isEmpty else { return }
        appendSectionHeading("Reminders (\(reminders.count))", to: document)
        for reminder in reminders {
            append(
                "• [\(reminder.urgency.rawValue)] \(reminder.displayText)\n",
                font: .systemFont(ofSize: 11),
                color: color(for: reminder.urgency),
                paragraphStyle: listParagraph(),
                to: document
            )
        }
        document.append(NSAttributedString(string: "\n"))
    }

    private static func appendTitles(_ titles: [TitleItem], to document: NSMutableAttributedString) {
        guard !titles.isEmpty else { return }
        appendSectionHeading("Suggested Titles", to: document)
        let body = titles.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        append(
            body + "\n\n",
            font: .systemFont(ofSize: 11),
            color: .black,
            paragraphStyle: paragraph(spacing: 3),
            to: document
        )
    }

    private static func appendProcessingDetails(
        _ summary: EnhancedSummaryData,
        to document: NSMutableAttributedString
    ) {
        appendSectionHeading("Processing Details", to: document)
        let lines = [
            "Word Count: \(summary.wordCount) words",
            "Original Length: \(summary.originalLength) characters",
            "Compression Ratio: \(summary.formattedCompressionRatio)",
            "Processing Time: \(summary.formattedProcessingTime)"
        ]
        append(
            lines.joined(separator: "\n") + "\n\n",
            font: .systemFont(ofSize: 10),
            color: .darkGray,
            paragraphStyle: paragraph(spacing: 3),
            to: document
        )
    }

    private static func appendFooter(_ date: Date, to document: NSMutableAttributedString) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        append(
            "Summary export · BisonNotes AI\nExported \(formatter.string(from: date))\n",
            font: .systemFont(ofSize: 9),
            color: .darkGray,
            paragraphStyle: paragraph(alignment: .center, spacing: 3),
            to: document
        )
    }

    private static func appendSectionHeading(_ title: String, to document: NSMutableAttributedString) {
        append(
            title + "\n",
            font: .boldSystemFont(ofSize: 16),
            color: .black,
            paragraphStyle: paragraph(spacing: 7),
            to: document
        )
        append(
            "— — —\n",
            font: .systemFont(ofSize: 9),
            color: .darkGray,
            paragraphStyle: paragraph(spacing: 5),
            to: document
        )
    }

    private static func append(
        _ text: String,
        font: NSFont,
        color: NSColor,
        paragraphStyle: NSParagraphStyle,
        to document: NSMutableAttributedString
    ) {
        document.append(NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        ))
    }

    private static func paragraph(
        alignment: NSTextAlignment = .left,
        spacing: CGFloat,
        lineSpacing: CGFloat = 0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.paragraphSpacing = spacing
        style.lineSpacing = lineSpacing
        return style
    }

    private static func listParagraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = 16
        style.paragraphSpacing = 3
        return style
    }

    private static func cleanedMarkdown(_ source: String) -> String {
        var text = source
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
        let replacements: [(String, String)] = [
            (#"(?m)^#{1,6}\s+"#, ""),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "$1 ($2)"),
            (#"(?m)^[-*+]\s+"#, "• "),
            (#"\*\*|__|`"#, "")
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func color(for priority: TaskItem.Priority) -> NSColor {
        switch priority {
        case .high: return .systemRed
        case .medium: return .systemOrange
        case .low: return .systemGreen
        }
    }

    private static func color(for urgency: ReminderItem.Urgency) -> NSColor {
        switch urgency {
        case .immediate: return .systemRed
        case .today: return .systemOrange
        case .thisWeek: return .systemBlue
        case .later: return .systemGreen
        }
    }

    private static func drawHeader(in context: CGContext, generatedAt: Date) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        drawLine(
            "BisonNotes AI · Summary Export · \(formatter.string(from: generatedAt))",
            at: CGPoint(x: 50, y: 760),
            font: .systemFont(ofSize: 8),
            color: .darkGray,
            in: context
        )
    }

    private static func drawFooter(in context: CGContext, pageNumber: Int) {
        drawLine(
            "— \(pageNumber) —",
            at: CGPoint(x: 287, y: 28),
            font: .systemFont(ofSize: 8),
            color: .darkGray,
            in: context
        )
    }

    private static func drawLine(
        _ text: String,
        at point: CGPoint,
        font: NSFont,
        color: NSColor,
        in context: CGContext
    ) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        ))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
#endif
