//
//  AudioChunkingModels.swift
//  Audio Journal
//
//  Data models for audio file chunking functionality
//

import Foundation
import AVFoundation
import CoreMedia

// MARK: - Audio Chunk Model

struct AudioChunk: Identifiable, Codable {
    let id: UUID
    let originalURL: URL
    let chunkURL: URL
    let sequenceNumber: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let fileSize: Int64
    let duration: TimeInterval

    init(originalURL: URL, chunkURL: URL, sequenceNumber: Int, startTime: TimeInterval, endTime: TimeInterval, fileSize: Int64) {
        self.id = UUID()
        self.originalURL = originalURL
        self.chunkURL = chunkURL
        self.sequenceNumber = sequenceNumber
        self.startTime = startTime
        self.endTime = endTime
        self.fileSize = fileSize
        self.duration = endTime - startTime
    }
}

// MARK: - Transcript Chunk Model

struct TranscriptChunk: Identifiable, Codable {
    let id: UUID
    let chunkId: UUID
    let sequenceNumber: Int
    let transcript: String
    let segments: [TranscriptSegment]
    let startTime: TimeInterval
    let endTime: TimeInterval
    let processingTime: TimeInterval?
    /// Chunk-local Parakeet word timings. These remain ephemeral until the
    /// existing reassembly path offsets them to the complete source timeline.
    let timedWords: [TimedTranscriptWord]?
    let createdAt: Date

    init(
        chunkId: UUID,
        sequenceNumber: Int,
        transcript: String,
        segments: [TranscriptSegment],
        startTime: TimeInterval,
        endTime: TimeInterval,
        processingTime: TimeInterval? = nil,
        timedWords: [TimedTranscriptWord]? = nil
    ) {
        self.id = UUID()
        self.chunkId = chunkId
        self.sequenceNumber = sequenceNumber
        self.transcript = transcript
        self.segments = segments
        self.startTime = startTime
        self.endTime = endTime
        self.processingTime = processingTime
        self.timedWords = timedWords
        self.createdAt = Date()
    }
}

// MARK: - Chunking Strategy

enum ChunkingStrategy {
    case fileSize(maxBytes: Int64)
    case duration(maxSeconds: TimeInterval)
    case combined(maxBytes: Int64, maxSeconds: TimeInterval)

    static let whisper = ChunkingStrategy.duration(maxSeconds: 2 * 60 * 60) // 2 hours
    static let onDeviceAI = ChunkingStrategy.duration(maxSeconds: 10 * 60) // 10 minutes
    static let mistralAI = ChunkingStrategy.combined(maxBytes: 24 * 1024 * 1024, maxSeconds: 1300) // 24MB and 1300 seconds

    var description: String {
        switch self {
        case .fileSize(let maxBytes):
            return "File size limit: \(maxBytes / 1024 / 1024) MB"
        case .duration(let maxSeconds):
            if maxSeconds < 60 {
                return "Duration limit: \(Int(maxSeconds)) seconds"
            }
            return "Duration limit: \(Int(maxSeconds / 60)) minutes"
        case .combined(let maxBytes, let maxSeconds):
            return "Combined limits: \(maxBytes / 1024 / 1024) MB and \(Int(maxSeconds / 60)) minutes"
        }
    }
}

// MARK: - Chunking Configuration

struct ChunkingConfig {
    let strategy: ChunkingStrategy
    let overlapSeconds: TimeInterval
    let tempDirectory: URL

    init(strategy: ChunkingStrategy, overlapSeconds: TimeInterval = 5.0, tempDirectory: URL? = nil) {
        self.strategy = strategy
        self.overlapSeconds = overlapSeconds
        self.tempDirectory = tempDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("AudioChunks")
    }

    static func config(for engine: TranscriptionEngine) -> ChunkingConfig {
        switch engine {
        case .notConfigured:
            return ChunkingConfig(strategy: .whisper) // Default fallback for unconfigured state
        case .whisper:
            return ChunkingConfig(strategy: .whisper)
        case .fluidAudio:
            return ChunkingConfig(strategy: .onDeviceAI)
        case .mistralAI:
            return ChunkingConfig(strategy: .mistralAI)
        }
    }
}

// MARK: - Chunking Result

struct ChunkingResult {
    let chunks: [AudioChunk]
    let totalDuration: TimeInterval
    let totalSize: Int64
    let chunkingTime: TimeInterval
    let needsChunking: Bool

