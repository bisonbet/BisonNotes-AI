import Foundation
import GRDB

private struct SQLiteEncodedSetting {
    let type: String
    let stringValue: String?
    let integerValue: Int64?
    let realValue: Double?
    let blobValue: Data?

    init(
        type: String,
        stringValue: String? = nil,
        integerValue: Int64? = nil,
        realValue: Double? = nil,
        blobValue: Data? = nil
    ) {
        self.type = type
        self.stringValue = stringValue
        self.integerValue = integerValue
        self.realValue = realValue
        self.blobValue = blobValue
    }
}

extension SQLiteLibraryStore {
    func readLibrarySettings() throws -> LibrarySettingsSnapshot {
        try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT key, valueType, stringValue, integerValue, realValue, blobValue
                FROM library_settings
                ORDER BY key
                """
            )
            var values: [String: LibrarySettingValue] = [:]
            for row in rows {
                guard let key: String = row["key"], !key.isEmpty,
                      let valueType: String = row["valueType"] else {
                    throw LibrarySettingsStoreError.invalidKey("<stored setting>")
                }
                values[key] = try Self.settingValue(from: row, key: key, type: valueType)
            }
            return LibrarySettingsSnapshot(values: values)
        }
    }

    func applyLibrarySettings(
        _ snapshot: LibrarySettingsSnapshot,
        at date: Date = Date()
    ) throws {
        let timestamp = date.timeIntervalSinceReferenceDate
        try databaseQueue.write { database in
            for key in snapshot.values.keys.sorted() {
                try Self.applySetting(
                    snapshot.values[key],
                    forKey: key,
                    timestamp: timestamp,
                    date: date,
                    in: database
                )
            }
        }
    }

    private static func applySetting(
        _ value: LibrarySettingValue?,
        forKey key: String,
        timestamp: Double,
        date: Date,
        in database: Database
    ) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibrarySettingsStoreError.invalidKey(key)
        }
        guard let value else { return }
        let encoded = try encodedSetting(value, key: key)
        let existed = try persistSetting(
            encoded,
            forKey: key,
            timestamp: timestamp,
            in: database
        )
        _ = try SQLiteLibraryStore.recordChange(
            in: database,
            entity: .setting,
            storageID: key,
            operation: existed ? .updated : .inserted,
            at: date
        )
    }

    private static func persistSetting(
        _ encoded: SQLiteEncodedSetting,
        forKey key: String,
        timestamp: Double,
        in database: Database
    ) throws -> Bool {
        let existed = try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM library_settings WHERE key = ?)",
            arguments: [key]
        ) ?? false
        try database.execute(
            sql: """
            UPDATE library_settings
            SET valueType = ?, stringValue = ?, integerValue = ?,
                realValue = ?, blobValue = ?, updatedAt = ?
            WHERE key = ?
            """,
            arguments: [
                encoded.type,
                encoded.stringValue,
                encoded.integerValue,
                encoded.realValue,
                encoded.blobValue,
                timestamp,
                key
            ]
        )

        if database.changesCount == 0 {
            try database.execute(
                sql: """
                INSERT INTO library_settings (
                    key, valueType, stringValue, integerValue,
                    realValue, blobValue, updatedAt
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    key,
                    encoded.type,
                    encoded.stringValue,
                    encoded.integerValue,
                    encoded.realValue,
                    encoded.blobValue,
                    timestamp
                ]
            )
        }
        return existed
    }

    private static func settingValue(
        from row: Row,
        key: String,
        type: String
    ) throws -> LibrarySettingValue {
        switch type {
        case "string":
            return .string(try storedString(from: row, key: key))
        case "integer":
            return .integer(try storedInteger(from: row, key: key))
        case "real":
            return .real(try storedFiniteReal(from: row, key: key))
        case "bool":
            let value = try storedInteger(from: row, key: key, type: "bool")
            guard value == 0 || value == 1 else {
                throw LibrarySettingsStoreError.unsupportedValue(
                    key: key,
                    type: "bool-without-0-or-1-value"
                )
            }
            return .bool(value == 1)
        case "data":
            return .data(try storedData(from: row, key: key))
        case "date":
            return .date(Date(timeIntervalSinceReferenceDate: try storedFiniteReal(from: row, key: key)))
        default:
            throw LibrarySettingsStoreError.unsupportedValue(key: key, type: type)
        }
    }

    private static func storedString(from row: Row, key: String) throws -> String {
        guard let value: String = row["stringValue"] else {
            throw LibrarySettingsStoreError.unsupportedValue(
                key: key,
                type: "string-without-value"
            )
        }
        return value
    }

    private static func storedInteger(
        from row: Row,
        key: String,
        type: String = "integer"
    ) throws -> Int64 {
        guard let value: Int64 = row["integerValue"] else {
            throw LibrarySettingsStoreError.unsupportedValue(
                key: key,
                type: "\(type)-without-value"
            )
        }
        return value
    }

    private static func storedFiniteReal(from row: Row, key: String) throws -> Double {
        guard let value: Double = row["realValue"], value.isFinite else {
            throw LibrarySettingsStoreError.nonFiniteValue(key: key)
        }
        return value
    }

    private static func storedData(from row: Row, key: String) throws -> Data {
        guard let value: Data = row["blobValue"] else {
            throw LibrarySettingsStoreError.unsupportedValue(
                key: key,
                type: "data-without-value"
            )
        }
        return value
    }

    private static func encodedSetting(
        _ value: LibrarySettingValue,
        key: String
    ) throws -> SQLiteEncodedSetting {
        switch value {
        case .string(let value):
            return SQLiteEncodedSetting(type: "string", stringValue: value)
        case .integer(let value):
            return SQLiteEncodedSetting(type: "integer", integerValue: value)
        case .real(let value):
            guard value.isFinite else {
                throw LibrarySettingsStoreError.nonFiniteValue(key: key)
            }
            return SQLiteEncodedSetting(type: "real", realValue: value)
        case .bool(let value):
            return SQLiteEncodedSetting(type: "bool", integerValue: value ? 1 : 0)
        case .data(let value):
            return SQLiteEncodedSetting(type: "data", blobValue: value)
        case .date(let value):
            let timeInterval = value.timeIntervalSinceReferenceDate
            guard timeInterval.isFinite else {
                throw LibrarySettingsStoreError.nonFiniteValue(key: key)
            }
            return SQLiteEncodedSetting(type: "date", realValue: timeInterval)
        }
    }
}
