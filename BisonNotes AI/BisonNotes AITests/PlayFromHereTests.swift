//
//  PlayFromHereTests.swift
//  BisonNotes AITests
//
//  Tapping a line of the player's read-along transcript plays from there. With
//  nothing playing there is no player to seek — none exists before the first
//  play or after a stop or the end of the audio — so the tap must start
//  playback at that time, not just seek.
//

import AVFoundation
import XCTest
@testable import BisonNotes_AI

@MainActor
final class PlayFromHereTests: XCTestCase {
    private var audioURL: URL!

    override func setUp() async throws {
        audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("play-from-here-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        let frames = AVAudioFrameCount(16_000 * 4)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: audioURL)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for playback")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testPlayingFromATimeStartsPlaybackThereWhenNothingIsPlaying() async throws {
        let viewModel = AudioRecorderViewModel()
        defer { viewModel.stopPlaying() }
        XCTAssertNil(viewModel.audioPlayer, "Nothing is playing yet, so there is no player to seek")

        viewModel.playRecording(url: audioURL, from: 2.0)
        try await waitUntil { viewModel.isPlaying }

        XCTAssertGreaterThanOrEqual(
            viewModel.audioPlayer?.currentTime ?? 0, 1.9,
            "Playback should start at the tapped line, not the beginning"
        )
    }

    /// A second tap while the first tap's player is still being prepared wins:
    /// the position is read once the player is ready, not copied before.
    func testTheLatestTapWinsWhilePlaybackIsBeingPrepared() async throws {
        let viewModel = AudioRecorderViewModel()
        defer { viewModel.stopPlaying() }
        viewModel.playRecording(url: audioURL, from: 3.0)
        XCTAssertTrue(viewModel.isPreparingPlayback)
        // Let the start get past configuring the session and into preparing
        // the player, where the position used to be copied too early.
        try await Task.sleep(for: .milliseconds(30))
        viewModel.playRecording(url: audioURL, from: 0.5)

        try await waitUntil { viewModel.isPlaying }
        XCTAssertLessThan(
            viewModel.audioPlayer?.currentTime ?? 9, 1.5,
            "Playback should start at the later tap, not the first"
        )
    }

    func testPlayingFromATimeWhilePlayingSeeks() async throws {
        let viewModel = AudioRecorderViewModel()
        defer { viewModel.stopPlaying() }
        viewModel.playRecording(url: audioURL, from: 3.0)
        try await waitUntil { viewModel.isPlaying }
        let player = viewModel.audioPlayer

        viewModel.playRecording(url: audioURL, from: 0.5)

        XCTAssertTrue(viewModel.audioPlayer === player, "A running player is reused, not restarted")
        XCTAssertLessThan(viewModel.audioPlayer?.currentTime ?? 9, 1.5, "It seeks back to the tapped line")
        XCTAssertTrue(viewModel.isPlaying)
    }
}
