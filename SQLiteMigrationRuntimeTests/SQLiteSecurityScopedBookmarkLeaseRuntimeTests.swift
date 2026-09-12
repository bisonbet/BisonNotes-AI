import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteSecurityScopedBookmarkLeaseRuntimeTests: XCTestCase {
    func testLeaseResolvesBookmarkAndStopsAccessIdempotently() throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let providerRoot = directory.appendingPathComponent("provider", isDirectory: true)
        try FileManager.default.createDirectory(
            at: providerRoot,
            withIntermediateDirectories: false
        )
        let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        let bookmark = try providerRoot.bookmarkData(
            options: bookmarkOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let lease = try SQLiteSecurityScopedBookmarkLease(bookmarkData: bookmark)
        XCTAssertEqual(lease.url, providerRoot.standardizedFileURL)
        XCTAssertFalse(lease.isStale)

        lease.stopAccessing()
        lease.stopAccessing()
    }

    func testLeaseRejectsInvalidBookmarkWithoutExposingSourceDetails() {
        XCTAssertThrowsError(
            try SQLiteSecurityScopedBookmarkLease(bookmarkData: Data([0x01, 0x02]))
        ) { error in
            XCTAssertEqual(
                error as? SQLiteSecurityScopedBookmarkError,
                .unableToResolve
            )
            XCTAssertFalse(error.localizedDescription.contains("0x01"))
        }
    }
}
