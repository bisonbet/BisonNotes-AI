//
//  LogPrivacyTests.swift
//  BisonNotes AITests
//
//  The diagnostic export is emailed to support or anyone else, so recording
//  names, summary titles and file names are scrubbed out of it.
//

import XCTest
@testable import BisonNotes_AI

final class LogPrivacyTests: XCTestCase {
    func testRecordingNamesAndTitlesAreScrubbedFromTheExport() {
        let log = """
        [DEBUG] [Summarization] Updating name from 'Mood Changes After Stopping Lexapro Medication' to 'Navigating Medication Changes And Burnout'
        [ERROR] [BackgroundProcessing] Recording: group project concerns and next steps
        [INFO] Imported Board Meeting Notes.m4a
        """
        let scrubbed = LogPrivacy.redacting(
            [
                "Mood Changes After Stopping Lexapro Medication",
                "Navigating Medication Changes And Burnout",
                "Group Project Concerns and Next Steps",
                "Board Meeting Notes.m4a"
            ],
            in: log
        )
        XCTAssertFalse(scrubbed.contains("Lexapro"))
        XCTAssertFalse(scrubbed.contains("Burnout"))
        XCTAssertFalse(scrubbed.localizedCaseInsensitiveContains("group project"), "Matching ignores case")
        XCTAssertFalse(scrubbed.contains("Board Meeting"))
        XCTAssertTrue(scrubbed.contains("[Summarization] Updating name from"), "Everything else in the line stays readable")
    }

    func testShortSensitiveNamesAreScrubbedAsWholeWords() {
        XCTAssertTrue(LogPrivacy.isRedactable("Therapy"))
        XCTAssertTrue(LogPrivacy.isRedactable("Q3"))
        XCTAssertTrue(LogPrivacy.isRedactable("Team Sync"))
        XCTAssertTrue(LogPrivacy.isRedactable("standup.m4a"))
        XCTAssertTrue(LogPrivacy.isRedactable("Retrospective-Notes"))
        XCTAssertFalse(LogPrivacy.isRedactable(" \n "))
        XCTAssertEqual(
            LogPrivacy.redacting(["Therapy", "Q3"], in: "Opened Therapy; Q3; Physiotherapy; Q30"),
            "Opened [redacted]; [redacted]; Physiotherapy; Q30"
        )
    }

    /// An audio file named after its recording's id must not scrub that id out
    /// of the log lines that identify the recording.
    func testIdentifiersAreNeverScrubbed() {
        let id = "E902566E-9C1C-4281-9E1C-BBA7DF79747A"
        XCTAssertFalse(LogPrivacy.isRedactable(id))
        XCTAssertFalse(LogPrivacy.isRedactable("\(id).m4a"))
        XCTAssertFalse(LogPrivacy.isRedactable(id.lowercased()))
        let line = "Recording UUID: \(id), Transcript UUID: \(id)"
        XCTAssertEqual(LogPrivacy.redacting([id, "\(id).m4a", "Team Sync"], in: line), line)
        // A name that merely contains an id is still a name.
        XCTAssertTrue(LogPrivacy.isRedactable("Call \(id)"))
    }

    func testALongerNameIsReplacedWholeBeforeAShorterOneInsideIt() {
        let scrubbed = LogPrivacy.redacting(["Team Sync", "Team Sync Follow Up"], in: "Opened Team Sync Follow Up")
        XCTAssertEqual(scrubbed, "Opened \(LogPrivacy.placeholder)")
    }

    func testDescribeLogsALengthNeverTheText() {
        XCTAssertEqual(LogPrivacy.describe("Private title"), "<13 chars>")
        XCTAssertEqual(LogPrivacy.describe(nil), "<empty>")
        XCTAssertEqual(LogPrivacy.describe(""), "<empty>")
    }

    func testFileReferencesKeepOnlyOpaqueIdentifiers() {
        let id = "E902566E-9C1C-4281-9E1C-BBA7DF79747A"
        XCTAssertEqual(LogPrivacy.fileReference("\(id).m4a"), "\(id).m4a")
        XCTAssertEqual(LogPrivacy.fileReference("Therapy.m4a"), "<11 chars>")
        XCTAssertEqual(LogPrivacy.fileReference("Private/\(id).m4a"), "<48 chars>")
    }

