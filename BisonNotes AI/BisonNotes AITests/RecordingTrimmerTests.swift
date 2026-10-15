//
//  RecordingTrimmerTests.swift
//  BisonNotes AITests
//

import XCTest
import AVFoundation
@testable import BisonNotes_AI

final class RecordingTrimmerTests: XCTestCase {
    private let sampleRate: Double = 16_000
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    // MARK: Synthetic audio

    /// `seconds` of a 440 Hz tone at `amplitude`, or digital silence at 0.
    private func tone(seconds: Double, amplitude: Float) -> [Float] {
        let count = Int(seconds * sampleRate)
        guard amplitude > 0 else { return [Float](repeating: 0, count: count) }
        return (0..<count).map { amplitude * sin(2 * .pi * 440 * Float($0) / Float(sampleRate)) }
    }

    /// Low-level noise standing in for room tone, well under the threshold.
    private func roomTone(seconds: Double, amplitude: Float = 0.0005) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * sampleRate)).map { _ in
            Float.random(in: -amplitude...amplitude, using: &generator)
        }
    }

    private func temporaryURL(_ ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-test-\(UUID().uuidString).\(ext)")
        temporaryURLs.append(url)
        return url
    }

    private func writeFile(_ samples: [Float], ext: String, settings: [String: Any]) throws -> URL {
        let url = temporaryURL(ext)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        // Scoped so the file is closed (and its header finalized) before reading.
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
        return url
    }

    private func writeWAV(_ samples: [Float]) throws -> URL {
        try writeFile(samples, ext: "wav", settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
    }

    private func writeM4A(_ samples: [Float]) throws -> URL {
        try writeFile(samples, ext: "m4a", settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ])
    }

    // MARK: Range math

    func testClampKeepsRangeInsideRecording() {
        let result = RecordingTrimMath.clamped(start: -5, end: 500, duration: 120)
        XCTAssertEqual(result.start, 0)
        XCTAssertEqual(result.end, 120)
    }

    func testMovingStartPastEndStopsAtMinimumGap() {
        let result = RecordingTrimMath.clamped(start: 80, end: 60, duration: 120, moving: .start)
        XCTAssertEqual(result.end, 60, "the edge not being moved stays put")
        XCTAssertEqual(result.start, 60 - RecordingTrimMath.minimumClipDuration, accuracy: 0.0001)
    }

    func testMovingEndBeforeStartStopsAtMinimumGap() {
        let result = RecordingTrimMath.clamped(start: 30, end: 10, duration: 120, moving: .end)
        XCTAssertEqual(result.start, 30)
        XCTAssertEqual(result.end, 30 + RecordingTrimMath.minimumClipDuration, accuracy: 0.0001)
    }

    func testMinimumGapNearFileEdgesPushesTheOtherHandle() {
        let atEnd = RecordingTrimMath.clamped(start: 120, end: 120, duration: 120, moving: .start)
        XCTAssertEqual(atEnd.end - atEnd.start, RecordingTrimMath.minimumClipDuration, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(atEnd.end, 120)

        let atStart = RecordingTrimMath.clamped(start: 0, end: 0, duration: 120, moving: .end)
        XCTAssertEqual(atStart.start, 0)
        XCTAssertEqual(atStart.end, RecordingTrimMath.minimumClipDuration, accuracy: 0.0001)
    }

    func testClampHandlesNonFiniteInput() {
        let result = RecordingTrimMath.clamped(start: .nan, end: .infinity, duration: 60)
        XCTAssertEqual(result.start, 0)
        XCTAssertEqual(result.end, 60)
        XCTAssertTrue(RecordingTrimMath.clamped(start: 1, end: 2, duration: .nan) == (0, 0))
    }

    func testValidityRequiresRemovingAudioAndAMinimumLength() {
        XCTAssertFalse(RecordingTrimMath.isValid(start: 0, end: 120, duration: 120), "full length is a copy, not a trim")
        XCTAssertFalse(RecordingTrimMath.isValid(start: 0.01, end: 119.99, duration: 120), "within edge tolerance")
        XCTAssertTrue(RecordingTrimMath.isValid(start: 0, end: 60, duration: 120))
        XCTAssertTrue(RecordingTrimMath.isValid(start: 10, end: 120, duration: 120))
        XCTAssertFalse(RecordingTrimMath.isValid(start: 10, end: 10.5, duration: 120), "below minimum length")
        XCTAssertFalse(RecordingTrimMath.isValid(start: 10, end: 130, duration: 120), "past the end")
        XCTAssertFalse(RecordingTrimMath.isValid(start: 0, end: 10, duration: 0))
    }

    func testTimeRangeIsExactForAThreeHourOffset() {
        let start: TimeInterval = 2 * 3600 + 15 * 60 + 3.25
        let end: TimeInterval = 3 * 3600 - 0.5
        let range = RecordingTrimMath.timeRange(start: start, end: end)
        XCTAssertEqual(range.start.seconds, start, accuracy: 0.0001)
        XCTAssertEqual(range.end.seconds, end, accuracy: 0.0001)
        XCTAssertEqual(range.duration.seconds, end - start, accuracy: 0.0001)
    }

    func testPassthroughOnlyForAACContainers() {
        XCTAssertTrue(RecordingTrimMath.prefersPassthrough(for: URL(fileURLWithPath: "/a/rec.m4a")))
        XCTAssertTrue(RecordingTrimMath.prefersPassthrough(for: URL(fileURLWithPath: "/a/rec.M4A")))
        XCTAssertFalse(RecordingTrimMath.prefersPassthrough(for: URL(fileURLWithPath: "/a/rec.wav")))
        XCTAssertFalse(RecordingTrimMath.prefersPassthrough(for: URL(fileURLWithPath: "/a/rec.mp3")))
    }

    func testTrimmedDateStartsWhereTheKeptAudioBegins() {
        let source = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RecordingTrimMath.trimmedRecordingDate(sourceDate: source, start: 90), source.addingTimeInterval(90))
        XCTAssertEqual(RecordingTrimMath.trimmedRecordingDate(sourceDate: source, start: -3), source)
    }

    func testEdgeFormatting() {
        XCTAssertEqual(RecordingTrimMath.formatEdge(0), "0:00.0")
        XCTAssertEqual(RecordingTrimMath.formatEdge(65.37), "1:05.4")
        // Rounded, not truncated, so a difference of two edges reads right.
        XCTAssertEqual(RecordingTrimMath.formatEdge(10_800 - 3611.6), "1:59:48.4")
        XCTAssertEqual(RecordingTrimMath.formatEdge(3 * 3600 + 2 * 60 + 9.9), "3:02:09.9")
        XCTAssertEqual(RecordingTrimMath.formatEdge(-4), "0:00.0")
    }

    // MARK: Silence scan on synthetic buffers

    func testWindowLevelsMatchKnownRMS() {
        // A full-scale square-ish signal of ±0.5 has RMS 0.5 → about -6 dBFS.
        let samples = (0..<1600).map { $0 % 2 == 0 ? Float(0.5) : Float(-0.5) }
        let levels = TrailingSilenceDetector.windowLevelsDB(samples, windowFrames: 800)
        XCTAssertEqual(levels.count, 2)
        XCTAssertEqual(levels[0], 20 * log10(0.5), accuracy: 0.01)

        let silent = TrailingSilenceDetector.windowLevelsDB([Float](repeating: 0, count: 1000), windowFrames: 400)
        XCTAssertEqual(silent.count, 3, "the last partial window still counts")
        XCTAssertTrue(silent.allSatisfy { $0 < -150 })
    }

    func testSuggestsEndAfterSpeechFollowedByLongSilence() {
        let samples = roomTone(seconds: 2) + tone(seconds: 20, amplitude: 0.2) + roomTone(seconds: 60)
        guard case .suggestion(let suggestion) = TrailingSilenceDetector.scan(samples: samples, sampleRate: sampleRate) else {
            return XCTFail("expected a suggestion")
        }
        XCTAssertEqual(suggestion.lastActivityEnd, 22, accuracy: 0.51, "within one window of the tone's end")
        XCTAssertEqual(
            suggestion.suggestedEnd,
            suggestion.lastActivityEnd + TrailingSilenceDetector.Configuration.standard.padding,
            accuracy: 0.0001
        )
        XCTAssertEqual(suggestion.totalDuration, 82, accuracy: 0.001)
        XCTAssertEqual(suggestion.trailingSilence, 82 - suggestion.suggestedEnd, accuracy: 0.0001)
    }

    func testIsolatedClickInDeadAirDoesNotEndTheScan() {
        // A 0.2 s click sits in one window, short of the three-window minimum.
        let samples = tone(seconds: 10, amplitude: 0.2) + roomTone(seconds: 30)
            + tone(seconds: 0.2, amplitude: 0.8) + roomTone(seconds: 30)
        guard case .suggestion(let suggestion) = TrailingSilenceDetector.scan(samples: samples, sampleRate: sampleRate) else {
            return XCTFail("expected a suggestion")
        }
        XCTAssertEqual(suggestion.lastActivityEnd, 10, accuracy: 0.51)
    }

    func testNoSuggestionWhenSpeechRunsToTheEnd() {
        let samples = roomTone(seconds: 5) + tone(seconds: 30, amplitude: 0.2) + roomTone(seconds: 2)
        XCTAssertEqual(TrailingSilenceDetector.scan(samples: samples, sampleRate: sampleRate), .noTrailingSilence)
    }

    func testEntirelySilentRecording() {
        XCTAssertEqual(TrailingSilenceDetector.scan(samples: roomTone(seconds: 30), sampleRate: sampleRate), .entirelySilent)
        XCTAssertEqual(TrailingSilenceDetector.scan(samples: [], sampleRate: sampleRate), .entirelySilent)
    }

    func testQuietSpeechAboveThresholdStillCounts() {
        // -32 dBFS RMS: quiet, but clearly above the -45 dBFS threshold.
        let samples = tone(seconds: 10, amplitude: 0.035) + roomTone(seconds: 30)
        guard case .suggestion(let suggestion) = TrailingSilenceDetector.scan(samples: samples, sampleRate: sampleRate) else {
            return XCTFail("expected a suggestion")
        }
        XCTAssertEqual(suggestion.lastActivityEnd, 10, accuracy: 0.51)
    }

    func testReverseScanRequiresConsecutiveActiveWindows() {
        var scan = TrailingSilenceDetector.ReverseScan(configuration: .standard)
        XCTAssertFalse(scan.feed(levelDB: -20, windowIndex: 9))
        XCTAssertFalse(scan.feed(levelDB: -80, windowIndex: 8), "silence resets the run")
        XCTAssertFalse(scan.feed(levelDB: -20, windowIndex: 7))
        XCTAssertFalse(scan.feed(levelDB: -20, windowIndex: 6))
        XCTAssertTrue(scan.feed(levelDB: -20, windowIndex: 5))
        XCTAssertEqual(scan.lastActiveWindowIndex, 7, "the run's highest window marks the end of activity")
    }

    // MARK: Silence scan on files

    func testFileScanAcrossChunkBoundaries() async throws {
        // 150 s spans three 60 s read chunks; the speech ends inside the first.
        let samples = tone(seconds: 40, amplitude: 0.2) + roomTone(seconds: 110)
        let url = try writeWAV(samples)
        let progressCalls = ProgressRecorder()

        let outcome = try await TrailingSilenceDetector.scan(fileURL: url) { progressCalls.record($0) }

        guard case .suggestion(let suggestion) = outcome else { return XCTFail("expected a suggestion, got \(outcome)") }
        XCTAssertEqual(suggestion.lastActivityEnd, 40, accuracy: 0.51)
        XCTAssertEqual(suggestion.totalDuration, 150, accuracy: 0.01)
        // 300 windows read 120 at a time from the end: the speech is found in
        // the second read, so the first 60 windows are never decoded.
        XCTAssertEqual(progressCalls.values, [0.4, 0.8], "stops reading once activity is found")
    }

    func testFileScanAgreesWithInMemoryScan() async throws {
        let samples = roomTone(seconds: 3) + tone(seconds: 12, amplitude: 0.1) + roomTone(seconds: 45)
        let url = try writeWAV(samples)
        let fromFile = try await TrailingSilenceDetector.scan(fileURL: url)
        let inMemory = TrailingSilenceDetector.scan(samples: samples, sampleRate: sampleRate)
        guard case .suggestion(let a) = fromFile, case .suggestion(let b) = inMemory else {
            return XCTFail("expected suggestions, got \(fromFile) and \(inMemory)")
        }
        XCTAssertEqual(a.lastActivityEnd, b.lastActivityEnd, accuracy: 0.51, "16-bit quantization may shift one window")
    }

    // MARK: Export

    @MainActor
    func testPassthroughTrimOfM4AReadsDurationFromTheExport() async throws {
        let source = try writeM4A(tone(seconds: 30, amplitude: 0.2))
        let output = temporaryURL("m4a")

        let result = try await RecordingTrimmer.export(sourceURL: source, start: 5, end: 17, outputURL: output)

        XCTAssertTrue(result.usedPassthrough)
        XCTAssertEqual(result.duration, 12, accuracy: 0.2, "packet-aligned cut lands close to the request")
        XCTAssertGreaterThan(result.fileSize, 0)
        let player = try AVAudioPlayer(contentsOf: output)
        XCTAssertEqual(player.duration, result.duration, accuracy: 0.1)
    }

    @MainActor
    func testNonAACSourceIsReencoded() async throws {
        let source = try writeWAV(tone(seconds: 10, amplitude: 0.2))
        let output = temporaryURL("m4a")

        let result = try await RecordingTrimmer.export(sourceURL: source, start: 2, end: 6, outputURL: output)

        XCTAssertFalse(result.usedPassthrough)
        XCTAssertEqual(result.duration, 4, accuracy: 0.2)
    }

    @MainActor
    func testInvalidRangeThrowsAndWritesNothing() async throws {
        let source = try writeM4A(tone(seconds: 10, amplitude: 0.2))
        let output = temporaryURL("m4a")

        do {
            _ = try await RecordingTrimmer.export(sourceURL: source, start: 0, end: 10, outputURL: output)
            XCTFail("a full-length range is not a trim")
        } catch RecordingTrimmerError.invalidRange {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}

/// Collects progress callbacks, which arrive off the main actor.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
