import GRDB
import XCTest

final class GRDBSystemSQLiteTests: XCTestCase {
    func testPinnedGRDBCanCreateAndQueryAFileBackedDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BisonNotesGRDB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let databaseURL = directory.appendingPathComponent("probe.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try DatabaseQueue(path: databaseURL.path)
        try database.write { db in
            try db.create(table: "probe") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("payload", .text).notNull()
            }

            try db.execute(
                sql: "INSERT INTO probe (payload) VALUES (?)",
                arguments: ["system"]
            )

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM probe") ?? 0
            XCTAssertEqual(count, 1)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
    }
}
