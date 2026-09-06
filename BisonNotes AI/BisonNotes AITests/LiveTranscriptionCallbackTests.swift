import AVFoundation
import Speech
import XCTest
@testable import BisonNotes_AI

final class LiveTranscriptionCallbackTests: XCTestCase {
    @MainActor
    func testAudioTapCreatedOnMainActorWritesFromBackgroundQueueAndStops() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tap-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<256 { samples[index] = 0.25 }
        let request = SFSpeechAudioBufferRecognitionRequest()
        let gate = LiveTranscriptionTapGate()
        let tap = LiveTranscriptionCallbacks.makeAudioTap(file: file, request: request, gate: gate)
        let invocation = BackgroundTapInvocation(tap: tap, buffer: buffer)

        await invocation.run()
        XCTAssertEqual(file.length, 256)

        gate.deactivate()
        request.endAudio()
        await invocation.run()
        XCTAssertEqual(file.length, 256, "A late callback must neither write nor append after stop")
    }

    @MainActor
    func testBackgroundRecognitionResultDeliversTranscriptOnMainActor() async {
        let delivered = expectation(description: "Transcript delivered on MainActor")
        let handler = LiveTranscriptionCallbacks.makeRecognitionHandler { transcript in
            MainActor.assertIsolated()
            XCTAssertEqual(transcript, "A partial transcript")
            delivered.fulfill()
        }
        await BackgroundRecognitionInvocation(handler: handler).run(includeResult: true)
        await fulfillment(of: [delivered], timeout: 2)
    }

    @MainActor
    func testRecognitionCallbackCreatedOnMainActorAcceptsBackgroundError() async {
        let handler = LiveTranscriptionCallbacks.makeRecognitionHandler { _ in
            XCTFail("An error without a result must not replace the transcript")
        }
        await BackgroundRecognitionInvocation(handler: handler).run()
    }

    /// `stop()` awaits the deactivation off the main actor. The wait itself still
    /// blocks on the lock the tap holds across `AVAudioFile.write` and
    /// `SFSpeechAudioBufferRecognitionRequest.append`, so doing it on the main
    /// thread would park the UI on the tap thread's disk I/O.
    @MainActor
    func testStopWaitsForTheTapWithoutBlockingTheMainActor() async {
        let gate = LiveTranscriptionTapGate()
        let entered = DispatchSemaphore(value: 0)
        let releaseBuffer = DispatchSemaphore(value: 0)
        defer { releaseBuffer.signal() }

        DispatchQueue.global().async {
            gate.whileActive {
                entered.signal()
                _ = releaseBuffer.wait(timeout: .now() + 5)
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        let started = ContinuousClock.now
        // Exactly what `LiveTranscriptionService.stop()` does.
        let stopping = Task { @MainActor in
            await Task.detached { gate.deactivate() }.value
        }
        // Only reachable while the main actor is free. Called directly instead of
        // awaited off it, `deactivate()` would hold the main thread until the
        // buffer above timed out five seconds later.
        let releasing = Task { @MainActor in
            releaseBuffer.signal()
        }
        await releasing.value
        XCTAssertLessThan(
            started.duration(to: .now), .seconds(1),
            "The main actor must stay free while an in-flight buffer finishes"
        )

        await stopping.value
        var ranAfterStop = false
        gate.whileActive { ranAfterStop = true }
        XCTAssertFalse(ranAfterStop, "Stop must still be complete once the await returns")
    }

    func testDeactivationWaitsForAcceptedBufferAndRejectsLaterWork() {
        let gate = LiveTranscriptionTapGate()
        let entered = DispatchSemaphore(value: 0)
        let releaseBuffer = DispatchSemaphore(value: 0)
        let stopping = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let bufferFinished = DispatchSemaphore(value: 0)
        defer { releaseBuffer.signal() }

        DispatchQueue.global().async {
            gate.whileActive {
                entered.signal()
                _ = releaseBuffer.wait(timeout: .now() + 5)
                bufferFinished.signal()
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            stopping.signal()
            gate.deactivate()
            stopped.signal()
        }
        XCTAssertEqual(stopping.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.05), .timedOut)
        releaseBuffer.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(bufferFinished.wait(timeout: .now()), .success)

        var ranAfterStop = false
        gate.whileActive { ranAfterStop = true }
        XCTAssertFalse(ranAfterStop)
        gate.deactivate() // Repeated stop remains harmless.
    }
}

// The test transfers framework objects to one worker and waits for completion
// before accessing them again. These wrappers deliberately preserve the actual
// framework callback types, including any accidental actor precondition.
private final class BackgroundTapInvocation: @unchecked Sendable {
    let tap: AVAudioNodeTapBlock
    let buffer: AVAudioPCMBuffer

    init(tap: @escaping AVAudioNodeTapBlock, buffer: AVAudioPCMBuffer) {
        self.tap = tap
        self.buffer = buffer
    }

    func run() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                XCTAssertFalse(Thread.isMainThread)
                tap(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
                continuation.resume()
            }
        }
    }
}

private final class BackgroundRecognitionInvocation: @unchecked Sendable {
    let handler: (SFSpeechRecognitionResult?, Error?) -> Void

    init(handler: @escaping (SFSpeechRecognitionResult?, Error?) -> Void) {
        self.handler = handler
    }

    func run(includeResult: Bool = false) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                XCTAssertFalse(Thread.isMainThread)
                if includeResult {
                    handler(StubSpeechResult(), nil)
                } else {
                    handler(nil, NSError(domain: "LiveTranscriptionCallbackTests", code: 1))
                }
                continuation.resume()
            }
        }
    }
}

private final class StubSpeechResult: SFSpeechRecognitionResult {
    override var bestTranscription: SFTranscription { StubSpeechTranscription() }
}

private final class StubSpeechTranscription: SFTranscription {
    override var formattedString: String { "A partial transcript" }
}
