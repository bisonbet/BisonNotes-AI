import Foundation

/// Collects the entire inventory or throws; no caller receives a partial result.
@MainActor
enum CloudQueryPagination {
    static func collect<Record, Cursor>(
        firstPage: (records: [Record], cursor: Cursor?),
        nextPage: @MainActor (Cursor) async throws -> (records: [Record], cursor: Cursor?)
    ) async throws -> [Record] {
        var records = firstPage.records
        var cursor = firstPage.cursor
        while let current = cursor {
            let page = try await nextPage(current)
            records.append(contentsOf: page.records)
            cursor = page.cursor
        }
        return records
    }
}
