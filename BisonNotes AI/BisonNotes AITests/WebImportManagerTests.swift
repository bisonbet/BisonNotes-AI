//
//  WebImportManagerTests.swift
//  BisonNotes AITests
//

import XCTest
@testable import BisonNotes_AI

final class WebImportManagerTests: XCTestCase {
    func testYouTubeVideoIDExtractionSupportsCommonURLShapes() throws {
        let watchURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abcDEF123_4&t=120"))
        let shortURL = try XCTUnwrap(URL(string: "https://youtu.be/abcDEF123_4"))
        let sharedURL = try XCTUnwrap(URL(
            string: "https://youtu.be/qLFNNRxwd5s?si=0LW8jQOPnePUG5VC"
        ))
        let shortsURL = try XCTUnwrap(URL(string: "https://youtube.com/shorts/abcDEF123_4?feature=share"))
        let embedURL = try XCTUnwrap(URL(string: "https://www.youtube-nocookie.com/embed/abcDEF123_4"))

        XCTAssertEqual(WebImportURLClassifier.youtubeVideoID(from: watchURL), "abcDEF123_4")
        XCTAssertEqual(WebImportURLClassifier.youtubeVideoID(from: shortURL), "abcDEF123_4")
        XCTAssertEqual(WebImportURLClassifier.youtubeVideoID(from: sharedURL), "qLFNNRxwd5s")
        XCTAssertEqual(WebImportURLClassifier.youtubeVideoID(from: shortsURL), "abcDEF123_4")
        XCTAssertEqual(WebImportURLClassifier.youtubeVideoID(from: embedURL), "abcDEF123_4")
    }

    func testYouTubePlayerResponseParserExtractsCaptionBaseURL() throws {
        let html = """
        <html><script>
        var ytInitialPlayerResponse = {
          "videoDetails": { "title": "Team Sync" },
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=qLFNNRxwd5s&lang=en",
                  "languageCode": "en",
                  "name": { "simpleText": "English" }
                }
              ]
            }
          }
        };
        </script></html>
        """

        let metadata = try YouTubePlayerResponseParser.metadata(fromHTML: html)

        XCTAssertEqual(metadata.title, "Team Sync")
        XCTAssertEqual(metadata.captionTracks.count, 1)
        XCTAssertEqual(metadata.captionTracks.first?.langCode, "en")
        XCTAssertEqual(metadata.captionTracks.first?.baseURL?.host, "www.youtube.com")
    }

    func testCaptionCleanerRemovesVTTMetadataAndDecodesEntities() {
        let vtt = """
        WEBVTT

        1
        00:00:00.000 --> 00:00:02.000
        Welcome &amp; thanks for joining

        2
        00:00:02.000 --> 00:00:04.000
        <c>Review Q&#38;A and next steps</c>
        """

        let text = TranscriptCaptionTextCleaner.plainText(from: vtt)

        XCTAssertEqual(text, "Welcome & thanks for joining\nReview Q&A and next steps")
    }

    func testCaptionCleanerReadsYouTubeTranscriptXML() {
        let xml = """
        <transcript>
            <text start="0" dur="1">First &amp; second</text>
            <text start="1" dur="1">Next &#39;item&#39;</text>
        </transcript>
        """

        let text = TranscriptCaptionTextCleaner.plainText(from: xml)

        XCTAssertEqual(text, "First & second\nNext 'item'")
    }

    func testCaptionCleanerRemovesCopiedYouTubeTimestamps() {
        let copiedTranscript = """
        0:00
        Welcome &amp; thanks for joining
        0:03 Next topic
        00:01:02.500 Decision made
        """

        let text = TranscriptCaptionTextCleaner.plainText(from: copiedTranscript)

        XCTAssertEqual(text, "Welcome & thanks for joining\nNext topic\nDecision made")
    }

    func testYouTubeRateLimitMessageDoesNotExposeRawHTTPStatus() {
        let message = WebImportError.youtubeRateLimited.localizedDescription

        XCTAssertTrue(message.contains("YouTube blocked the caption request"))
        XCTAssertFalse(message.contains("HTTP 429"))
    }
}
