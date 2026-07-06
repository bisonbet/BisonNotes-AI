//
//  WebImportModels.swift
//  BisonNotes AI
//

import Foundation

enum WebImportKind: String, CaseIterable, Identifiable {
    case automatic
    case audioOrVideo
    case transcript

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .audioOrVideo:
            return "Audio or Video"
        case .transcript:
            return "Transcript"
        }
    }
}

enum WebImportRoute {
    case audioOrVideo
    case transcript
}

struct DownloadedWebFile {
    let localURL: URL
    let route: WebImportRoute
}

struct YouTubeImportRecovery: Identifiable {
    let id = UUID()
    let videoURL: URL
    let videoID: String

    var transcriptName: String {
        "YouTube \(videoID)"
    }
}

enum WebImportError: LocalizedError {
    case invalidURL
    case insecureURL
    case invalidResponse
    case httpStatus(Int)
    case unsupportedRemoteType
    case fileTooLarge(Int64, Int64)
    case invalidYouTubeURL
    case noYouTubeCaptions
    case emptyTranscript
    case youtubeAudioUnsupported
    case transcriptImportFailed
    case youtubeRateLimited

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid HTTP or HTTPS URL."
        case .insecureURL:
            return "Public HTTP links are blocked. Use HTTPS, localhost, or a private-network address."
        case .invalidResponse:
            return "The server did not return a valid response."
        case .httpStatus(let status):
            return "The server returned HTTP \(status)."
        case .unsupportedRemoteType:
            return "This link does not look like a supported audio, video, or transcript file."
        case .fileTooLarge(let size, let limit):
            return """
            The file is too large (\(Self.formatBytes(size)); maximum is \(Self.formatBytes(limit)).
            """
        case .invalidYouTubeURL:
            return "This YouTube link could not be recognized."
        case .noYouTubeCaptions:
            return "No public caption track was found for this YouTube video."
        case .emptyTranscript:
            return "The transcript was empty."
        case .youtubeAudioUnsupported:
            return """
            YouTube audio cannot be imported directly. Import public captions from the YouTube \
            link, or use a direct audio/video file URL.
            """
        case .transcriptImportFailed:
            return "The transcript could not be imported."
        case .youtubeRateLimited:
            return """
            YouTube blocked the caption request from this network. Try again later, or import a VTT, \
            SRT, or TXT transcript file for this video.
            """
        }
    }

    private static func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
