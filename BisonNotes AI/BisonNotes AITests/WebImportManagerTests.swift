//
//  WebImportManagerTests.swift
//  BisonNotes AITests
//

import XCTest
import CoreData
@testable import BisonNotes_AI

final class WebImportManagerTests: XCTestCase {
    @MainActor
    func testSignedAudioDownloadImportsThroughPersistence() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioWebImportURLProtocol.self]
        let downloader = WebImportDownloader(sessionConfiguration: configuration)
        let persistence = PersistenceController(inMemory: true)
        let fileImportManager = FileImportManager(persistenceController: persistence)
        let transcriptImportManager = TranscriptImportManager()
        let manager = WebImportManager(downloader: downloader)
        let url = "https://example.com/signed-download"

        await manager.importFromURLString(
            url,
            importKind: .audioOrVideo,
            fileImportManager: fileImportManager,
            transcriptImportManager: transcriptImportManager
        )

        XCTAssertTrue(manager.lastImportSucceeded)
        XCTAssertFalse(manager.showingImportAlert)
        XCTAssertEqual(fileImportManager.importResults?.successful, 1)

        let request: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        let recordings = try persistence.container.viewContext.fetch(request)
        let recording = try XCTUnwrap(recordings.first)
        XCTAssertEqual(recording.transcriptionStatus, "Not Started")
        XCTAssertTrue(recording.recordingURL?.hasSuffix(".wav") == true)

        if let relativePath = recording.recordingURL,
           let documentsURL = FileManager.default.urls(
               for: .documentDirectory,
               in: .userDomainMask
           ).first {
            try? FileManager.default.removeItem(
                at: documentsURL.appendingPathComponent(relativePath)
            )
        }
    }

    @MainActor
    func testRejectedAudioShowsLinkErrorAndLeavesNoOrphanedFile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioWebImportURLProtocol.self]
        let downloader = WebImportDownloader(sessionConfiguration: configuration)
        let persistence = PersistenceController(inMemory: true)
        let fileImportManager = FileImportManager(persistenceController: persistence)
        let transcriptImportManager = TranscriptImportManager()
        let manager = WebImportManager(downloader: downloader)
        let documentsURL = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let filesBefore = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: documentsURL.path)) ?? []
        )

        await manager.importFromURLString(
            "https://example.com/invalid.wav",
            importKind: .audioOrVideo,
            fileImportManager: fileImportManager,
            transcriptImportManager: transcriptImportManager
        )

        let filesAfter = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: documentsURL.path)) ?? []
        )
        let request: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()

        XCTAssertFalse(manager.lastImportSucceeded)
        XCTAssertTrue(manager.showingImportAlert)
        XCTAssertTrue(manager.importMessage.contains("Invalid audio file"))
        XCTAssertFalse(fileImportManager.showingImportAlert)
        XCTAssertEqual(filesAfter, filesBefore)
        XCTAssertEqual(try persistence.container.viewContext.count(for: request), 0)
    }

    func testUnknownAudioMIMEIsNotRelabeledAsM4A() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioWebImportURLProtocol.self]
        let downloader = WebImportDownloader(sessionConfiguration: configuration)
        let url = try XCTUnwrap(URL(string: "https://example.com/unknown-media"))

        do {
            _ = try await downloader.downloadRemoteFile(from: url, preferredKind: .audioOrVideo)
            XCTFail("Expected an unknown audio MIME type to be rejected")
        } catch WebImportError.unsupportedRemoteType {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDownloaderStopsAnUnknownLengthBodyAtTheRouteLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedWebImportURLProtocol.self]
        let downloader = WebImportDownloader(
            sessionConfiguration: configuration,
            maxMediaDownloadSize: 16,
            maxTranscriptDownloadSize: 5
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/transcript.txt"))

        do {
            _ = try await downloader.downloadRemoteFile(from: url, preferredKind: .transcript)
            XCTFail("Expected the streaming size limit to stop the transfer")
        } catch WebImportError.fileTooLarge(let attemptedSize, let limit) {
            XCTAssertGreaterThan(attemptedSize, limit)
            XCTAssertEqual(limit, 5)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDownloaderRejectsRedirectTargetsThatViolateTransportPolicy() throws {
        let secureURL = try XCTUnwrap(URL(string: "https://example.com/file.txt"))
        let insecureURL = try XCTUnwrap(URL(string: "http://example.com/file.txt"))

        XCTAssertTrue(WebImportDownloader.isAllowedDownloadURL(secureURL))
        XCTAssertFalse(WebImportDownloader.isAllowedDownloadURL(insecureURL))
    }

    func testTemporaryCleanupRemovesStaleWebImportArtifacts() throws {
        let fileManager = FileManager.default
        let importsDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("BisonNotesWebImports", isDirectory: true)
        try fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        let staleFile = importsDirectory.appendingPathComponent("stale-test-\(UUID().uuidString).txt")
        try Data("stale transcript".utf8).write(to: staleFile)
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)],
            ofItemAtPath: staleFile.path
        )

        TemporaryFileCleanupService.shared.cleanupStaleFiles(maxAge: 60)

        XCTAssertFalse(fileManager.fileExists(atPath: staleFile.path))
    }

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

    func testCaptionCleanerPreservesNumericSpeechAndComparisons() {
        let vtt = """
        WEBVTT

        1
        00:00:00.000 --> 00:00:02.000
        911

        2
        00:00:02.000 --> 00:00:04.000
        In 2026, 5 < 10 and 10 > 5
        """

        let text = TranscriptCaptionTextCleaner.plainText(from: vtt)

        XCTAssertEqual(text, "911\nIn 2026, 5 < 10 and 10 > 5")
    }

    func testCaptionCleanerOnlyTreatsNumbersBeforeTimingLinesAsCueIdentifiers() {
        let srt = """
        42
        This number is spoken aloud.

        43
        00:00:01,000 --> 00:00:02,000
        This is a caption cue.
        """

        let text = TranscriptCaptionTextCleaner.plainText(from: srt)

        XCTAssertEqual(text, "42\nThis number is spoken aloud.\nThis is a caption cue.")
    }

    func testYouTubeRateLimitMessageDoesNotExposeRawHTTPStatus() {
        let message = WebImportError.youtubeRateLimited.localizedDescription

        XCTAssertTrue(message.contains("YouTube blocked the caption request"))
        XCTAssertFalse(message.contains("HTTP 429"))
    }

    func testYouTubeRateLimitWinsWhenCaptionFallbackAlsoFails() {
        let resolved = YouTubeImportService.preferredCaptionDiscoveryError(
            watchError: WebImportError.youtubeRateLimited,
            fallbackError: WebImportError.noYouTubeCaptions
        )

        guard let webImportError = resolved as? WebImportError,
              case .youtubeRateLimited = webImportError else {
            return XCTFail("Expected the rate-limit recovery error to be preserved")
        }
    }
}

