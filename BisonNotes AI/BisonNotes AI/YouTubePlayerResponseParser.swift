//
//  YouTubePlayerResponseParser.swift
//  BisonNotes AI
//
//  Extracts caption track metadata from YouTube watch-page player JSON.
//

import Foundation

struct YouTubeWatchPageMetadata {
    let title: String?
    let captionTracks: [YouTubeCaptionTrack]
}

struct YouTubePlayerResponseParser {
    static func metadata(fromHTML html: String) throws -> YouTubeWatchPageMetadata {
        let json = try extractPlayerResponseJSON(fromHTML: html)
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(YouTubePlayerResponse.self, from: data)
        return YouTubeWatchPageMetadata(
            title: response.videoDetails?.title,
            captionTracks: response.captionTracks
        )
    }

    private static func extractPlayerResponseJSON(fromHTML html: String) throws -> String {
        let markers = [
            "ytInitialPlayerResponse =",
            "ytInitialPlayerResponse=",
            "\"ytInitialPlayerResponse\":"
        ]

        for marker in markers {
            guard let markerRange = html.range(of: marker),
                  let openingBrace = html[markerRange.upperBound...].firstIndex(of: "{") else {
                continue
            }

            if let json = balancedJSONObject(in: html, startingAt: openingBrace) {
                return json
            }
        }

        throw WebImportError.noYouTubeCaptions
    }

    private static func balancedJSONObject(in text: String, startingAt start: String.Index) -> String? {
        var index = start
        var depth = 0
        var isInString = false
        var isEscaped = false

        while index < text.endIndex {
            let character = text[index]

            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
            } else if character == "\"" {
                isInString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }

            index = text.index(after: index)
        }

        return nil
    }
}

private struct YouTubePlayerResponse: Decodable {
    let captions: Captions?
    let videoDetails: VideoDetails?

    var captionTracks: [YouTubeCaptionTrack] {
        captions?
            .playerCaptionsTracklistRenderer?
            .captionTracks?
            .compactMap(\.importTrack) ?? []
    }

    struct Captions: Decodable {
        let playerCaptionsTracklistRenderer: Tracklist?
    }

    struct Tracklist: Decodable {
        let captionTracks: [CaptionTrack]?
    }

    struct CaptionTrack: Decodable {
        let baseUrl: String?
        let languageCode: String?
        let name: CaptionName?
        let kind: String?

        var importTrack: YouTubeCaptionTrack? {
            guard let languageCode,
                  let baseUrl,
                  let url = URL(string: baseUrl) else {
                return nil
            }

            return YouTubeCaptionTrack(
                langCode: languageCode,
                name: name?.text ?? "",
                kind: kind ?? "",
                baseURL: url
            )
        }
    }

    struct CaptionName: Decodable {
        let simpleText: String?
        let runs: [TextRun]?

        var text: String? {
            simpleText ?? runs?.map(\.text).joined()
        }
    }

    struct TextRun: Decodable {
        let text: String
    }

    struct VideoDetails: Decodable {
        let title: String?
    }
}
