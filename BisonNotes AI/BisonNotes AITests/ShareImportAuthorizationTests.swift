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
}