private final class OversizedWebImportURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
              ) else {
            client?.urlProtocol(self, didFailWithError: WebImportError.invalidResponse)
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("four".utf8))
        client?.urlProtocol(self, didLoad: Data("more".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AudioWebImportURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: WebImportError.invalidResponse)
            return
        }

        let isSignedDownload = url.lastPathComponent == "signed-download"
        let isUnknownMedia = url.lastPathComponent == "unknown-media"
        let headers: [String: String]
        let data: Data

        if isSignedDownload {
            headers = [
                "Content-Type": "application/octet-stream",
                "Content-Disposition": "attachment; filename=\"signed-recording.wav\""
            ]
            data = Self.validWAVData()
        } else if isUnknownMedia {
            headers = ["Content-Type": "audio/flac"]
            data = Data("not-flac".utf8)
        } else {
            headers = ["Content-Type": "audio/wav"]
            data = Data("not-audio".utf8)
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: WebImportError.invalidResponse)
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func validWAVData() -> Data {
        let sampleCount: UInt32 = 800
        var data = Data("RIFF".utf8)
        data.appendLittleEndian(UInt32(36) + sampleCount)
        data.append(Data("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(8_000))
        data.appendLittleEndian(UInt32(8_000))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(8))
        data.append(Data("data".utf8))
        data.appendLittleEndian(sampleCount)
        data.append(Data(repeating: 128, count: Int(sampleCount)))
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}
