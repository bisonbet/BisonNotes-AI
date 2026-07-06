//
//  YouTubeImportService.swift
//  BisonNotes AI
//
//  Imports public YouTube caption tracks as transcripts.
//

import Foundation

struct YouTubeImportService {
    func transcriptItem(from url: URL) async throws -> TranscriptTextImportItem {
        guard let videoID = WebImportURLClassifier.youtubeVideoID(from: url) else {
            throw WebImportError.invalidYouTubeURL
        }

        let watchMetadata = try? await fetchWatchPageMetadata(videoID: videoID)
        let tracks = watchMetadata?.captionTracks.isEmpty == false
            ? watchMetadata?.captionTracks ?? []
            : try await fetchCaptionTracks(videoID: videoID)
        guard let track = preferredCaptionTrack(from: tracks) else {
            throw WebImportError.noYouTubeCaptions
        }

        let captionText = try await fetchCaptionText(videoID: videoID, track: track)
        let transcript = TranscriptCaptionTextCleaner.plainText(from: captionText)
        guard transcript.count >= 10 else {
            throw WebImportError.emptyTranscript
        }

        let title: String
        if let metadataTitle = watchMetadata?.title {
            title = metadataTitle
        } else {
            title = await fetchTitle(for: url) ?? "YouTube \(videoID)"
        }
        return TranscriptTextImportItem(text: transcript, name: title)
    }

    private func fetchWatchPageMetadata(videoID: String) async throws -> YouTubeWatchPageMetadata {
        var components = URLComponents(string: "https://www.youtube.com/watch")
        components?.queryItems = [URLQueryItem(name: "v", value: videoID)]
        guard let url = components?.url else {
            throw WebImportError.invalidYouTubeURL
        }

        let (data, response) = try await URLSession.shared.data(for: request(for: url, accept: .html))
        try validateHTTPResponse(response)
        guard let html = String(data: data, encoding: .utf8) else {
            throw WebImportError.invalidResponse
        }

        return try YouTubePlayerResponseParser.metadata(fromHTML: html)
    }

    private func fetchCaptionTracks(videoID: String) async throws -> [YouTubeCaptionTrack] {
        var components = URLComponents(string: "https://www.youtube.com/api/timedtext")
        components?.queryItems = [
            URLQueryItem(name: "type", value: "list"),
            URLQueryItem(name: "v", value: videoID)
        ]

        guard let url = components?.url else {
            throw WebImportError.invalidYouTubeURL
        }

        let (data, response) = try await URLSession.shared.data(for: request(for: url, accept: .caption))
        try validateHTTPResponse(response)

        let parser = YouTubeCaptionListParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.shouldResolveExternalEntities = false
        guard xmlParser.parse() else {
            return []
        }

        return parser.tracks
    }

    private func preferredCaptionTrack(from tracks: [YouTubeCaptionTrack]) -> YouTubeCaptionTrack? {
        tracks.first { $0.langCode.lowercased() == "en" && $0.kind != "asr" }
            ?? tracks.first { $0.langCode.lowercased().hasPrefix("en") }
            ?? tracks.first { $0.kind != "asr" }
            ?? tracks.first
    }

    private func fetchCaptionText(
        videoID: String,
        track: YouTubeCaptionTrack
    ) async throws -> String {
        if let baseURL = track.baseURL {
            return try await fetchCaptionText(from: baseURL)
        }

        var queryItems = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "lang", value: track.langCode),
            URLQueryItem(name: "fmt", value: "vtt")
        ]

        if !track.name.isEmpty {
            queryItems.append(URLQueryItem(name: "name", value: track.name))
        }

        if !track.kind.isEmpty {
            queryItems.append(URLQueryItem(name: "kind", value: track.kind))
        }

        var components = URLComponents(string: "https://www.youtube.com/api/timedtext")
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw WebImportError.invalidYouTubeURL
        }

        return try await fetchCaptionText(from: url)
    }

    private func fetchCaptionText(from url: URL) async throws -> String {
        let captionURL = captionURLWithFormat(url)
        let (data, response) = try await URLSession.shared.data(
            for: request(for: captionURL, accept: .caption)
        )
        try validateHTTPResponse(response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WebImportError.emptyTranscript
        }
        return text
    }

    private func fetchTitle(for url: URL) async -> String? {
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ]

        guard let metadataURL = components?.url,
              let (data, response) = try? await URLSession.shared.data(
                for: request(for: metadataURL, accept: .json)
              ),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let metadata = try? JSONDecoder().decode(YouTubeOEmbedResponse.self, from: data) else {
            return nil
        }

        return metadata.title
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebImportError.invalidResponse
        }

        if httpResponse.statusCode == 429 {
            throw WebImportError.youtubeRateLimited
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebImportError.httpStatus(httpResponse.statusCode)
        }
    }

    private func captionURLWithFormat(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "fmt" }
        queryItems.append(URLQueryItem(name: "fmt", value: "vtt"))
        components.queryItems = queryItems
        return components.url ?? url
    }

    private func request(for url: URL, accept: YouTubeRequestAccept) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
                "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(accept.headerValue, forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        return request
    }
}

struct YouTubeCaptionTrack {
    let langCode: String
    let name: String
    let kind: String
    let baseURL: URL?

    init(langCode: String, name: String, kind: String, baseURL: URL? = nil) {
        self.langCode = langCode
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
    }
}

enum YouTubeRequestAccept {
    case html
    case caption
    case json

    var headerValue: String {
        switch self {
        case .html:
            return "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        case .caption:
            return "text/vtt,text/plain,*/*;q=0.8"
        case .json:
            return "application/json,text/plain,*/*"
        }
    }
}

final class YouTubeCaptionListParser: NSObject, XMLParserDelegate {
    private(set) var tracks: [YouTubeCaptionTrack] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "track",
              let langCode = attributeDict["lang_code"] else {
            return
        }

        tracks.append(YouTubeCaptionTrack(
            langCode: langCode,
            name: attributeDict["name"] ?? "",
            kind: attributeDict["kind"] ?? ""
        ))
    }
}

private struct YouTubeOEmbedResponse: Decodable {
    let title: String
}
