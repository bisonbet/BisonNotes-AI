//
//  ShareImportAuthorizationTests.swift
//  BisonNotes AITests
//

import XCTest
@testable import BisonNotes_AI

final class ShareImportAuthorizationTests: XCTestCase {
    private var inboxURL: URL!

    override func setUpWithError() throws {
        inboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareImportAuthorizationTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: inboxURL)
    }

    func testRejectsShareImportURLWithoutStoredToken() {
        let token = UUID().uuidString
        let url = URL(string: "bisonnotes://share-import?token=\(token)")!

        XCTAssertFalse(ShareImportAuthorization.consumeURLToken(from: url, in: inboxURL))
    }

    func testConsumesMatchingURLTokenOnce() throws {
        let token = UUID().uuidString
        let tokenData = try XCTUnwrap(token.data(using: .utf8))
        try tokenData.write(to: ShareImportAuthorization.tokenFileURL(in: inboxURL), options: .atomic)
        let url = URL(string: "bisonnotes://share-import?token=\(token)")!

        XCTAssertTrue(ShareImportAuthorization.consumeURLToken(from: url, in: inboxURL))
        XCTAssertFalse(ShareImportAuthorization.consumeURLToken(from: url, in: inboxURL))
    }

    func testRejectsUnsupportedSchemeHostEvenWithToken() throws {
        let token = UUID().uuidString
        let tokenData = try XCTUnwrap(token.data(using: .utf8))
        try tokenData.write(to: ShareImportAuthorization.tokenFileURL(in: inboxURL), options: .atomic)
        let url = URL(string: "bisonnotes://settings?token=\(token)")!

        XCTAssertFalse(ShareImportAuthorization.consumeURLToken(from: url, in: inboxURL))
    }

    func testConsumesPendingTokenForActivationScan() throws {
        let token = UUID().uuidString
        let tokenData = try XCTUnwrap(token.data(using: .utf8))
        try tokenData.write(to: ShareImportAuthorization.tokenFileURL(in: inboxURL), options: .atomic)

        XCTAssertTrue(ShareImportAuthorization.consumePendingToken(in: inboxURL))
        XCTAssertFalse(ShareImportAuthorization.consumePendingToken(in: inboxURL))
    }

    func testSharedExtensionContractBuildsAcceptedImportURL() throws {
        let token = UUID().uuidString
        let url = try XCTUnwrap(ShareExtensionContract.importURL(for: token))

        XCTAssertTrue(ShareImportAuthorization.isShareImportURL(url))
        XCTAssertEqual(ShareImportAuthorization.token(from: url), token)
        XCTAssertEqual(
            ShareImportAuthorization.tokenFileName,
            ShareExtensionContract.tokenFileName
        )
    }

    func testSharedExtensionContractMatchesAppImportTypes() {
        let expectedExtensions: Set<String> = [
            "m4a", "mp3", "wav", "caf", "aiff", "aif",
            "txt", "text", "md", "markdown", "pdf", "doc", "docx"
        ]

        XCTAssertEqual(ShareExtensionContract.supportedExtensions, expectedExtensions)
    }

    func testSharedExtensionContractUsesSuggestedNameForExtensionlessTemporaryURL() throws {
        let provider = NSItemProvider()
        provider.suggestedName = "Meeting Recording.M4A"

        let destinationName = try XCTUnwrap(
            ShareExtensionContract.destinationFileName(
                sourceURL: URL(fileURLWithPath: "/tmp/provider-file"),
                provider: provider,
                typeIdentifier: "com.apple.m4a-audio"
            )
        )

        XCTAssertTrue(destinationName.hasSuffix("_Meeting Recording.M4A"))
    }

    func testSharedExtensionContractSanitizesSuggestedFileName() throws {
        let provider = NSItemProvider()
        provider.suggestedName = "../../shared-notes.txt"

        let destinationName = try XCTUnwrap(
            ShareExtensionContract.destinationFileName(
                sourceURL: URL(fileURLWithPath: "/tmp/provider-file"),
                provider: provider,
                typeIdentifier: "public.plain-text"
            )
        )

        XCTAssertTrue(destinationName.hasSuffix("_shared-notes.txt"))
        XCTAssertFalse(destinationName.contains(".."))
    }
}
