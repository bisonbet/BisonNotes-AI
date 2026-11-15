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

    func testOneShortWordIsNotScrubbedEverywhere() {
        // A recording named "Meeting" must not erase that word from every line.
        XCTAssertFalse(LogPrivacy.isRedactable("Meeting"))
        XCTAssertFalse(LogPrivacy.isRedactable("Q3"))
        XCTAssertTrue(LogPrivacy.isRedactable("Team Sync"))
        XCTAssertTrue(LogPrivacy.isRedactable("standup.m4a"))
        XCTAssertTrue(LogPrivacy.isRedactable("Retrospective-Notes"))
        XCTAssertEqual(LogPrivacy.redacting(["Meeting"], in: "Content type: Meeting"), "Content type: Meeting")
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
}