    init(chunks: [AudioChunk], totalDuration: TimeInterval, totalSize: Int64, chunkingTime: TimeInterval) {
        self.chunks = chunks
        self.totalDuration = totalDuration
        self.totalSize = totalSize
        self.chunkingTime = chunkingTime
        self.needsChunking = chunks.count > 1
    }
}

// MARK: - Reassembly Result

struct ReassemblyResult {
    let transcriptData: TranscriptData
    let totalSegments: Int
    let reassemblyTime: TimeInterval
    let chunks: [TranscriptChunk]
    /// One absolute, sorted, clamped, overlap-deduplicated word collection
    /// produced by `reassembleTranscript`. Nil means no chunk carried timing.
    let timedWords: [TimedTranscriptWord]?
}

// MARK: - Recording Finalization Validation

struct AudioAssetInspection: Equatable, Sendable {
    let fileSize: Int64
    let duration: TimeInterval
    let hasAudioTrack: Bool
}

enum AudioAssetInspectionError: Error, Equatable, Sendable {
    case fileMissing
    case fileUnreadable
    case invalidDuration
    case missingAudioTrack
    case invalidContainer
}

enum AudioAssetInspector {
    static func inspect(url: URL) async throws -> AudioAssetInspection {
        try await inspectWithAudioTrack(url: url).inspection
    }

    /// The inspection plus the audio track that was loaded to produce it.
    ///
    /// Kept separate from `inspect(url:)` because `AVAssetTrack` is not `Sendable`
    /// and the finalization path only needs the sendable facts. Callers that go on
    /// to read the track's format use this instead of opening the asset a second
    /// time — for a long recording that is a whole extra demux of the same file.
    static func inspectWithAudioTrack(
        url: URL
    ) async throws -> (inspection: AudioAssetInspection, audioTrack: AVAssetTrack) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw AudioAssetInspectionError.fileMissing
        }

        let fileSize: Int64
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let value = attributes[.size] as? NSNumber, value.int64Value > 0 else {
                throw AudioAssetInspectionError.fileUnreadable
            }
            fileSize = value.int64Value
        } catch let error as AudioAssetInspectionError {
            throw error
        } catch {
            throw AudioAssetInspectionError.fileUnreadable
        }

        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw AudioAssetInspectionError.invalidDuration
            }

            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = tracks.first else {
                throw AudioAssetInspectionError.missingAudioTrack
            }

            return (
                AudioAssetInspection(
                    fileSize: fileSize,
                    duration: duration,
                    hasAudioTrack: true
                ),
                audioTrack
            )
        } catch let error as AudioAssetInspectionError {
            throw error
        } catch {
            throw AudioAssetInspectionError.invalidContainer
        }
    }
}

struct RecordingFinalizationFacts: Equatable, Sendable {
    let delegateSucceeded: Bool
    let fileExists: Bool
    let fileSize: Int64
    let duration: TimeInterval
    let hasAudioTrack: Bool
}

enum RecordingFinalizationRejection: Equatable, Sendable {
    case delegateReportedFailure
    case fileMissing
    case fileUnreadable
    case invalidDuration
    case missingAudioTrack
    case invalidContainer

    var userMessage: String {
        switch self {
        case .delegateReportedFailure:
            return "Recording failed and was not saved."
        case .fileMissing, .fileUnreadable, .invalidDuration, .missingAudioTrack, .invalidContainer:
            return "No audio was captured. Recording was not saved."
        }
    }
}

enum RecordingFinalizationResult: Equatable, Sendable {
    case usable(fileSize: Int64, duration: TimeInterval)
    case rejected(RecordingFinalizationRejection)

    var isUsable: Bool {
        if case .usable = self { return true }
        return false
    }
}

enum RecordingFinalizationPolicy {
    static func evaluate(_ facts: RecordingFinalizationFacts) -> RecordingFinalizationResult {
        guard facts.delegateSucceeded else {
            return .rejected(.delegateReportedFailure)
        }
        guard facts.fileExists else {
            return .rejected(.fileMissing)
        }
        guard facts.fileSize > 0 else {
            return .rejected(.fileUnreadable)
        }
        guard facts.duration.isFinite, facts.duration > 0 else {
            return .rejected(.invalidDuration)
        }
        guard facts.hasAudioTrack else {
            return .rejected(.missingAudioTrack)
        }

        return .usable(fileSize: facts.fileSize, duration: facts.duration)
    }