    func testFileErrorsDoNotIncludeDescriptionsOrUserInfo() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [
            NSFilePathErrorKey: "/private/Therapy.m4a",
            NSLocalizedDescriptionKey: "Could not read Therapy.m4a"
        ])
        XCTAssertEqual(LogPrivacy.errorDescription(error), "domain=NSCocoaErrorDomain, code=260")
    }

    func testOldNamesAndCoordinatesAreScrubbedWithoutDatabaseTerms() {
        let log = """
        [INFO] [BackgroundProcessing] Creating summary for recording: Therapy
        [INFO] [BackgroundProcessing] Saving location data - lat: 39.7817, lon: -89.6501
        [ERROR] [Transcription] Could not resolve URL for recording: A deleted recording
        [DEBUG] [FileManagement] Successfully imported: A former name.m4a
        [INFO] [BackgroundProcessing] Recording name: Renamed title
        """
        let scrubbed = LogPrivacy.redacting([], in: log)
        for sensitive in ["Therapy", "39.7817", "-89.6501", "A deleted recording", "A former name", "Renamed title"] {
            XCTAssertFalse(scrubbed.contains(sensitive))
        }
        XCTAssertTrue(scrubbed.contains("[ERROR] [Transcription] Could not resolve URL for recording:"))
        XCTAssertEqual(scrubbed.components(separatedBy: "\n").count, 5)
    }

    func testLegacyFileMessagesRetainIDsAndUnrelatedMetrics() {
        let id = "E902566E-9C1C-4281-9E1C-BBA7DF79747A"
        let metric = "[INFO] fetched=155 saved=2 alreadyGone=3 recording=\(id)"
        let scrubbed = LogPrivacy.redacting([], in: "Audio file renamed: Therapy.m4a -> \(id).m4a\n\(metric)")
        XCTAssertFalse(scrubbed.contains("Therapy"))
        XCTAssertTrue(scrubbed.contains(id))
        XCTAssertTrue(scrubbed.contains(metric))
    }

    func testShortNamesCannotRedactASegmentOfAnIdentifier() {
        let id = "E902566E-9C1C-4281-9E1C-BBA7DF79747A"
        XCTAssertEqual(LogPrivacy.redacting(["9C1C"], in: "id=\(id) 9C1C"), "id=\(id) [redacted]")
    }

    func testSafeFileReferencesAndErrorCodesRemainUsefulInExports() {
        let id = "E902566E-9C1C-4281-9E1C-BBA7DF79747A"
        let log = """
        [INFO] Starting transcription for: \(id).m4a
        [DEBUG] Found ZIP entry: <17 chars> (compression: 8, size: 2048)
        [ERROR] Audio export: failed to stage <11 chars>: domain=NSCocoaErrorDomain, code=260
        """
        XCTAssertEqual(LogPrivacy.redacting([], in: log), log)
    }

    func testLegacyPathRepairScrubsOldFileNamesAndKeepsTheRecordingID() {
        let id = "E902566E-9C1C-4281-9E1C-BBA7DF79747A"
        let log = "[DEBUG] Updated URL by name match for recording ID \(id): Therapy.m4a -> Private.m4a"
        XCTAssertEqual(
            LogPrivacy.redacting([], in: log),
            "[DEBUG] Updated URL by name match for recording ID \(id): [redacted]"
        )
    }

    func testANameSurroundingAnIdentifierStillLosesItsPrivateText() {
        let id = "E902566E-9C1C-4281-9E1C-BBA7DF79747A"
        XCTAssertEqual(
            LogPrivacy.redacting(["Therapy \(id)"], in: "Opened Therapy \(id)"),
            "Opened [redacted] ids=\(id)"
        )
        XCTAssertEqual(
            LogPrivacy.redacting(["Therapy E902566E"], in: "Opened Therapy \(id)"),
            "Opened [redacted] ids=\(id)"
        )
    }
}
