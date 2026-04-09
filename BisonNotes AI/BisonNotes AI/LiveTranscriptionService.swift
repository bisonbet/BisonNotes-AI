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

    /// Set to false when stopping; the tap closure checks this before writing.
    private nonisolated(unsafe) var tapIsActive = false

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
            guard let self, let result else { return }
            Task { @MainActor in
                self.liveTranscript = result.bestTranscription.formattedString
            }
        }

        // Install a single tap that writes to file AND feeds the recognizer.
        // `file` is a strong capture so the AVAudioFile stays alive for the
        // duration of the tap even if self.audioFile is set to nil.
        let file = audioFile
        tapIsActive = true
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.tapIsActive else { return }
            try? file?.write(from: buffer)
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
        tapIsActive = false  // Signal the tap closure to stop writing
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
