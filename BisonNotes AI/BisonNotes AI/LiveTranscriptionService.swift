//
//  LiveTranscriptionService.swift
//  BisonNotes AI
//
//  Provides real-time on-device transcription during recording using
//  AVAudioEngine + SFSpeechRecognizer. Also handles writing the audio
//  to a file so recordings made in this mode are saved normally.
//

import Foundation
import AVFoundation
import Speech

/// Lets the audio tap — which runs on the render thread, outside the service's
/// actor — check whether it should still be writing. Reads and writes are both
/// single-word and guarded by the lock, so the unchecked conformance covers only
/// that one field.
private final class TapActivationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func deactivate() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

@MainActor
class LiveTranscriptionService: ObservableObject {

    @Published var liveTranscript: String = ""
    @Published var isActive: Bool = false

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var outputURL: URL?
    private var tempCafURL: URL?
    private var tapActivation: TapActivationFlag?

    // MARK: - Start

    /// Starts live transcription, recording audio to a temporary .caf file.
    /// - Parameter finalURL: The final .m4a URL where audio will be saved on stop.
    func start(finalURL: URL) throws {
        guard !isActive else { return }

        let engine = AVAudioEngine()
        audioEngine = engine
        liveTranscript = ""
        outputURL = finalURL

        // Prepare temporary CAF file for raw PCM writing
        let tempDir = FileManager.default.temporaryDirectory
        let cafURL = tempDir.appendingPathComponent("live_\(UUID().uuidString).caf")
        tempCafURL = cafURL

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Guard against an unconfigured audio session (0 channels / 0 sample rate)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw LiveTranscriptionError.audioEngineSetupFailed
        }

        // Open audio file for writing
        audioFile = try AVAudioFile(forWriting: cafURL, settings: inputFormat.settings)

        // Configure speech recognition
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechRecognizer = recognizer

        guard let recognizer, recognizer.isAvailable else {
            throw LiveTranscriptionError.speechRecognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            let transcript = result.bestTranscription.formattedString
            Task { @MainActor [weak self] in
                self?.liveTranscript = transcript
            }
        }

        // Install a single tap that writes to file AND feeds the recognizer.
        // `file` is a strong capture so the AVAudioFile stays alive for the
        // duration of the tap even if self.audioFile is set to nil.
        guard let file = audioFile else {
            throw LiveTranscriptionError.audioEngineSetupFailed
        }

        // `removeTap` does not guarantee that a callback already dispatched on
        // the render thread has returned, so `stop()` clears this flag first.
        // Without it an in-flight buffer can reach `request.append` after
        // `endAudio()`, which raises. The flag is a class so the nonisolated
        // tap closure can read it without capturing actor-isolated state.
        let tapFlag = TapActivationFlag()
        tapActivation = tapFlag

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            // The callback owns immutable references to the file and request.
            // Stop clears the flag and removes this tap before releasing the
            // service's references.
            guard tapFlag.isActive else { return }
            try? file.write(from: buffer)
            request.append(buffer)
        }

        try engine.start()
        isActive = true

        AppLog.shared.transcription("LiveTranscriptionService: started")
    }

    // MARK: - Stop

    /// Stops recording and transcription. Exports audio to the final .m4a URL.
    /// Returns the final URL and the accumulated transcript text.
    func stop() async -> (url: URL?, transcript: String) {
        guard isActive else { return (nil, "") }

        isActive = false
        // Signal the tap to stop writing before removing it, so a callback
        // already in flight cannot append to the request after endAudio().
        // The tap's immutable captures keep its file and request alive until
        // any in-flight callback has returned.
        tapActivation?.deactivate()
        tapActivation = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil  // Flush and close the file

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        let finalTranscript = liveTranscript

        // Export from .caf to .m4a at the final URL
        guard let cafURL = tempCafURL, let finalURL = outputURL else {
            return (nil, finalTranscript)
        }
        tempCafURL = nil
        outputURL = nil

        do {
            let finalM4AURL = try await exportToM4A(from: cafURL, to: finalURL)
            // Clean up temp .caf
            try? FileManager.default.removeItem(at: cafURL)
            AppLog.shared.transcription("LiveTranscriptionService: stopped, saved to \(finalM4AURL.lastPathComponent)")
            return (finalM4AURL, finalTranscript)
        } catch {
            AppLog.shared.transcription("LiveTranscriptionService: export failed: \(error)", level: .error)
            try? FileManager.default.removeItem(at: cafURL)
            return (nil, finalTranscript)
        }
    }

    // MARK: - Helpers

    private func exportToM4A(from cafURL: URL, to m4aURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: cafURL)

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw LiveTranscriptionError.exportFailed
        }

        try await exportSession.export(to: m4aURL, as: .m4a)
        return m4aURL
    }

    // MARK: - Permission Check

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

enum LiveTranscriptionError: LocalizedError {
    case speechRecognizerUnavailable
    case exportFailed
    case audioEngineSetupFailed

    var errorDescription: String? {
        switch self {
        case .speechRecognizerUnavailable:
            return "On-device speech recognition is not available."
        case .exportFailed:
            return "Failed to save the audio recording."
        case .audioEngineSetupFailed:
            return "Audio input is not available. Check microphone permissions."
        }
    }
}