    static func inspect(url: URL, delegateSucceeded: Bool) async -> RecordingFinalizationResult {
        guard delegateSucceeded else {
            return .rejected(.delegateReportedFailure)
        }

        do {
            let inspection = try await AudioAssetInspector.inspect(url: url)
            return evaluate(
                RecordingFinalizationFacts(
                    delegateSucceeded: true,
                    fileExists: true,
                    fileSize: inspection.fileSize,
                    duration: inspection.duration,
                    hasAudioTrack: inspection.hasAudioTrack
                )
            )
        } catch let error as AudioAssetInspectionError {
            let rejection: RecordingFinalizationRejection
            switch error {
            case .fileMissing: rejection = .fileMissing
            case .fileUnreadable: rejection = .fileUnreadable
            case .invalidDuration: rejection = .invalidDuration
            case .missingAudioTrack: rejection = .missingAudioTrack
            case .invalidContainer: rejection = .invalidContainer
            }
            return .rejected(rejection)
        } catch {
            return .rejected(.invalidContainer)
        }
    }
}

// MARK: - Audio File Info

struct AudioFileInfo {
    let url: URL
    let duration: TimeInterval
    let fileSize: Int64
    let format: String
    let sampleRate: Double
    let channels: Int

    static func create(from url: URL) async throws -> AudioFileInfo {
        AppLog.shared.chunking("AudioFileInfo.create - Analyzing audio source", level: .debug)
        AppLog.shared.chunking("AudioFileInfo.create - File exists: \(FileManager.default.fileExists(atPath: url.path))", level: .debug)

        // One inspection, and it hands back the audio track it already loaded:
        // re-opening the asset here meant demuxing the whole file twice.
        let inspection: AudioAssetInspection
        let audioTrack: AVAssetTrack
        do {
            (inspection, audioTrack) = try await AudioAssetInspector.inspectWithAudioTrack(url: url)
        } catch {
            AppLog.shared.chunking(
                "AudioFileInfo.create - Audio inspection failed: \(error)",
                level: .error
            )
            throw AudioChunkingError.invalidAudioFile
        }
        let duration = inspection.duration
        AppLog.shared.chunking("AudioFileInfo.create - Loaded duration: \(duration)s (\(duration/60) minutes)", level: .debug)

        let fileSize = inspection.fileSize
        AppLog.shared.chunking("AudioFileInfo.create - File size: \(fileSize) bytes (\(fileSize/1024/1024) MB)", level: .debug)

        // Get format information
        var sampleRate: Double = 0
        var channels: Int = 0

        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        if let formatDescription = formatDescriptions.first {
            let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
            sampleRate = audioStreamBasicDescription?.pointee.mSampleRate ?? 0
            channels = Int(audioStreamBasicDescription?.pointee.mChannelsPerFrame ?? 0)
        }

        // Determine format from file extension
        let fileExtension = url.pathExtension.lowercased()
        let format: String
        switch fileExtension {
        case "mp3":
            format = "MP3"
        case "m4a", "mp4":
            format = "AAC"
        case "wav":
            format = "WAV"
        case "flac":
            format = "FLAC"
        default:
            format = fileExtension.uppercased()
        }

        let audioFileInfo = AudioFileInfo(
            url: url,
            duration: duration,
            fileSize: fileSize,
            format: format,
            sampleRate: sampleRate,
            channels: channels
        )

        AppLog.shared.chunking("AudioFileInfo.create - Successfully created: duration=\(audioFileInfo.duration)s, size=\(audioFileInfo.fileSize) bytes, format=\(audioFileInfo.format), sampleRate=\(audioFileInfo.sampleRate), channels=\(audioFileInfo.channels)", level: .debug)

        return audioFileInfo
    }
}

// MARK: - Chunking Errors

enum AudioChunkingError: LocalizedError {
    case fileNotFound
    case invalidAudioFile
    case chunkingFailed(String)
    case reassemblyFailed(String)
    case tempDirectoryCreationFailed
    case fileWriteFailed(String)
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Audio file not found or inaccessible"
        case .invalidAudioFile:
            return "Invalid audio file format or corrupted file"
        case .chunkingFailed(let message):
            return "Audio file chunking failed: \(message)"
        case .reassemblyFailed(let message):
            return "Transcript reassembly failed: \(message)"
        case .tempDirectoryCreationFailed:
            return "Failed to create temporary directory for chunks"
        case .fileWriteFailed(let message):
            return "Failed to write chunk file: \(message)"
        case .cleanupFailed(let message):
            return "Failed to cleanup temporary files: \(message)"
        }
    }
}
