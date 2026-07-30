#if os(macOS)
import AppKit
import CoreText
import Foundation

extension MacSummaryExportRenderer {
    static func drawHeader(in context: CGContext, generatedAt: Date) {
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

    static func drawFooter(in context: CGContext, pageNumber: Int) {
        drawLine(
            "— \(pageNumber) —",
            at: CGPoint(x: 287, y: 28),
            font: .systemFont(ofSize: 8),
            color: .darkGray,
            in: context
        )
    }

    static func drawLine(
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
