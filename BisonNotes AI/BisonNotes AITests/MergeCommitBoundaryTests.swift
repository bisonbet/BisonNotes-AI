//
//  MergeCommitBoundaryTests.swift
//  BisonNotes AITests
//
//  Drives a real segment merge into the window where the merged output exists
//  but Core Data has not acknowledged it — the boundary where both of this
//  path's production bugs lived. Unlike the policy tests, this exercises the
//  wiring: composition, export, the file swap, and the catch's cleanup.
//

import XCTest
@preconcurrency import AVFoundation
@testable import BisonNotes_AI

#if os(iOS)
@MainActor
final class MergeCommitBoundaryTests: XCTestCase {
    private var documents: URL!
    private var createdURLs: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        createdURLs = []
    }

    override func tearDown() async throws {
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: documents.appendingPathComponent("deferred-recovery.json"))
        try await super.tearDown()
    }

    /// Both bugs were about what the catch does with the artifacts, so the
    /// assertions are: the merged output survives, its inputs do not, and the
    /// recovery snapshot names only the output.
    func testMetadataFailureKeepsTheMergedOutputAndReleasesItsInputs() async throws {
        let stem = "mergetest-\(UUID().uuidString)"
        let mainURL = documents.appendingPathComponent("\(stem).m4a")
        let secondSegment = documents.appendingPathComponent("\(stem)_seg2.caf")
        createdURLs.append(contentsOf: [mainURL, secondSegment])

        try writeSilentAudio(at: mainURL, seconds: 0.5)
        try writeSilentAudio(at: secondSegment, seconds: 0.5)

        let viewModel = AudioRecorderViewModel()
        viewModel.mergeCommitFailureForTesting = NSError(
            domain: "MergeCommitBoundaryTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "injected metadata failure"]
        )

        await viewModel.mergeRecordingSegments(
            segments: [mainURL, secondSegment],
            mainURL: mainURL,
            ownsLiveRecordingState: false
        )

        // The merged recording is the only copy of the audio, so it must survive
        // a metadata failure.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: mainURL.path),
            "The merged output must survive a failed metadata commit"
        )

        // Its inputs are superseded; leaving them was the orphan bug.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: secondSegment.path),
            "A superseded source segment must not be left on disk"
        )
        let backups = try FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("merge_backup_") }
        createdURLs.append(contentsOf: backups)
        XCTAssertTrue(backups.isEmpty, "The merge backup must not be left on disk")

        // Snapshotting the inputs alongside the output was the duplication bug.
        let claimed = recoverySnapshotFilenames()
        XCTAssertTrue(
            claimed.contains(mainURL.lastPathComponent),
            "The merged output must be reclaimable; snapshot named \(claimed)"
        )
        XCTAssertFalse(
            claimed.contains(secondSegment.lastPathComponent),
            "A source segment must never be snapshotted beside the merged output"
        )
        XCTAssertFalse(
            claimed.contains(where: { $0.hasPrefix("merge_backup_") }),
            "The backup must never be snapshotted beside the merged output"
        )
    }

    /// The merged file must be the real thing, not a truncated export: its
    /// duration should cover both inputs.
    func testMergedOutputContainsBothSegments() async throws {
        let stem = "mergetest-\(UUID().uuidString)"
        let mainURL = documents.appendingPathComponent("\(stem).m4a")
        let secondSegment = documents.appendingPathComponent("\(stem)_seg2.caf")
        createdURLs.append(contentsOf: [mainURL, secondSegment])

        try writeSilentAudio(at: mainURL, seconds: 0.5)
        try writeSilentAudio(at: secondSegment, seconds: 0.5)

        let viewModel = AudioRecorderViewModel()
        viewModel.mergeCommitFailureForTesting = NSError(domain: "t", code: 1)

        await viewModel.mergeRecordingSegments(
            segments: [mainURL, secondSegment],
            mainURL: mainURL,
            ownsLiveRecordingState: false
        )

        let duration = try await AVURLAsset(url: mainURL).load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.7, "The merged output should span both 0.5s inputs")
    }

    // MARK: - Helpers

    private func recoverySnapshotFilenames() -> Set<String> {
        let url = documents.appendingPathComponent("deferred-recovery.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return TemporaryFileCleanupService.recoveryClaimedFilenames(fromSnapshot: data)
    }

    private func writeSilentAudio(at url: URL, seconds: TimeInterval) throws {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = url.pathExtension.lowercased() == "m4a"
            ? [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1
            ]
            : format.settings

        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleRate * seconds)
        ) else {
            throw NSError(domain: "MergeCommitBoundaryTests", code: 2)
        }
        buffer.frameLength = AVAudioFrameCount(sampleRate * seconds)
        // Non-silent samples, so nothing downstream treats this as an empty
        // startup fragment and skips it during validation.
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<Int(buffer.frameLength) {
                channel[frame] = sin(Float(frame) * 0.01) * 0.25
            }
        }
        try file.write(from: buffer)
    }
}
#endif
