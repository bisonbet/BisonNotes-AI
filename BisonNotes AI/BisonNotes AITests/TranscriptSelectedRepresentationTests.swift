import CoreData
import XCTest
@testable import BisonNotes_AI

/// The transcript version the user saves is the one summaries read, and it
/// survives leaving and reopening the editor.
@MainActor
final class TranscriptSelectedRepresentationTests: XCTestCase {
    private var persistenceController: PersistenceController!
    private var coreDataManager: CoreDataManager!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        coreDataManager = CoreDataManager(persistenceController: persistenceController)
    }

    override func tearDownWithError() throws {
        coreDataManager = nil
        persistenceController = nil
    }

    func testSummaryInputFollowsTheSelectedVersion() {
        var transcript = makeTranscript(segments: [
            segment(speaker: "speaker_1", text: "we uh ship it", cleaned: "We ship it."),
            segment(speaker: "speaker_2", text: "friday", cleaned: nil)
        ])

        XCTAssertEqual(transcript.selectedRepresentation, .original)
        XCTAssertEqual(transcript.textForSummarization, "Speaker 1: we uh ship it\nSpeaker 2: friday")

        transcript.selectedRepresentation = .cleaned
        // A segment with no cleanup keeps its original text.
        XCTAssertEqual(transcript.textForSummarization, "Speaker 1: We ship it.\nSpeaker 2: friday")
        XCTAssertEqual(transcript.preservingIdentity().selectedRepresentation, .cleaned)
    }

    func testSingleSpeakerSummaryInputFollowsTheSelectedVersion() {
        var transcript = makeTranscript(segments: [
            segment(speaker: "Speaker", text: "um hello there", cleaned: "Hello there.")
        ])
        transcript.selectedRepresentation = .cleaned

        XCTAssertEqual(transcript.textForSummarization, "Hello there.")
    }

    func testChoosingAVersionIsAnUnsavedChange() {
        let segments = [segment(speaker: "speaker_1", text: "raw", cleaned: "Raw.")]
        let saved = TranscriptEditorSnapshot(segments: segments, speakerMappings: [:], representation: .original)
        let switched = TranscriptEditorSnapshot(segments: segments, speakerMappings: [:], representation: .cleaned)

        XCTAssertNotEqual(saved, switched)
        XCTAssertTrue(saved.hasSameContent(as: switched))
    }

    func testSavedVersionPersistsAndIsKeptByLaterSaves() throws {
        let recordingId = try insertSavedRecording()
        let workflow = RecordingWorkflowManager(
            persistenceController: persistenceController,
            coreDataManager: coreDataManager
        )
        let segments = [segment(speaker: "speaker_1", text: "raw", cleaned: "Raw.")]

        _ = try workflow.createTranscript(for: recordingId, segments: segments)
        XCTAssertEqual(try coreDataManager.fetchTranscriptData(for: recordingId)?.selectedRepresentation, .original)

        _ = try workflow.createTranscript(for: recordingId, segments: segments, selectedRepresentation: .cleaned)
        XCTAssertEqual(try coreDataManager.fetchTranscriptData(for: recordingId)?.selectedRepresentation, .cleaned)

        // A save that does not choose a version (a rerun, a relabel) keeps it.
        _ = try workflow.createTranscript(for: recordingId, segments: segments)
        XCTAssertEqual(try coreDataManager.fetchTranscriptData(for: recordingId)?.selectedRepresentation, .cleaned)

        _ = try workflow.createTranscript(for: recordingId, segments: segments, selectedRepresentation: .original)
        XCTAssertEqual(try coreDataManager.fetchTranscriptData(for: recordingId)?.selectedRepresentation, .original)
    }

    // MARK: - Helpers

    private func segment(speaker: String, text: String, cleaned: String?) -> TranscriptSegment {
        TranscriptSegment(
            speaker: speaker,
            text: text,
            startTime: 0,
            endTime: 1,
            cleanup: cleaned.map { TranscriptSegmentCleanup(normalizedText: $0) }
        )
    }

    private func makeTranscript(segments: [TranscriptSegment]) -> TranscriptData {
        TranscriptData(
            recordingURL: URL(fileURLWithPath: "/tmp/representation.m4a"),
            recordingName: "Representation",
            recordingDate: Date(timeIntervalSince1970: 0),
            segments: segments
        )
    }

    private func insertSavedRecording() throws -> UUID {
        let context = coreDataManager.managedObjectContext
        let recording = RecordingEntry(context: context)
        let id = UUID()
        recording.id = id
        recording.recordingName = "Representation"
        recording.recordingDate = Date()
        recording.createdAt = Date()
        try context.save()
        return id
    }
}
