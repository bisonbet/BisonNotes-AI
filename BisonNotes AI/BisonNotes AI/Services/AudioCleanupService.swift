//
//  AudioCleanupService.swift
//  BisonNotes AI
//
//  Applies real audio cleanup processing to improve transcription accuracy:
//  - High-pass filter to remove low-frequency rumble
//  - Noise gate to reduce background noise
//  - Dynamic normalization based on audio analysis
//  - Peak limiting to prevent clipping
//

import Foundation
import AVFoundation
import Accelerate

actor AudioCleanupService {

    static let shared = AudioCleanupService()

    private init() {}

    // MARK: - Configuration

    struct CleanupConfig {
        /// High-pass filter cutoff frequency in Hz (removes rumble below this)
        var highPassCutoff: Float = 80.0

        /// Noise gate threshold in dB (signals below this are attenuated)
        var noiseGateThreshold: Float = -50.0

        /// Target peak level in dB for normalization
        var targetPeakLevel: Float = -3.0

        /// Whether to apply noise reduction
        var applyNoiseReduction: Bool = true

        /// Noise reduction strength (0.0 to 1.0)
        var noiseReductionStrength: Float = 0.6

        static let `default` = CleanupConfig()
        static let aggressive = CleanupConfig(
            highPassCutoff: 100.0,
            noiseGateThreshold: -45.0,
            targetPeakLevel: -1.0,
            noiseReductionStrength: 0.8
        )
    }

    // MARK: - Public API

    /// Processes an audio file with real cleanup operations.
    /// Returns the URL of a cleaned temporary file. The original file is not modified.
    func cleanAudio(at sourceURL: URL, config: CleanupConfig = .default) async throws -> URL {
        let startTime = Date()
        AppLog.shared.fileManagement("AudioCleanupService: Starting audio cleanup for \(sourceURL.lastPathComponent)")

        // Validate source file
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw AudioCleanupError.fileNotFound
        }

        // Load audio file
        let audioFile = try AVAudioFile(forReading: sourceURL)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard frameCount > 0 else {
            throw AudioCleanupError.emptyAudio
        }

        AppLog.shared.fileManagement("Audio format: \(format.sampleRate)Hz, \(format.channelCount) channels, \(frameCount) frames", level: .debug)

        // Read audio data into buffer
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioCleanupError.bufferAllocationFailed
        }
        try audioFile.read(into: inputBuffer)
        inputBuffer.frameLength = frameCount

        // Process the audio
        let processedBuffer = try await processAudio(buffer: inputBuffer, config: config)

        // Write to output file
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("cleaned_\(UUID().uuidString).m4a")

        try await writeAudioFile(buffer: processedBuffer, to: outputURL, originalFormat: format)

        let duration = Date().timeIntervalSince(startTime)
        AppLog.shared.fileManagement("AudioCleanupService: Cleanup completed in \(String(format: "%.2f", duration))s")

        return outputURL
    }

    /// Removes a temporary cleaned audio file after transcription completes.
    func removeTempFile(at url: URL) {
        guard url.path.contains(FileManager.default.temporaryDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Audio Processing Pipeline

    private func processAudio(buffer: AVAudioPCMBuffer, config: CleanupConfig) async throws -> AVAudioPCMBuffer {
        guard let floatData = buffer.floatChannelData else {
            throw AudioCleanupError.invalidAudioFormat
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sampleRate = Float(buffer.format.sampleRate)

        AppLog.shared.fileManagement("Processing \(frameCount) frames across \(channelCount) channels", level: .debug)

        // Create output buffer
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            throw AudioCleanupError.bufferAllocationFailed
        }
        outputBuffer.frameLength = buffer.frameLength

        guard let outputData = outputBuffer.floatChannelData else {
            throw AudioCleanupError.bufferAllocationFailed
        }

        // Process each channel
        for channel in 0..<channelCount {
            var samples = Array(UnsafeBufferPointer(start: floatData[channel], count: frameCount))

            // Step 1: Analyze audio for noise profile (first 0.5 seconds assumed to be noise)
            let noiseProfile = analyzeNoiseProfile(samples: samples, sampleRate: sampleRate)
            AppLog.shared.fileManagement("Channel \(channel): Noise floor estimated at \(String(format: "%.1f", noiseProfile.noiseFloorDB)) dB", level: .debug)

            // Step 2: Apply high-pass filter to remove rumble
            samples = applyHighPassFilter(samples: samples, cutoffHz: config.highPassCutoff, sampleRate: sampleRate)

            // Step 3: Apply noise reduction if enabled
            if config.applyNoiseReduction {
                samples = applyNoiseReduction(
                    samples: samples,
                    noiseProfile: noiseProfile,
                    strength: config.noiseReductionStrength,
                    sampleRate: sampleRate
                )
            }

            // Step 4: Apply noise gate
            samples = applyNoiseGate(samples: samples, thresholdDB: config.noiseGateThreshold)

            // Step 5: Normalize to target peak level
            samples = normalizeAudio(samples: samples, targetPeakDB: config.targetPeakLevel)

            // Step 6: Apply soft limiter to prevent clipping
            samples = applySoftLimiter(samples: samples)

            // Copy to output buffer
            for i in 0..<frameCount {
                outputData[channel][i] = samples[i]
            }
        }

        return outputBuffer
    }

    // MARK: - DSP Operations

    private struct NoiseProfile {
        var noiseFloorDB: Float
        var noiseSpectrum: [Float]
    }

    private func analyzeNoiseProfile(samples: [Float], sampleRate: Float) -> NoiseProfile {
        // Analyze first 0.5 seconds (or less if audio is shorter) to estimate noise floor
        let analysisSamples = min(Int(sampleRate * 0.5), samples.count)
        guard analysisSamples > 0 else {
            return NoiseProfile(noiseFloorDB: -60, noiseSpectrum: [])
        }

        let analysisSegment = Array(samples.prefix(analysisSamples))

        // Calculate RMS of the analysis segment
        var rms: Float = 0
        vDSP_rmsqv(analysisSegment, 1, &rms, vDSP_Length(analysisSamples))

        // Convert to dB
        let noiseFloorDB = 20 * log10(max(rms, 1e-10))

        // Simple spectral analysis for noise profile (using FFT)
        let fftSize = 2048
        let noiseSpectrum = computeAverageSpectrum(samples: analysisSegment, fftSize: fftSize)

        return NoiseProfile(noiseFloorDB: noiseFloorDB, noiseSpectrum: noiseSpectrum)
    }

    private func computeAverageSpectrum(samples: [Float], fftSize: Int) -> [Float] {
        guard samples.count >= fftSize else {
            return Array(repeating: 0, count: fftSize / 2)
        }

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return Array(repeating: 0, count: fftSize / 2)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var accumulatedMagnitudes = Array(repeating: Float(0), count: fftSize / 2)
        var windowCount = 0
        let hopSize = fftSize / 2

        // Apply Hann window and compute FFT for overlapping windows
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var realPart = [Float](repeating: 0, count: fftSize / 2)
        var imagPart = [Float](repeating: 0, count: fftSize / 2)

        var position = 0
        while position + fftSize <= samples.count {
            // Extract and window the segment
            var segment = Array(samples[position..<(position + fftSize)])
            vDSP_vmul(segment, 1, window, 1, &segment, 1, vDSP_Length(fftSize))

            // Perform FFT
            segment.withUnsafeMutableBufferPointer { segmentPtr in
                realPart.withUnsafeMutableBufferPointer { realPtr in
                    imagPart.withUnsafeMutableBufferPointer { imagPtr in
                        var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                        segmentPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                        }
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                        // Compute magnitudes and accumulate
                        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
                        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

                        vDSP_vadd(accumulatedMagnitudes, 1, magnitudes, 1, &accumulatedMagnitudes, 1, vDSP_Length(fftSize / 2))
                    }
                }
            }

            windowCount += 1
            position += hopSize
        }

        // Average the accumulated magnitudes
        if windowCount > 0 {
            var divisor = Float(windowCount)
            vDSP_vsdiv(accumulatedMagnitudes, 1, &divisor, &accumulatedMagnitudes, 1, vDSP_Length(fftSize / 2))
        }

        return accumulatedMagnitudes
    }

    private func applyHighPassFilter(samples: [Float], cutoffHz: Float, sampleRate: Float) -> [Float] {
        // Butterworth high-pass filter (2nd order)
        let nyquist = sampleRate / 2
        let normalizedCutoff = cutoffHz / nyquist

        // Calculate filter coefficients
        let c = tan(.pi * normalizedCutoff)
        let c2 = c * c
        let sqrt2 = Float(sqrt(2.0))
        let a0 = 1 / (1 + sqrt2 * c + c2)

        let b0 = a0
        let b1 = -2 * a0
        let b2 = a0
        let a1 = 2 * a0 * (c2 - 1)
        let a2 = a0 * (1 - sqrt2 * c + c2)

        // Apply filter using direct form II transposed
        var output = [Float](repeating: 0, count: samples.count)
        var z1: Float = 0
        var z2: Float = 0

        for i in 0..<samples.count {
            let input = samples[i]
            let result = b0 * input + z1
            z1 = b1 * input - a1 * result + z2
            z2 = b2 * input - a2 * result
            output[i] = result
        }

        AppLog.shared.fileManagement("Applied high-pass filter at \(cutoffHz)Hz", level: .debug)
        return output
    }

    private func applyNoiseReduction(samples: [Float], noiseProfile: NoiseProfile, strength: Float, sampleRate: Float) -> [Float] {
        // Spectral subtraction noise reduction
        let fftSize = 2048
        let hopSize = fftSize / 4
        let log2n = vDSP_Length(log2(Float(fftSize)))

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return samples
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Create analysis and synthesis windows
        var analysisWindow = [Float](repeating: 0, count: fftSize)
        var synthesisWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&analysisWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_hann_window(&synthesisWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Pad input for overlap-add
        let paddedInput = [Float](repeating: 0, count: fftSize / 2) + samples + [Float](repeating: 0, count: fftSize / 2)
        var output = [Float](repeating: 0, count: paddedInput.count)

        var realPart = [Float](repeating: 0, count: fftSize / 2)
        var imagPart = [Float](repeating: 0, count: fftSize / 2)

        var position = 0
        while position + fftSize <= paddedInput.count {
            // Extract and window segment
            var segment = Array(paddedInput[position..<(position + fftSize)])
            vDSP_vmul(segment, 1, analysisWindow, 1, &segment, 1, vDSP_Length(fftSize))

            // Forward FFT
            segment.withUnsafeMutableBufferPointer { segmentPtr in
                realPart.withUnsafeMutableBufferPointer { realPtr in
                    imagPart.withUnsafeMutableBufferPointer { imagPtr in
                        var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                        segmentPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                        }
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
            }

            // Compute magnitude and phase
            var magnitudes = [Float](repeating: 0, count: fftSize / 2)
            var phases = [Float](repeating: 0, count: fftSize / 2)

            for i in 0..<(fftSize / 2) {
                let real = realPart[i]
                let imag = imagPart[i]
                magnitudes[i] = sqrt(real * real + imag * imag)
                phases[i] = atan2(imag, real)
            }

            // Spectral subtraction
            for i in 0..<min(magnitudes.count, noiseProfile.noiseSpectrum.count) {
                let noiseEstimate = sqrt(noiseProfile.noiseSpectrum[i]) * strength
                magnitudes[i] = max(magnitudes[i] - noiseEstimate, magnitudes[i] * 0.1)
            }

            // Reconstruct complex spectrum
            for i in 0..<(fftSize / 2) {
                realPart[i] = magnitudes[i] * cos(phases[i])
                imagPart[i] = magnitudes[i] * sin(phases[i])
            }

            // Inverse FFT
            var reconstructed = [Float](repeating: 0, count: fftSize)
            realPart.withUnsafeMutableBufferPointer { realPtr in
                imagPart.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_INVERSE))

                    reconstructed.withUnsafeMutableBufferPointer { outputPtr in
                        outputPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                            vDSP_ztoc(&splitComplex, 1, complexPtr, 2, vDSP_Length(fftSize / 2))
                        }
                    }
                }
            }

            // Scale by FFT size
            var scale = 1.0 / Float(fftSize)
            vDSP_vsmul(reconstructed, 1, &scale, &reconstructed, 1, vDSP_Length(fftSize))

            // Apply synthesis window and overlap-add
            vDSP_vmul(reconstructed, 1, synthesisWindow, 1, &reconstructed, 1, vDSP_Length(fftSize))

            for i in 0..<fftSize {
                output[position + i] += reconstructed[i]
            }

            position += hopSize
        }

        // Remove padding
        let result = Array(output[fftSize/2..<(fftSize/2 + samples.count)])
        AppLog.shared.fileManagement("Applied spectral subtraction noise reduction (strength: \(String(format: "%.0f", strength * 100))%)", level: .debug)
        return result
    }

    private func applyNoiseGate(samples: [Float], thresholdDB: Float) -> [Float] {
        let threshold = pow(10, thresholdDB / 20)
        let releaseSamples = 1000

        var output = [Float](repeating: 0, count: samples.count)
        var envelope: Float = 0
        var gateOpen = false
        var gateCounter = 0

        for i in 0..<samples.count {
            let absValue = abs(samples[i])

            // Update envelope follower
            if absValue > envelope {
                envelope = absValue
            } else {
                envelope *= 0.9999
            }

            // Gate logic
            if envelope > threshold {
                gateOpen = true
                gateCounter = releaseSamples
            } else if gateCounter > 0 {
                gateCounter -= 1
            } else {
                gateOpen = false
            }

            // Apply gate with smooth attack/release
            if gateOpen {
                output[i] = samples[i]
            } else {
                // Soft attenuation when gate is closed
                output[i] = samples[i] * 0.1
            }
        }

        AppLog.shared.fileManagement("Applied noise gate at \(thresholdDB)dB threshold", level: .debug)
        return output
    }

    private func normalizeAudio(samples: [Float], targetPeakDB: Float) -> [Float] {
        // Find current peak
        var maxVal: Float = 0
        vDSP_maxmgv(samples, 1, &maxVal, vDSP_Length(samples.count))

        guard maxVal > 0 else { return samples }

        // Calculate gain needed
        let currentPeakDB = 20 * log10(maxVal)
        let gainDB = targetPeakDB - currentPeakDB
        var gain = pow(10, gainDB / 20)

        // Apply gain
        var output = [Float](repeating: 0, count: samples.count)
        vDSP_vsmul(samples, 1, &gain, &output, 1, vDSP_Length(samples.count))

        AppLog.shared.fileManagement("Normalized audio: \(String(format: "%.1f", currentPeakDB))dB to \(String(format: "%.1f", targetPeakDB))dB (gain: \(String(format: "%.1f", gainDB))dB)", level: .debug)
        return output
    }

    private func applySoftLimiter(samples: [Float]) -> [Float] {
        // Soft clipping to prevent harsh distortion
        let threshold: Float = 0.9
        let ratio: Float = 0.3

        return samples.map { sample in
            let absVal = abs(sample)
            if absVal > threshold {
                let excess = absVal - threshold
                let compressed = threshold + excess * ratio
                return sample > 0 ? min(compressed, 1.0) : max(-compressed, -1.0)
            }
            return sample
        }
    }

    // MARK: - File I/O

    private func writeAudioFile(buffer: AVAudioPCMBuffer, to url: URL, originalFormat: AVAudioFormat) async throws {
        // First write to a temporary CAF file (lossless), then convert to M4A
        let tempCAFURL = url.deletingPathExtension().appendingPathExtension("caf")

        // Write PCM data to CAF file
        let outputFile = try AVAudioFile(
            forWriting: tempCAFURL,
            settings: originalFormat.settings,
            commonFormat: originalFormat.commonFormat,
            interleaved: originalFormat.isInterleaved
        )
        try outputFile.write(from: buffer)

        // Convert CAF to M4A using AVAssetExportSession
        let asset = AVURLAsset(url: tempCAFURL)

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempCAFURL)
            throw AudioCleanupError.exportSessionFailed
        }

        // Clean up temp CAF file after export completes (success or failure)
        defer { try? FileManager.default.removeItem(at: tempCAFURL) }

        try await exportSession.export(to: url, as: .m4a)
    }
}

// MARK: - Errors

enum AudioCleanupError: LocalizedError {
    case fileNotFound
    case emptyAudio
    case exportSessionFailed
    case noAudioTrack
    case bufferAllocationFailed
    case invalidAudioFormat

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "The audio file was not found."
        case .emptyAudio:
            return "The audio file appears to be empty."
        case .exportSessionFailed:
            return "Could not create audio processing session."
        case .noAudioTrack:
            return "No audio track found in the file."
        case .bufferAllocationFailed:
            return "Failed to allocate audio processing buffer."
        case .invalidAudioFormat:
            return "The audio format is not supported for cleanup."
        }
    }
}
