//
//  BisonNotesAIIntegrationTests.swift
//  BisonNotes AITests
//
//  Created by Tim Champ on 7/26/25.
//

import XCTest
@testable import BisonNotes_AI

@MainActor
final class BisonNotesAIIntegrationTests: XCTestCase {
    private var persistenceController: PersistenceController!
    private var appCoordinator: AppDataCoordinator!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        appCoordinator = AppDataCoordinator(persistenceController: persistenceController)
        tempDirectory = try TestHelpers.createTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? TestHelpers.cleanupTemporaryDirectory(tempDirectory)
        }
        tempDirectory = nil
        appCoordinator = nil
        persistenceController = nil
    }

    @MainActor
    func testRecordingTranscriptSummaryStayLinkedByUUID() throws {
        let audioURL = tempDirectory.appendingPathComponent("workflow-recording.m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)

        let recordingId = appCoordinator.addRecording(
            url: audioURL,
            name: "Workflow Recording",
            date: Date(timeIntervalSince1970: 1_770_000_000),
            fileSize: 1_024,
            duration: 60,
            quality: .whisperOptimized
        )
        let transcriptId = try XCTUnwrap(appCoordinator.addTranscript(
            for: recordingId,
            segments: [
                TranscriptSegment(speaker: "Speaker 1", text: "Discuss the release checklist.", startTime: 0, endTime: 3)
            ],
            engine: .fluidAudio,
            processingTime: 0.2,
            confidence: 0.95
        ))
        let summaryId = try XCTUnwrap(appCoordinator.addSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: "Release checklist discussion with enough detail to be considered a real generated summary.",
            tasks: [TaskItem(text: "Run the regression gate")],
            titles: [TitleItem(text: "Release Checklist")],
            contentType: .meeting,
            aiEngine: "Test",
            aiModel: "fixture",
            originalLength: 80,
            processingTime: 0.1
        ))

        let complete = try XCTUnwrap(appCoordinator.getCompleteRecordingData(id: recordingId))
        XCTAssertEqual(complete.recording.id, recordingId)
        XCTAssertEqual(complete.recording.transcriptId, transcriptId)
        XCTAssertEqual(complete.recording.summaryId, summaryId)
        XCTAssertEqual(complete.transcript?.recordingId, recordingId)
        XCTAssertEqual(complete.summary?.recordingId, recordingId)
        XCTAssertEqual(complete.summary?.transcriptId, transcriptId)
    }

    @MainActor
    func testTranscriptReplacementPreservesTranscriptIdAndUpdatesSegments() throws {
        let recordingId = try createRecording(named: "Transcript Replacement")
        let firstId = try XCTUnwrap(appCoordinator.addTranscript(
            for: recordingId,
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "Old text", startTime: 0, endTime: 1)]
        ))

        let secondId = try XCTUnwrap(appCoordinator.addTranscript(
            for: recordingId,
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "New replacement text", startTime: 0, endTime: 2)],
            engine: .fluidAudio,
            confidence: 0.9
        ))

        let transcript = try XCTUnwrap(appCoordinator.getTranscriptData(for: recordingId))
        XCTAssertEqual(secondId, firstId)
        XCTAssertEqual(transcript.segments.map(\.text), ["New replacement text"])
        XCTAssertEqual(transcript.engine, .fluidAudio)
    }

    @MainActor
    func testShortSummaryIsRejectedWithoutReplacingExistingSummary() throws {
        let recordingId = try createRecording(named: "Summary Guard")
        let transcriptId = try XCTUnwrap(appCoordinator.addTranscript(
            for: recordingId,
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "Enough transcript text", startTime: 0, endTime: 2)]
        ))
        let existingSummaryId = try XCTUnwrap(appCoordinator.addSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: "This existing summary is long enough to be persisted before a failed regeneration attempt.",
            aiModel: "fixture",
            originalLength: 60
        ))

        let rejected = appCoordinator.addSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: "Too short",
            aiModel: "fixture",
            originalLength: 9
        )

        let summary = try XCTUnwrap(appCoordinator.getSummary(for: recordingId))
        XCTAssertNil(rejected)
        XCTAssertEqual(summary.id, existingSummaryId)
    }

    @MainActor
    func testLegacySummaryMigrationUsesURLFallbackAndIsIdempotent() throws {
        let audioURL = tempDirectory.appendingPathComponent("legacy-summary.m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        let recordingId = appCoordinator.addRecording(
            url: audioURL,
            name: "Legacy Summary Recording",
            date: Date(timeIntervalSince1970: 1_770_000_000),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )
        let transcriptId = try XCTUnwrap(appCoordinator.addTranscript(
            for: recordingId,
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "Legacy transcript", startTime: 0, endTime: 1)]
        ))

        let legacyURL = URL(fileURLWithPath: audioURL.path + "/../\(audioURL.lastPathComponent)")
        let legacySummary = EnhancedSummaryData(
            id: UUID(),
            recordingId: nil,
            transcriptId: transcriptId,
            recordingURL: legacyURL,
            recordingName: "Legacy Summary Recording",
            recordingDate: Date(timeIntervalSince1970: 1_770_000_000),
            summary: "This legacy summary contains enough content to be migrated safely.",
            aiEngine: "Legacy",
            aiModel: "legacy-fixture",
            originalLength: 80
        )
        let data = try JSONEncoder().encode([legacySummary])

        let firstReport = SummaryManager.shared.migrateLegacySummaries(from: data, using: appCoordinator)
        XCTAssertEqual(firstReport.migratedCount, 1)
        XCTAssertEqual(firstReport.unresolvedCount, 0)
        XCTAssertTrue(firstReport.didComplete)

        let firstEntry = try XCTUnwrap(appCoordinator.getSummary(for: recordingId))
        XCTAssertEqual(firstEntry.id, legacySummary.id)
        XCTAssertEqual(firstEntry.recordingId, recordingId)
        XCTAssertEqual(firstEntry.transcriptId, transcriptId)

        let secondReport = SummaryManager.shared.migrateLegacySummaries(from: data, using: appCoordinator)
        XCTAssertEqual(secondReport.migratedCount, 1)
        XCTAssertTrue(secondReport.didComplete)
        XCTAssertEqual(appCoordinator.getAllSummaries().count, 1)
        XCTAssertEqual(appCoordinator.getSummary(for: recordingId)?.id, legacySummary.id)
    }

    @MainActor
    func testLegacySummaryMigrationPreservesExistingCoreDataSummary() throws {
        let audioURL = tempDirectory.appendingPathComponent("existing-core-data-summary.m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        let recordingId = appCoordinator.addRecording(
            url: audioURL,
            name: "Existing Core Data Summary",
            date: Date(timeIntervalSince1970: 1_770_000_000),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )
        let transcriptId = try XCTUnwrap(appCoordinator.addTranscript(
            for: recordingId,
            segments: [TranscriptSegment(speaker: "Speaker 1", text: "Current transcript", startTime: 0, endTime: 1)]
        ))
        let existingSummaryId = try XCTUnwrap(appCoordinator.addSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: "The current Core Data summary must remain authoritative over stale legacy storage.",
            aiModel: "current-fixture",
            originalLength: 80
        ))
        let legacySummary = EnhancedSummaryData(
            id: UUID(),
            recordingId: recordingId,
            transcriptId: transcriptId,
            recordingURL: audioURL,
            recordingName: "Existing Core Data Summary",
            recordingDate: Date(timeIntervalSince1970: 1_760_000_000),
            summary: "This stale legacy summary must not replace newer Core Data content.",
            aiEngine: "Legacy",
            aiModel: "legacy-fixture",
            originalLength: 70,
            generatedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        let report = SummaryManager.shared.migrateLegacySummaries(
            from: try JSONEncoder().encode([legacySummary]),
            using: appCoordinator
        )

        XCTAssertTrue(report.didComplete)
        XCTAssertEqual(report.migratedCount, 0)
        XCTAssertEqual(report.preservedExistingCount, 1)
        XCTAssertEqual(appCoordinator.getAllSummaries().count, 1)
        let persisted = try XCTUnwrap(appCoordinator.getSummary(for: recordingId))
        XCTAssertEqual(persisted.id, existingSummaryId)
        XCTAssertEqual(
            persisted.summary,
            "The current Core Data summary must remain authoritative over stale legacy storage."
        )
    }

    @MainActor
    func testLegacySummaryMigrationRetainsCorruptDataAndDoesNotMarkComplete() throws {
        let defaults = try makeMigrationDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set(Data("not-json".utf8), forKey: SummaryManager.legacySummariesKey)

        let report = SummaryManager.shared.migrateLegacySummariesIfNeeded(using: appCoordinator, defaults: defaults)

        XCTAssertFalse(report.didComplete)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertNotNil(defaults.data(forKey: SummaryManager.legacySummariesKey))
        XCTAssertNil(defaults.object(forKey: SummaryManager.legacyMigrationVersionKey))
    }

    @MainActor
    func testLegacySummaryMigrationRetainsUnresolvedSummaryForRecovery() throws {
        let defaults = try makeMigrationDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let missingURL = tempDirectory.appendingPathComponent("not-in-core-data.m4a")
        let legacySummary = makeLegacySummary(for: missingURL)
        defaults.set(try JSONEncoder().encode([legacySummary]), forKey: SummaryManager.legacySummariesKey)

        let report = SummaryManager.shared.migrateLegacySummariesIfNeeded(using: appCoordinator, defaults: defaults)

        XCTAssertFalse(report.didComplete)
        XCTAssertEqual(report.unresolvedCount, 1)
        XCTAssertNotNil(defaults.data(forKey: SummaryManager.legacySummariesKey))
        XCTAssertNil(defaults.object(forKey: SummaryManager.legacyMigrationVersionKey))
        XCTAssertEqual(appCoordinator.getAllSummaries().count, 0)
    }

    @MainActor
    func testLegacySummaryMigrationDeletesKeyOnlyAfterAllItemsMigrate() throws {
        let defaults = try makeMigrationDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let matchingURL = tempDirectory.appendingPathComponent("matching-summary.m4a")
        try TestHelpers.createMockAudioFile(at: matchingURL)
        let matchingID = appCoordinator.addRecording(
            url: matchingURL,
            name: "Matching Summary",
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )
        let matchingSummary = makeLegacySummary(for: matchingURL)
        let unresolvedSummary = makeLegacySummary(for: tempDirectory.appendingPathComponent("unresolved-summary.m4a"))
        defaults.set(try JSONEncoder().encode([matchingSummary, unresolvedSummary]), forKey: SummaryManager.legacySummariesKey)

        let partialReport = SummaryManager.shared.migrateLegacySummariesIfNeeded(using: appCoordinator, defaults: defaults)
        XCTAssertFalse(partialReport.didComplete)
        XCTAssertEqual(partialReport.migratedCount, 1)
        XCTAssertNotNil(defaults.data(forKey: SummaryManager.legacySummariesKey))
        XCTAssertEqual(appCoordinator.getSummary(for: matchingID)?.id, matchingSummary.id)

        let unresolvedURL = unresolvedSummary.recordingURL
        try TestHelpers.createMockAudioFile(at: unresolvedURL)
        _ = appCoordinator.addRecording(
            url: unresolvedURL,
            name: "Unresolved Summary",
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )

        let completedReport = SummaryManager.shared.migrateLegacySummariesIfNeeded(using: appCoordinator, defaults: defaults)
        XCTAssertTrue(completedReport.didComplete)
        XCTAssertEqual(completedReport.migratedCount, 2)
        XCTAssertNil(defaults.data(forKey: SummaryManager.legacySummariesKey))
        XCTAssertEqual(defaults.integer(forKey: SummaryManager.legacyMigrationVersionKey), SummaryManager.legacyMigrationVersion)
    }

    @MainActor
    private func createRecording(named name: String) throws -> UUID {
        let audioURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        return appCoordinator.addRecording(
            url: audioURL,
            name: name,
            date: Date(),
            fileSize: 1_024,
            duration: 10,
            quality: .whisperOptimized
        )
    }

    private var defaultsSuiteName: String {
        "BisonNotesAIIntegrationTests.LegacySummaryMigration.\(name)"
    }

    private func makeMigrationDefaults() throws -> UserDefaults {
        let suiteName = defaultsSuiteName
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "BisonNotesAIIntegrationTests", code: 1)
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeLegacySummary(for url: URL) -> EnhancedSummaryData {
        EnhancedSummaryData(
            id: UUID(),
            recordingId: nil,
            recordingURL: url,
            recordingName: url.deletingPathExtension().lastPathComponent,
            recordingDate: Date(timeIntervalSince1970: 1_770_000_000),
            summary: "This legacy summary contains enough content to be migrated safely.",
            aiEngine: "Legacy",
            aiModel: "legacy-fixture",
            originalLength: 80
        )
    }
}
