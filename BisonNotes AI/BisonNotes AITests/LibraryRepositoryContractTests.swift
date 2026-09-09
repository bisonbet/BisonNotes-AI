import CoreData
import Foundation
import XCTest
@testable import BisonNotes_AI

final class LibraryRepositoryContractTests: XCTestCase {
    func testCoreDataRepositoryReturnsStorageNeutralRecordingSnapshot() async throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        let fixture = try SQLiteMigrationCoreDataSourceFixtureFactory.make(
            at: directory.appendingPathComponent("repository.sqlite"),
            version: .active
        )
        defer {
            try? SQLiteMigrationCoreDataSourceFixtureFactory.close(
                container: fixture.container
            )
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = CoreDataLibraryRepository(
            context: fixture.container.viewContext
        )
        let recordings = try await repository.fetchRecordingSummaries()

        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].legacyID, "10000000-0000-0000-0000-000000000001")
        XCTAssertEqual(recordings[0].name, "Fixture recording")
        XCTAssertEqual(recordings[0].recordingDate, Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(recordings[0].duration, 7.5)
        XCTAssertEqual(recordings[0].fileSize, 42)
        XCTAssertEqual(recordings[0].recordingURL, "recording.m4a")
        XCTAssertEqual(recordings[0].isArchived, false)
        XCTAssertEqual(recordings[0].lastModified, Date(timeIntervalSinceReferenceDate: 101))
    }
}
