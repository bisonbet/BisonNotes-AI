//
//  ExportLocationPrivacyTests.swift
//  BisonNotes AITests
//
//  A summary export carries the recording's location only when the user chose
//  "with location". A recording's location is often the user's home, and a
//  shared export must not reveal it by default.
//

import XCTest
@testable import BisonNotes_AI

@MainActor
final class ExportLocationPrivacyTests: XCTestCase {
    private let address = "742 Evergreen Terrace, Springfield"

    private func makeSummary() -> EnhancedSummaryData {
        EnhancedSummaryData(
            recordingId: UUID(),
            recordingURL: URL(fileURLWithPath: "/tmp/export-location.m4a"),
            recordingName: "Kitchen planning",
            recordingDate: Date(),
            summary: "We planned the kitchen renovation and agreed on a budget.",
            aiModel: "fixture",
            promptTemplate: nil,
            originalLength: 60
        )
    }

    private func makeLocation() -> LocationData {
        LocationData(latitude: 39.7817, longitude: -89.6501, timestamp: Date(), accuracy: 5, address: address)
    }

    private func rtfText(_ data: Data) throws -> String {
        try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ).string
    }

    func testAnExportWithoutLocationLeavesThePlaceOut() throws {
        let data = try RTFExportService.shared.generateDocument(
            summaryData: makeSummary(),
            locationData: nil,
            locationAddress: nil
        )
        let text = try rtfText(data)
        XCTAssertTrue(text.contains("kitchen renovation"), "The summary itself is exported")
        XCTAssertFalse(text.contains("Evergreen"), "No address when the user chose without location")
        XCTAssertFalse(text.contains("39.78"), "No coordinates when the user chose without location")
    }

    func testAnExportWithLocationIncludesIt() throws {
        let data = try RTFExportService.shared.generateDocument(
            summaryData: makeSummary(),
            locationData: makeLocation(),
            locationAddress: address
        )
        XCTAssertTrue(try rtfText(data).contains("Evergreen"), "With location, the place is in the export")
    }
}
