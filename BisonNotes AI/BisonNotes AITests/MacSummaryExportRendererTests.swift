#if os(macOS)
import AppKit
import PDFKit
import XCTest
@testable import BisonNotes_AI

final class MacSummaryExportRendererTests: XCTestCase {
    @MainActor
    func testPDFWithLocationIncludesDedicatedMapPage() throws {
        let summary = TestHelpers.createMockEnhancedSummaryData()
        let location = LocationData(
            latitude: 40.7128,
            longitude: -74.0060,
            address: "New York, NY"
        )
        let image = makeTestImage()

        let data = try MacSummaryExportRenderer.pdfData(
            summaryData: summary,
            locationData: location,
            locationAddress: location.address,
            mapImages: .init(close: image, wide: image)
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        let lastPage = try XCTUnwrap(document.page(at: document.pageCount - 1))

        XCTAssertGreaterThanOrEqual(document.pageCount, 2)
        XCTAssertTrue(lastPage.string?.contains("Location Maps") == true)
        XCTAssertTrue(lastPage.string?.contains("Local View") == true)
        XCTAssertTrue(lastPage.string?.contains("Regional View") == true)
    }

    @MainActor
    private func makeTestImage() -> NSImage {
        let image = NSImage(size: CGSize(width: 680, height: 360))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: image.size)).fill()
        image.unlockFocus()
        return image
    }
}
#endif
