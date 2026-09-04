//
//  SummaryPresencePolicyTests.swift
//  BisonNotes AITests
//

import XCTest
@testable import BisonNotes_AI

final class SummaryPresencePolicyTests: XCTestCase {
    func testRelationshipWinsOverStaleNotStartedStatus() {
        XCTAssertTrue(
            SummaryPresencePolicy.hasStoredSummary(
                relationshipExists: true,
                summaryID: nil,
                status: ProcessingStatus.notStarted.rawValue
            )
        )
    }

    func testSummaryIdentifierWinsOverStaleNotStartedStatus() {
        XCTAssertTrue(
            SummaryPresencePolicy.hasStoredSummary(
                relationshipExists: false,
                summaryID: UUID(),
                status: ProcessingStatus.notStarted.rawValue
            )
        )
    }

    func testCompletedStatusSupportsAnUnfaultedSummary() {
        XCTAssertTrue(
            SummaryPresencePolicy.hasStoredSummary(
                relationshipExists: false,
                summaryID: nil,
                status: ProcessingStatus.completed.rawValue
            )
        )
    }

    func testNoStoredSummaryRemainsAvailableForGeneration() {
        XCTAssertFalse(
            SummaryPresencePolicy.hasStoredSummary(
                relationshipExists: false,
                summaryID: nil,
                status: ProcessingStatus.notStarted.rawValue
            )
        )
    }

    func testStoredMetadataAvoidsRelationshipLookup() {
        var relationshipWasRead = false
        func relationshipExists() -> Bool {
            relationshipWasRead = true
            return false
        }

        XCTAssertTrue(
            SummaryPresencePolicy.hasStoredSummary(
                relationshipExists: relationshipExists(),
                summaryID: UUID(),
                status: ProcessingStatus.notStarted.rawValue
            )
        )
        XCTAssertFalse(relationshipWasRead)
    }
}
