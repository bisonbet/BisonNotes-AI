import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteLibrarySettingsRuntimeTests: XCTestCase {
    func testSQLiteStoreRoundTripsTypedAllowlistedValuesAndRecordsChanges() async throws {
        let directory = try makeVerifierTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteLibraryStore(
            databaseURL: directory.appendingPathComponent("library.sqlite")
        )
        let settings = try SQLiteLibrarySettingsStore(
            store: store,
            allowedKeys: ["timeFormat", "enabled", "count", "timeout", "payload", "date"]
        )
        let snapshot = LibrarySettingsSnapshot(values: [
            "timeFormat": .string("24h"),
            "enabled": .bool(true),
            "count": .integer(42),
            "timeout": .real(180.5),
            "payload": .data(Data([1, 2, 3])),
            "date": .date(Date(timeIntervalSinceReferenceDate: 123))
        ])

        try await settings.apply(snapshot)
        let persistedSnapshot = try await settings.read()
        XCTAssertEqual(persistedSnapshot, snapshot)
        let repository = SQLiteLibraryRepository(store: store)
        let settingsRevision = try await repository.currentRevision()
        let settingChanges = try await repository.changes(since: 0)
        XCTAssertEqual(settingsRevision, 6)
        XCTAssertEqual(
            settingChanges.map(\.entity),
            Array(repeating: .setting, count: 6)
        )

        do {
            try await settings.apply(
                LibrarySettingsSnapshot(values: ["notAllowed": .string("secret")])
            )
            XCTFail("Expected the settings allowlist to reject the key")
        } catch let error as LibrarySettingsStoreError {
            XCTAssertEqual(error, .disallowedKey("notAllowed"))
        }
    }

    func testUserDefaultsStoreUsesOnlyItsAllowlist() async throws {
        let suiteName = "BisonNotesSQLiteRuntimeTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("untouched", forKey: "outsideAllowlist")
        let settings = try UserDefaultsLibrarySettingsStore(
            defaults: defaults,
            allowedKeys: ["timeFormat", "enabled"]
        )
        let snapshot = LibrarySettingsSnapshot(values: [
            "timeFormat": .string("12h"),
            "enabled": .bool(false)
        ])

        try await settings.apply(snapshot)
        let persistedSnapshot = try await settings.read()
        XCTAssertEqual(persistedSnapshot, snapshot)
        XCTAssertEqual(defaults.string(forKey: "outsideAllowlist"), "untouched")

        do {
            try await settings.apply(
                LibrarySettingsSnapshot(values: ["outsideAllowlist": .string("changed")])
            )
            XCTFail("Expected the defaults allowlist to reject the key")
        } catch let error as LibrarySettingsStoreError {
            XCTAssertEqual(error, .disallowedKey("outsideAllowlist"))
        }
    }
}
