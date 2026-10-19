import XCTest
@testable import BisonNotes_AI

/// The MLX system instruction rides along with every request, so anything it
/// repeats from the request prompt is sent twice.
final class MLXSwiftPromptBuilderTests: XCTestCase {
    private let transcript = Array(repeating: "word", count: 1_200).joined(separator: " ")

    private var composers: [(String, SummaryPromptComposer)] {
        [
            ("default", SummaryPromptComposer(preset: .standard, detailLevel: .balanced, comedyMode: .off)),
            ("business", SummaryPromptComposer(preset: .businessMeeting, detailLevel: .balanced, comedyMode: .off)),
            ("custom", SummaryPromptComposer(
                preset: .custom,
                customText: "Only the decisions.",
                detailLevel: .balanced,
                comedyMode: .off
            )),
            ("custom meeting", SummaryPromptComposer(
                preset: .custom,
                customText: "Only the decisions.",
                recordingType: .meeting,
                detailLevel: .balanced,
                comedyMode: .off
            ))
        ]
    }

    private func occurrences(of marker: String, in text: String) -> Int {
        text.components(separatedBy: marker).count - 1
    }

    func testDetailBlockIsSentOncePerRequest() {
        for (name, composer) in composers {
            let system = MLXSwiftPromptBuilder.systemInstruction(composer)
            let requests = [
                ("complete", MLXSwiftPromptBuilder.completePrompt(transcript: transcript, composer)),
                ("consolidation", MLXSwiftPromptBuilder.consolidationPrompt(
                    encodedChunks: "Chunk 1:\nSummary:\nA plan.",
                    originalWordCount: 2_400,
                    composer
                ))
            ]
            // The custom block names "<<<" in its preamble; count the fence line itself.
            let marker = composer.ownsSummaryFormat ? "<<<\n" : "Summary Detail:"
            XCTAssertFalse(system.contains("Summary Detail:"), "\(name): detail belongs in the request prompt")
            XCTAssertFalse(system.contains("<<<\n"), "\(name): custom text belongs in the request prompt")
            XCTAssertFalse(system.contains("Recording Type:"), "\(name): the recording type rides in the detail block")
            for (kind, prompt) in requests {
                XCTAssertEqual(
                    occurrences(of: marker, in: system + prompt), 1,
                    "\(name) \(kind): the detail block must be sent exactly once"
                )
            }
        }
    }

    func testRequestDetailIsSizedToItsTranscript() {
        let composer = SummaryPromptComposer(preset: .standard, detailLevel: .balanced, comedyMode: .off)
        let complete = MLXSwiftPromptBuilder.completePrompt(transcript: transcript, composer)
        let consolidation = MLXSwiftPromptBuilder.consolidationPrompt(
            encodedChunks: "Chunk 1:\nSummary:\nA plan.",
            originalWordCount: 2_400,
            composer
        )
        XCTAssertTrue(complete.contains("Target approximately 120-180 words"))
        XCTAssertTrue(consolidation.contains("Target approximately 240-360 words"), "Consolidation sizes to the whole transcript")
        XCTAssertFalse(complete.contains("padding it to meet a fixed length"), "The unsized variant is no longer sent")
    }

    func testSystemInstructionDoesNotRestateFormatOrDetailRules() {
        let standard = MLXSwiftPromptBuilder.systemInstruction(
            SummaryPromptComposer(preset: .standard, detailLevel: .balanced, comedyMode: .off)
        )
        XCTAssertFalse(standard.contains("Markdown"))
        XCTAssertFalse(standard.contains("selected detail level"))
        XCTAssertTrue(standard.contains("1. A summary based on what was actually discussed"))
        XCTAssertTrue(standard.contains("Follow the request's summary detail instructions"))
    }

    func testCustomPromptKeepsItsOwnershipOfTheSummary() {
        let custom = SummaryPromptComposer(
            preset: .custom,
            customText: "Only the decisions.",
            recordingType: .meeting,
            detailLevel: .balanced,
            comedyMode: .snarky
        )
        XCTAssertEqual(custom.effectiveComedyMode, .off)

        let system = MLXSwiftPromptBuilder.systemInstruction(custom)
        let complete = MLXSwiftPromptBuilder.completePrompt(transcript: transcript, custom)
        let consolidation = MLXSwiftPromptBuilder.consolidationPrompt(
            encodedChunks: "Chunk 1:\nSummary:\nA plan.",
            originalWordCount: 2_400,
            custom
        )
        XCTAssertTrue(system.contains("Follow the user's summary instructions for the narrative summary"))
        for prompt in [system, complete, consolidation] {
            XCTAssertFalse(prompt.contains("Summary Detail:"))
            XCTAssertFalse(prompt.contains("### 1. Overview"), "A custom prompt owns the summary's structure")
        }
        for prompt in [complete, consolidation] {
            XCTAssertTrue(prompt.contains("<<<\nOnly the decisions.\n>>>"))
            XCTAssertTrue(prompt.contains("Recording Type: Meeting (selected by the user)"))
            XCTAssertTrue(prompt.contains("## Tasks"), "Parser section headers stay")
        }
    }
}
